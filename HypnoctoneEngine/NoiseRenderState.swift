import Foundation
import Atomics

/// ピンクノイズ生成と振幅補間（フェードイン / フェードアウト）に必要な状態を保持するクラス。
///
/// `NoiseGenerator` の内部実装として使われる。`AVAudioSourceNode` の render block と
/// メインスレッド（fade スケジュール）の両方から参照される。
/// render block はリアルタイムのオーディオスレッドで実行されるため、
/// ここではアロケーション・ロック・I/O を行わず、単純な数値の読み書きだけに留める。
///
/// ## スレッドモデル
///
/// `ToneRenderState` と同じ「pending / active 分離 + odd/even seqlock」を採用。
/// fade コマンドの publish/observe プロトコルは `ToneRenderState` のコメントを参照。
///
/// 1. **Audio thread 単一所有**
///    - fade: `currentAmplitude`, `activeTargetAmplitude`, `activeFadeFramesRemaining`, `lastConsumedGeneration`
///    - PRNG（L/R 独立）: `prngStateLeft`, `prngStateRight`（xorshift32 の state）
///    - Paul Kellet's pink filter state（L/R 独立）: `b0L`..`b6L`, `b0R`..`b6R`
///    - 1-pole IIR lowpass state（L/R 独立）: `lpL`, `lpR`
///    - Filter cutoff LFO 位相（L/R 共通）: `filterLfoPhase`
///    - L/R 独立 PRNG / pink filter / lowpass により、左右で相関ゼロの真ステレオを生成する。
///
/// 2. **Main writer / Audio reader（pending command）** — 全 atomic
///    - `pendingTargetAmplitudeBits` / `pendingFadeFrames` / `pendingGeneration`
///
/// 3. **定数**
///    - `sampleRate`, `defaultAmplitude`
///
/// ## なぜ PRNG を自前実装するか
///
/// `Float.random(in:)` などの標準 API は内部で OS の random source を呼ぶ可能性があり、
/// audio thread の realtime 制約（アロケーション・ロック・syscall 禁止）に違反する恐れがある。
/// xorshift32 は加算・XOR・ビットシフトのみの軽量 PRNG で、render block 内で安全に呼べる。
/// seed は 0 以外なら何でもよい（0 だと出力が永久に 0 になる）。
///
/// ## ピンクノイズ生成（Paul Kellet's IIR filter）
///
/// ホワイトノイズを 7 段の IIR フィルタに通すと約 -3dB/oct のピンクスペクトラムになる
/// （Paul Kellet, "Filter to make pink noise from white noise", 1999）。
/// Sleep アプリ用途では高域がきつくないピンクノイズが定番。係数は固定値。
final class NoiseRenderState {

    // MARK: - 定数

    /// レンダリングに使うサンプルレート（Hz）。fade フレーム数換算用。
    let sampleRate: Double

    /// 定常状態の基本振幅。Drone (0.2) より控えめにして混ぜたときに耳ざわりにならない量。
    /// lowpass で高域カットして RMS が下がる分、Task 11 時点の 0.05 から少し上げる想定。
    let defaultAmplitude: Float

    // MARK: - 定数 — Lowpass + cutoff LFO

    /// Lowpass cutoff の中心周波数（Hz）。filter LFO がこの周辺で揺らぐ。
    let filterCutoffCenter: Double

    /// Lowpass cutoff の LFO 深さ（Hz、±この値）。
    let filterCutoffDepthHz: Double

    /// Filter cutoff LFO の 1 サンプルあたり位相増分（ラジアン）。
    /// `2π / (filterLfoPeriodSeconds × sampleRate)`。period=0 で 0（実質無効化）。
    let filterLfoPhaseIncrement: Double

    // MARK: - 定数 — Envelope LFO（全体音量ゆらぎ / 呼吸感）

    /// Envelope LFO 深さ（multiplier の振幅。0.075 なら出力が 0.925〜1.075 で揺れる）。0 で無効。
    let envelopeDepth: Float

    /// Envelope LFO の 1 サンプルあたり位相増分（ラジアン）。
    /// `2π / (envelopePeriodSeconds × sampleRate)`。Drone と同じ値を渡せば同期して呼吸する。
    let envelopePhaseIncrement: Double

    // MARK: - Audio thread 単一所有 — fade

    /// 現在の振幅（サンプル単位に補間された値）。
    var currentAmplitude: Float = 0.0

    /// 現在 active な fade の目標振幅。
    var activeTargetAmplitude: Float = 0.0

    /// 現在 active な fade の残りフレーム数。
    var activeFadeFramesRemaining: Int = 0

    /// 最後に consume した `pendingGeneration` の値（odd/even seqlock）。
    var lastConsumedGeneration: Int = 0

    // MARK: - Audio thread 単一所有 — PRNG (xorshift32, L/R 独立)

