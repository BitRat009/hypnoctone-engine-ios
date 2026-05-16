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
/// L/R で独立した PRNG seed と filter state を使い、相関ゼロの真ステレオノイズを生成する。
///
/// ## fade ロジック（odd/even seqlock）
/// `DroneGenerator` と同じプロトコル。詳細は `ToneRenderState` のコメント参照。
@MainActor
final class NoiseGenerator {

    // MARK: - 公開状態

    /// AVAudioEngine に attach する source node。
    let sourceNode: AVAudioSourceNode

    /// この Generator の出力フォーマット（stereo / Float32）。
    /// mono を渡された場合は L/R を平均化して 1ch にダウンミックスして出力する（後方互換）。
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

            // L/R 独立の PRNG state / pink filter state をローカル変数に移す。
            var prngL = state.prngStateLeft
            var prngR = state.prngStateRight
            var b0L = state.b0L, b1L = state.b1L, b2L = state.b2L, b3L = state.b3L
            var b4L = state.b4L, b5L = state.b5L, b6L = state.b6L
            var b0R = state.b0R, b1R = state.b1R, b2R = state.b2R, b3R = state.b3R
            var b4R = state.b4R, b5R = state.b5R, b6R = state.b6R

            // stereo: 2 buffer (L=0, R=1) / mono fallback: 1 buffer に (L+R)/2 を書く。
            let isStereo = ablPointer.count >= 2
            let bufferL = UnsafeMutableBufferPointer<Float>(ablPointer[0])
            let bufferR = isStereo ? UnsafeMutableBufferPointer<Float>(ablPointer[1]) : bufferL

            for frame in 0..<Int(frameCount) {
                // フェード残りがあれば 1 サンプル分だけ target に近づける。
                if framesRemaining > 0 {
                    let step = (target - amplitude) / Float(framesRemaining)
                    amplitude += step
                    framesRemaining -= 1
                } else {
                    amplitude = target
                }

                // ---- L チャネルのピンクノイズ生成 ----
                prngL ^= prngL &<< 13
                prngL ^= prngL &>> 17
                prngL ^= prngL &<< 5
                let whiteL = Float(prngL &>> 8) * invFloat24 - 1.0
                b0L = 0.99886 * b0L + whiteL * 0.0555179
                b1L = 0.99332 * b1L + whiteL * 0.0750759
                b2L = 0.96900 * b2L + whiteL * 0.1538520
                b3L = 0.86650 * b3L + whiteL * 0.3104856
                b4L = 0.55000 * b4L + whiteL * 0.5329522
                b5L = -0.7616 * b5L - whiteL * 0.0168980
                let pinkL = (b0L + b1L + b2L + b3L + b4L + b5L + b6L + whiteL * 0.5362) * 0.11
                b6L = whiteL * 0.115926

                // ---- R チャネルのピンクノイズ生成（独立 PRNG / filter state） ----
                prngR ^= prngR &<< 13
                prngR ^= prngR &>> 17
                prngR ^= prngR &<< 5
                let whiteR = Float(prngR &>> 8) * invFloat24 - 1.0
                b0R = 0.99886 * b0R + whiteR * 0.0555179
                b1R = 0.99332 * b1R + whiteR * 0.0750759
                b2R = 0.96900 * b2R + whiteR * 0.1538520
                b3R = 0.86650 * b3R + whiteR * 0.3104856
                b4R = 0.55000 * b4R + whiteR * 0.5329522
                b5R = -0.7616 * b5R - whiteR * 0.0168980
                let pinkR = (b0R + b1R + b2R + b3R + b4R + b5R + b6R + whiteR * 0.5362) * 0.11
                b6R = whiteR * 0.115926

                let sampleL = pinkL * amplitude
                let sampleR = pinkR * amplitude

                if isStereo {
                    bufferL[frame] = sampleL
                    bufferR[frame] = sampleR
                } else {
                    bufferL[frame] = (sampleL + sampleR) * 0.5
                }
            }

            // 更新後の state を書き戻す。
            state.currentAmplitude = amplitude
            state.activeFadeFramesRemaining = framesRemaining
            state.prngStateLeft = prngL
            state.prngStateRight = prngR
            state.b0L = b0L; state.b1L = b1L; state.b2L = b2L; state.b3L = b3L
            state.b4L = b4L; state.b5L = b5L; state.b6L = b6L
            state.b0R = b0R; state.b1R = b1R; state.b2R = b2R; state.b3R = b3R
            state.b4R = b4R; state.b5R = b5R; state.b6R = b6R
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
