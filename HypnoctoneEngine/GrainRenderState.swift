import Foundation
import Atomics

/// 1 つの grain（粒）の状態。短い windowed サイン波として再生される。
/// audio thread が固定容量プール `GrainRenderState.activeGrains` の要素として
/// 単一所有で読み書きする。`framesRemaining == 0` のスロットが「空きプール」を表す。
struct Grain {
    /// 現在の位相（ラジアン）。
    var phase: Double
    /// 1 サンプルあたりの位相増分（ラジアン）。
    var phaseIncrement: Double
    /// 残りフレーム数。0 ならこのスロットは inactive（空き）。
    /// 1 frame ごとにデクリメントされ、cosine window 計算にも使う。
    var framesRemaining: Int
    /// 全フレーム数（window 形状計算用、`framesRemaining` の初期値）。
    var totalFrames: Int
    /// 出力チャネル。0 = L のみ / 1 = R のみ。
    /// L/R 別 trigger なので「両方」は通常使わないが、enum ではなく Int で持つことで
    /// audio thread の分岐コストを最小化する。
    var channel: Int
}

/// 粒状音響（granular synthesis）の状態を保持するクラス。
///
/// `GrainGenerator` の内部実装として使われる。`AVAudioSourceNode` の render block と
/// メインスレッド（fade スケジュール）の両方から参照される。
/// render block はリアルタイムのオーディオスレッドで実行されるため、
/// アロケーション・ロック・I/O を行わず、単純な数値の読み書きだけに留める。
///
/// ## スレッドモデル
///
/// `ToneRenderState` / `NoiseRenderState` と同じ「pending / active 分離 + odd/even seqlock」
/// を fade コマンドに採用。grain pool 自体は audio thread 単一所有のため atomic 不要。
///
/// 1. **Audio thread 単一所有**
///    - fade: `currentAmplitude`, `activeTargetAmplitude`, `activeFadeFramesRemaining`, `lastConsumedGeneration`
///    - PRNG（L/R 独立）: `prngStateLeft`, `prngStateRight`（xorshift32 の state）
///    - grain pool: `activeGrains`（固定容量配列、in-place 更新）
///    - 次 trigger までの frame カウンタ: `framesUntilNextTriggerLeft`, `framesUntilNextTriggerRight`
///    - Envelope LFO 位相: `envelopePhase`
///
/// 2. **Main writer / Audio reader（pending command）** — 全 atomic
///    - `pendingTargetAmplitudeBits` / `pendingFadeFrames` / `pendingGeneration`
///
/// 3. **定数**
///    - `sampleRate`, `defaultAmplitude`, `twoPi`, `grainDurationFrames`,
///      `meanInterTriggerFrames`, `pitchPhaseIncrements[]`, `maxActiveGrains`
///
/// ## Grain 生成プロトコル
///
/// 各 sample で `framesUntilNextTrigger{L,R}--` を行い、0 になったら新 grain を生成する。
/// 「次 trigger までの frame 数」は trigger 時に `mean × (0.5 + random)` で更新する。
/// 0.5〜1.5 倍の uniform 揺らぎで、本物の Poisson 過程 (指数分布) ではない。
/// `-log` は trigger 時のみなので realtime 負荷上の理由ではなく、uniform 揺らぎを採用するのは
/// 実装簡素化 + 「cluster (短時間に複数 trigger) を抑制して Sleep 用途で聴感を安定させる」狙い。
/// exponential 分布は短間隔に偏るため Sleep には不向き。
///
/// 新 grain の配置: `activeGrains` を線形走査して `framesRemaining == 0` の最初のスロットを
/// 上書きする。プールが満杯の場合は trigger を捨てる（音響的には「同時発音数 cap」で問題なし）。
///
/// ## Window
///
/// cosine bell window: `window(t) = 0.5 × (1 - cos(2π × t / totalFrames))`
/// `t = 0` で 0、中央で 1。`t = totalFrames - 1` の最終 sample は厳密 0 ではないが
/// `(total-1)/total` ≈ 1 のため値は微小（grain 60ms / 44.1kHz で約 7e-7）。
/// クリックノイズは聴感上問題にならない水準で、分母を `total-1` にする厳密化はしていない。
/// `t = totalFrames - framesRemaining` で進行度を計算するため totalFrames を保持する。
///
/// ## Pitch
///
/// `pitchPhaseIncrements[]` の中から trigger 時に random index で選ぶ（uniform）。
/// Sleep 用途の高音域 sparkle なので、scale 内の C#5/E5/A5/F#5 等 4 候補程度を想定。
/// 各 grain は固定 pitch（生存中に変化しない）。
final class GrainRenderState {