    /// L チャネル用 xorshift32 state。0 以外で初期化。
    /// 独立 PRNG により L/R のノイズが相関ゼロになり、stereo の空間感が出る。
    var prngStateLeft: UInt32 = 0xCAFEBABE

    /// R チャネル用 xorshift32 state。L と別の seed を採用。
    /// `0xDEADBEEF` は慣用的なマジックナンバー（特に深い意味は無い）。
    var prngStateRight: UInt32 = 0xDEADBEEF

    // MARK: - Audio thread 単一所有 — Paul Kellet's pink filter state (L/R 独立)

    var b0L: Float = 0.0
    var b1L: Float = 0.0
    var b2L: Float = 0.0
    var b3L: Float = 0.0
    var b4L: Float = 0.0
    var b5L: Float = 0.0
    var b6L: Float = 0.0

    var b0R: Float = 0.0
    var b1R: Float = 0.0
    var b2R: Float = 0.0
    var b3R: Float = 0.0
    var b4R: Float = 0.0
    var b5R: Float = 0.0
    var b6R: Float = 0.0

    // MARK: - Audio thread 単一所有 — Lowpass + cutoff LFO

    /// L チャネル 1-pole IIR lowpass の前回出力（state）。
    /// `lp += α × (input - lp)` の `lp`。
    var lpL: Float = 0.0

    /// R チャネル 1-pole IIR lowpass の state。
    var lpR: Float = 0.0

    /// Filter cutoff LFO の現在位相（ラジアン）。
    /// 1 ブロックごとに `filterLfoPhaseIncrement × frameCount` だけ加算して 2π 折り返し。
    /// L/R 共通の LFO（雨音の密度変化は左右で同じ方向に動く想定）。
    var filterLfoPhase: Double = 0.0

    /// Envelope LFO の現在位相（ラジアン）。audio thread 単一所有。
    /// Drone と同じ初期位相・周期を渡せば自然に同期して全体が呼吸する。
    var envelopePhase: Double = 0.0

    // MARK: - Main writer / Audio reader（pending command, 全 atomic）

    /// 次の fade で目指す振幅（Float の bitPattern を保持）。
    /// odd/even seqlock writer プロトコルは `ToneRenderState` 参照。
    let pendingTargetAmplitudeBits = ManagedAtomic<UInt32>(0)

    /// 次の fade で使う総フレーム数。
    let pendingFadeFrames = ManagedAtomic<Int>(0)

    /// fade コマンドの世代番号。odd: writer 書き込み中、even: 公開済み。
    let pendingGeneration = ManagedAtomic<Int>(0)

    // MARK: - 初期化

    /// - Parameters:
    ///   - sampleRate: レンダリングのサンプルレート（Hz）。
    ///   - defaultAmplitude: 定常時の基本振幅（0.0〜1.0）。既定は 0.08（lowpass で高域カット
    ///     する分の RMS 補正を含む）。
    ///   - filterCutoffCenter: Lowpass cutoff の中心周波数（Hz）。既定 2000Hz で「雨音」の中域。
    ///   - filterCutoffDepthHz: Lowpass cutoff の LFO 深さ（±Hz）。既定 400Hz。
    ///   - filterLfoPeriodSeconds: Filter cutoff LFO の周期（秒）。既定 11 秒。0 で LFO 無効。
    ///   - envelopePeriodSeconds: Envelope LFO 周期（秒）。0 で無効。Sleep 用途では 30〜60 秒。
    ///   - envelopeDepth: Envelope LFO 深さ。0.075 で出力 0.925〜1.075 範囲に揺れる。0 で無効。
    ///   - envelopeInitialPhase: Envelope LFO 初期位相。Drone と同じ値で同期。
    init(
        sampleRate: Double,
        defaultAmplitude: Float = 0.08,
        filterCutoffCenter: Double = 2000.0,
        filterCutoffDepthHz: Double = 400.0,
        filterLfoPeriodSeconds: Double = 11.0,
        envelopePeriodSeconds: Double = 0.0,
        envelopeDepth: Float = 0.0,
        envelopeInitialPhase: Double = 0.0
    ) {
        self.sampleRate = sampleRate
        self.defaultAmplitude = defaultAmplitude
        self.filterCutoffCenter = filterCutoffCenter
        self.filterCutoffDepthHz = filterCutoffDepthHz
        if filterLfoPeriodSeconds > 0 {
            self.filterLfoPhaseIncrement = 2.0 * Double.pi / (filterLfoPeriodSeconds * sampleRate)
        } else {
            self.filterLfoPhaseIncrement = 0.0
        }
        self.envelopeDepth = envelopeDepth
        if envelopePeriodSeconds > 0 {
            self.envelopePhaseIncrement = 2.0 * Double.pi / (envelopePeriodSeconds * sampleRate)
        } else {
            self.envelopePhaseIncrement = 0.0
        }
        self.envelopePhase = envelopeInitialPhase
    }
}
