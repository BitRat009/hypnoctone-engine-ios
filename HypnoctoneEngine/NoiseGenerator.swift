import AVFoundation
import Atomics
import os

/// Sleep モード用のピンクノイズを生成する。
///
/// `DroneGenerator` と並列に `mainMixerNode` に attach され、Drone（持続音）の上に
/// ピンクノイズを重ねる音響レイヤー。雨音的な耳触りの良い帯域分布を持ち、
/// Sleep アプリの定番要素として加える。
///
/// 構造・スレッドモデル・fade ロジック（odd/even seqlock）は `DroneGenerator` と同形式。
/// 共通化はせず別クラスとして実装する（3 つ目の Generator が出てきたら refactor 検討）。
///
/// ## スレッドモデル
/// - 構築・fade スケジュールはメインスレッド（`@MainActor` の `AudioEngineController` から呼ばれる）
/// - render block は audio thread（realtime）または main thread（offline）で AVAudioEngine から呼ばれる
/// - render block は `NoiseRenderState` の値を直接 read/write するだけで、Generator 本体のメソッドは呼ばない
///
/// ## ピンクノイズ生成
/// xorshift32 PRNG でホワイトノイズを生成し、Paul Kellet's 7 段 IIR filter で
/// ピンクスペクトラム（約 -3dB/oct）に整形する。係数は定数。
///
/// ## fade ロジック（odd/even seqlock）
/// `DroneGenerator` と同じプロトコル。詳細は `ToneRenderState` のコメント参照。
@MainActor
final class NoiseGenerator {

    // MARK: - 公開状態

    /// AVAudioEngine に attach する source node。
    let sourceNode: AVAudioSourceNode

    /// この Generator の出力フォーマット（mono / Float32）。
    let sourceFormat: AVAudioFormat

    /// 定常時の振幅（フェード完了後の目標値）。
    let defaultAmplitude: Float

    /// レンダリングのサンプルレート（Hz）。fade 持続時間からフレーム数を計算する側で参照する。
    let sampleRate: Double

    // MARK: - 内部

    private let renderState: NoiseRenderState

    private let logger = Logger(
        subsystem: "com.hypnoctone.HypnoctoneEngine",
        category: "NoiseGenerator"
    )

    // MARK: - 初期化