    // MARK: - 定数

    /// レンダリングに使うサンプルレート（Hz）。
    let sampleRate: Double

    /// 2π（位相 1 周）。
    let twoPi: Double = 2.0 * Double.pi

    /// 定常状態の基本振幅（grain 1 個あたりの最大振幅）。同時 N 個で peak は N 倍まで可能。
    let defaultAmplitude: Float

    /// 1 つの grain のフレーム数（duration × sampleRate）。
    let grainDurationFrames: Int

    /// trigger 間隔の平均フレーム数（`sampleRate / expectedTriggersPerSecond`）。
    /// 実際の trigger 間隔は `mean × (0.5 + random)` の uniform 揺らぎを掛けて Poisson 過程を
    /// 近似する。
    let meanInterTriggerFrames: Double

    /// trigger 時に選択する pitch 候補（phaseIncrement = 2π × freq / sampleRate）。
    /// 配列要素数は通常 2〜8 程度。各 grain は uniform random で選んだ index に固定。
    let pitchPhaseIncrements: [Double]

    /// 同時 active grain の最大数。プール固定容量。
    /// 8 程度あれば 60ms grain × 2 triggers/sec の最大重なり (0.06 × 2 × 2 = 0.24 同時稼働) より
    /// 十分余裕。超えた trigger は捨てる。
    let maxActiveGrains: Int

    // MARK: - 定数 — Envelope LFO（全体音量ゆらぎ / 呼吸感）

    /// Envelope LFO 深さ（multiplier の振幅）。0 で envelope 無効。
    let envelopeDepth: Float

    /// Envelope LFO の 1 サンプルあたり位相増分（ラジアン）。
    /// `2π / (envelopePeriodSeconds × sampleRate)`。Drone と同じ値で同期して呼吸する。
    let envelopePhaseIncrement: Double

    // MARK: - Audio thread 単一所有 — fade

    var currentAmplitude: Float = 0.0
    var activeTargetAmplitude: Float = 0.0
    var activeFadeFramesRemaining: Int = 0
    var lastConsumedGeneration: Int = 0

    // MARK: - Audio thread 単一所有 — PRNG (L/R 独立)

    /// L チャネル trigger 判定 + pitch 選択用 xorshift32 state。0 以外で初期化。
    var prngStateLeft: UInt32 = 0xBADDCAFE

    /// R チャネル用 xorshift32 state。L と別 seed。
    var prngStateRight: UInt32 = 0xFEEDFACE

    // MARK: - Audio thread 単一所有 — Grain pool

    /// 固定容量の grain プール。`framesRemaining == 0` が空きスロット。
    /// audio thread が線形走査して新 grain を配置 / 既存 grain を進める。
    var activeGrains: [Grain]

    /// 次の L channel trigger までの残りフレーム数。0 になったら trigger を打って次間隔を決める。
    /// 初期値は `Int(meanInterTriggerFrames)`（fade-in 後しばらく経ってから最初の trigger）。
    var framesUntilNextTriggerLeft: Int

    /// 次の R channel trigger までの残りフレーム数。L と独立。
    var framesUntilNextTriggerRight: Int

    // MARK: - Audio thread 単一所有 — Envelope LFO

    /// Envelope LFO の現在位相（ラジアン）。Drone と同じ初期位相・周期で同期。
    var envelopePhase: Double

