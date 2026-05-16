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
///    - L/R 独立 PRNG により、左右で相関ゼロの真ステレオピンクノイズを生成する。
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
    let defaultAmplitude: Float

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
    ///   - defaultAmplitude: 定常時の基本振幅（0.0〜1.0）。既定は 0.05（Drone 0.2 の 1/4）。
    init(sampleRate: Double, defaultAmplitude: Float = 0.05) {
        self.sampleRate = sampleRate
        self.defaultAmplitude = defaultAmplitude
    }
}