    /// - Parameters:
    ///   - format: source node の出力フォーマット。`AudioEngineController` 側で一度
    ///             生成済みのものを共有する（Drone と同じ format）。
    ///   - defaultAmplitude: 定常時の振幅（0.0〜1.0）。既定は 0.05。
    init(
        format: AVAudioFormat,
        defaultAmplitude: Float = 0.05
    ) {
        self.sourceFormat = format
        self.sampleRate = format.sampleRate
        self.defaultAmplitude = defaultAmplitude
        self.renderState = NoiseRenderState(
            sampleRate: format.sampleRate,
            defaultAmplitude: defaultAmplitude
        )

        // closure 内で参照するために local capture（self を捕捉しない）。
        let state = renderState

        // UInt32 → [-1, 1) Float の変換係数（上位 24bit を Float に乗せる）。
        // Float の有効精度は約 24bit なので、UInt32 全体を割ると下位ビットが捨てられて
        // 分布が崩れる。上位 24bit に切り詰めて精密な一様乱数にする。
        let invFloat24: Float = 2.0 / Float(1 << 24)

        self.sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            isSilence.pointee = false

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            // ---- ブロック先頭で pending command を odd/even seqlock で consume ----
            // プロトコル詳細は ToneRenderState / DroneGenerator のコメントを参照。
            let g1 = state.pendingGeneration.load(ordering: .acquiring)
            if g1 & 1 == 0 && g1 != state.lastConsumedGeneration {
                let newTargetBits = state.pendingTargetAmplitudeBits.load(ordering: .relaxed)
                let newFrames = state.pendingFadeFrames.load(ordering: .relaxed)
                let g2 = state.pendingGeneration.load(ordering: .acquiring)
                if g1 == g2 {
                    state.activeTargetAmplitude = Float(bitPattern: newTargetBits)
                    state.activeFadeFramesRemaining = newFrames
                    state.lastConsumedGeneration = g1
                }
            }

            // ---- 補間ループ（active 状態を audio thread が単一所有） ----
            var amplitude = state.currentAmplitude
            let target = state.activeTargetAmplitude
            var framesRemaining = state.activeFadeFramesRemaining

            // PRNG と pink filter の state をローカル変数に移し、ループ内で更新後に書き戻す。
            var prng = state.prngState
            var b0 = state.b0
            var b1 = state.b1
            var b2 = state.b2
            var b3 = state.b3
            var b4 = state.b4
            var b5 = state.b5
            var b6 = state.b6

            for frame in 0..<Int(frameCount) {
                // フェード残りがあれば 1 サンプル分だけ target に近づける。
                if framesRemaining > 0 {
                    let step = (target - amplitude) / Float(framesRemaining)
                    amplitude += step
                    framesRemaining -= 1
                } else {
                    amplitude = target
                }

                // xorshift32: state を更新して新しい疑似乱数を生成。
                prng ^= prng &<< 13
                prng ^= prng &>> 17
                prng ^= prng &<< 5
                // 上位 24bit を [-1, 1) Float にマップ。
                let white = Float(prng &>> 8) * invFloat24 - 1.0

                // Paul Kellet's pink filter（係数は固定）。
                b0 = 0.99886 * b0 + white * 0.0555179
                b1 = 0.99332 * b1 + white * 0.0750759
                b2 = 0.96900 * b2 + white * 0.1538520
                b3 = 0.86650 * b3 + white * 0.3104856
                b4 = 0.55000 * b4 + white * 0.5329522
                b5 = -0.7616 * b5 - white * 0.0168980
                let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11
                b6 = white * 0.115926

                let sample = pink * amplitude

                for buffer in ablPointer {
                    let bufferPointer = UnsafeMutableBufferPointer<Float>(buffer)
                    bufferPointer[frame] = sample
                }
            }

            // 更新後の state を書き戻す。
            state.currentAmplitude = amplitude
            state.activeFadeFramesRemaining = framesRemaining
            state.prngState = prng
            state.b0 = b0
            state.b1 = b1
            state.b2 = b2
            state.b3 = b3
            state.b4 = b4
            state.b5 = b5
            state.b6 = b6
            return noErr
        }
    }

    // MARK: - フェードスケジュール（odd/even seqlock writer）

    /// fade-in をスケジュールする（現在の振幅から `defaultAmplitude` まで線形上昇）。
    ///
    /// odd/even seqlock writer プロトコル:
    ///   1. gen を **.acquiringAndReleasing** increment → odd（書き込み中マーカー）
    ///   2. target / frames を relaxed store
    ///   3. gen を **.releasing** increment → even（公開済みマーカー）
    /// - Parameter duration: 補間に使う秒数。
    func scheduleFadeIn(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        // begin marker（odd）は .acquiringAndReleasing で後続 payload store の前倒しを防ぐ。
        renderState.pendingGeneration.wrappingIncrement(by: 1, ordering: .acquiringAndReleasing)
        renderState.pendingTargetAmplitudeBits.store(defaultAmplitude.bitPattern, ordering: .relaxed)
        renderState.pendingFadeFrames.store(frames, ordering: .relaxed)
        // end marker（even）は .releasing。これで reader が payload を取りに来る。
        let newGen = renderState.pendingGeneration.wrappingIncrementThenLoad(by: 1, ordering: .releasing)
        logger.info("Noise fade-in scheduled: target=\(self.defaultAmplitude, privacy: .public) frames=\(frames) gen=\(newGen)")
    }

    /// fade-out をスケジュールする（現在の振幅から 0 まで線形下降）。
    /// プロトコルは `scheduleFadeIn(duration:)` と同じ odd/even seqlock writer。
    /// - Parameter duration: 補間に使う秒数。
    func scheduleFadeOut(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        renderState.pendingGeneration.wrappingIncrement(by: 1, ordering: .acquiringAndReleasing)
        renderState.pendingTargetAmplitudeBits.store(Float(0).bitPattern, ordering: .relaxed)
        renderState.pendingFadeFrames.store(frames, ordering: .relaxed)
        let newGen = renderState.pendingGeneration.wrappingIncrementThenLoad(by: 1, ordering: .releasing)
        logger.info("Noise fade-out scheduled: target=0 frames=\(frames) gen=\(newGen)")
    }

    // MARK: - 状態参照

    /// 「鳴らす意図があるか」。最新の schedule が指示した target を見る。
    var hasAudibleTarget: Bool {
        let bits = renderState.pendingTargetAmplitudeBits.load(ordering: .relaxed)
        return Float(bitPattern: bits) > 0.0
    }
}