    // MARK: - Main writer / Audio reader（pending command, 全 atomic）

    /// 次の fade で目指す振幅（Float bitPattern）。odd/even seqlock writer プロトコル。
    let pendingTargetAmplitudeBits = ManagedAtomic<UInt32>(0)

    /// 次の fade で使う総フレーム数。
    let pendingFadeFrames = ManagedAtomic<Int>(0)

    /// fade コマンドの世代番号。odd: writer 書き込み中、even: 公開済み。
    let pendingGeneration = ManagedAtomic<Int>(0)

    // MARK: - 初期化

    /// - Parameters:
    ///   - sampleRate: レンダリングのサンプルレート（Hz）。
    ///   - defaultAmplitude: grain 1 個あたりの最大振幅。同時 N 個で peak は最大 N 倍。
    ///   - grainDurationSeconds: 1 grain の長さ（秒）。0.04〜0.10 程度が自然な「粒」感。
    ///   - expectedTriggersPerSecond: 1 channel あたり 1 秒間の期待 trigger 数。
    ///     Sleep 用途では 0.5〜2.0（疎な「ぽつり」感）。
    ///   - pitchFrequencies: 候補 pitch（Hz）。各 grain は trigger 時に uniform random で選ぶ。
    ///   - maxActiveGrains: 同時 active grain の最大数。プール容量。
    ///   - envelopePeriodSeconds: Envelope LFO 周期（秒）。0 で無効。Drone と揃えて同期。
    ///   - envelopeDepth: Envelope LFO 深さ。
    ///   - envelopeInitialPhase: Envelope LFO 初期位相。
    init(
        sampleRate: Double,
        defaultAmplitude: Float = 0.04,
        grainDurationSeconds: Double = 0.06,
        expectedTriggersPerSecond: Double = 1.0,
        pitchFrequencies: [Double] = [554.37, 659.26, 739.99, 880.00],
        maxActiveGrains: Int = 8,
        envelopePeriodSeconds: Double = 0.0,
        envelopeDepth: Float = 0.0,
        envelopeInitialPhase: Double = 0.0
    ) {
        precondition(maxActiveGrains > 0, "GrainRenderState: maxActiveGrains must be > 0")
        precondition(!pitchFrequencies.isEmpty, "GrainRenderState: pitchFrequencies must not be empty")
        precondition(grainDurationSeconds > 0, "GrainRenderState: grainDurationSeconds must be > 0")
        precondition(expectedTriggersPerSecond > 0, "GrainRenderState: expectedTriggersPerSecond must be > 0")

        self.sampleRate = sampleRate
        self.defaultAmplitude = defaultAmplitude
        self.grainDurationFrames = max(1, Int(grainDurationSeconds * sampleRate))
        self.meanInterTriggerFrames = sampleRate / expectedTriggersPerSecond
        self.maxActiveGrains = maxActiveGrains
        self.pitchPhaseIncrements = pitchFrequencies.map { 2.0 * Double.pi * $0 / sampleRate }
        // プールは inactive (framesRemaining=0) で初期化。
        self.activeGrains = Array(
            repeating: Grain(phase: 0.0, phaseIncrement: 0.0, framesRemaining: 0, totalFrames: 0, channel: 0),
            count: maxActiveGrains
        )
        // 初期値: mean をベースに L/R で異なる初期 offset を与え、最初の trigger が
        // 同時にならないようにする（小さい初期 phase 差で stereo の独立性を強める）。
        self.framesUntilNextTriggerLeft = Int(meanInterTriggerFrames * 0.6)
        self.framesUntilNextTriggerRight = Int(meanInterTriggerFrames * 1.1)

        self.envelopeDepth = envelopeDepth
        if envelopePeriodSeconds > 0 {
            self.envelopePhaseIncrement = 2.0 * Double.pi / (envelopePeriodSeconds * sampleRate)
        } else {
            self.envelopePhaseIncrement = 0.0
        }
        self.envelopePhase = envelopeInitialPhase
    }
}
