import AVFoundation
import os

/// Sleep モード基底音となる Drone（持続音）を生成する。
///
/// 現段階では単一周波数のサイン波を生成するだけ。将来的に倍音や微妙な
/// モジュレーション、複数声の重ね合わせを加える余地を残した分離レイヤー。
/// `AudioEngineController` がこの Generator を保持し、`AVAudioEngine` に attach する。
///
/// ## スレッドモデル
/// - 構築・fade スケジュールはメインスレッド（`@MainActor` の `AudioEngineController` から呼ばれる）
/// - render block は audio thread（realtime）または main thread（offline）で AVAudioEngine から呼ばれる
/// - render block は `ToneRenderState` の値を直接 read/write するだけで、Generator 本体のメソッドは呼ばない
///
/// ## fade ロジック（pending/active 分離）
/// `scheduleFadeIn(duration:)` / `scheduleFadeOut(duration:)` でメインスレッドが
/// **pending 領域** に新しい fade コマンドを書く（target → frames → generation の順）。
/// render block はブロック先頭で pending を atomically consume して **active 領域** に転記し、
/// 実際の補間は active 領域に対して行う。詳細は `ToneRenderState` のコメント参照。
@MainActor
final class DroneGenerator {

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

    private let renderState: ToneRenderState

    private let logger = Logger(
        subsystem: "com.hypnoctone.HypnoctoneEngine",
        category: "DroneGenerator"
    )

    // MARK: - 初期化

    /// - Parameters:
    ///   - format: source node の出力フォーマット。`AudioEngineController` 側で一度
    ///             生成済みのものを共有する（manual rendering でも同じ format を使う）。
    ///   - frequency: 生成するサイン波の周波数（Hz）。既定は 220Hz (A3)。
    ///                Sleep モード方針として 440Hz より低めの落ち着いた音域を採用。
    ///   - defaultAmplitude: 定常時の振幅（0.0〜1.0）。既定は小音量の 0.2。
    init(
        format: AVAudioFormat,
        frequency: Double = 220.0,
        defaultAmplitude: Float = 0.2
    ) {
        self.sourceFormat = format
        self.sampleRate = format.sampleRate
        self.defaultAmplitude = defaultAmplitude
        self.renderState = ToneRenderState(
            frequency: frequency,
            sampleRate: format.sampleRate,
            defaultAmplitude: defaultAmplitude
        )

        // closure 内で参照するために local capture（self を捕捉しない）。
        let state = renderState

        self.sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            isSilence.pointee = false

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            // ---- ブロック先頭で pending command を best-effort で consume ----
            //
            // 1. pendingGeneration を読む
            // 2. lastConsumedGeneration と異なれば新しいコマンドあり（と推定）
            // 3. target / frames を読む
            // 4. pendingGeneration を再度読む
            // 5. 1 回目と 2 回目が一致 → 「main が書き込み中ではなさそう」と判断、active に転記
            // 6. 不一致 → main が書き込み中、このブロックは skip（active を据え置き、次ブロックで retry）
            //
            // 注: これは Swift の memory model 上は厳密な atomic publication ではない。
            // store-store 並べ替えで gen が値より先に observable になると、stale payload を
            // accept する穴が残る（詳細は ToneRenderState のコメント参照）。
            // 実用上は許容、厳密化したい時は Swift Atomics 導入で対応する。
            let gen1 = state.pendingGeneration
            if gen1 != state.lastConsumedGeneration {
                let newTarget = state.pendingTargetAmplitude
                let newFrames = state.pendingFadeFrames
                let gen2 = state.pendingGeneration
                if gen1 == gen2 {
                    state.activeTargetAmplitude = newTarget
                    state.activeFadeFramesRemaining = newFrames
                    state.lastConsumedGeneration = gen1
                }
                // gen1 != gen2 の場合は何もしない（次ブロックで再試行される）
            }

            // ---- 補間ループ（active 状態を audio thread が単一所有） ----
            let phaseIncrement = state.phaseIncrement
            let twoPi = state.twoPi
            var phase = state.phase
            var amplitude = state.currentAmplitude
            let target = state.activeTargetAmplitude
            var framesRemaining = state.activeFadeFramesRemaining

            for frame in 0..<Int(frameCount) {
                // フェード残りがあれば 1 サンプル分だけ target に近づける。
                if framesRemaining > 0 {
                    let step = (target - amplitude) / Float(framesRemaining)
                    amplitude += step
                    framesRemaining -= 1
                } else {
                    amplitude = target
                }

                let sample = Float(sin(phase)) * amplitude
                phase += phaseIncrement
                if phase >= twoPi {
                    phase -= twoPi
                }
                for buffer in ablPointer {
                    let bufferPointer = UnsafeMutableBufferPointer<Float>(buffer)
                    bufferPointer[frame] = sample
                }
            }

            state.phase = phase
            state.currentAmplitude = amplitude
            state.activeFadeFramesRemaining = framesRemaining
            return noErr
        }
    }

    // MARK: - フェードスケジュール（pending 領域に書く）

    /// fade-in をスケジュールする（現在の振幅から `defaultAmplitude` まで線形上昇）。
    /// pending 領域に新しいコマンドを書き、generation を最後にインクリメントする。
    /// - Parameter duration: 補間に使う秒数。フレーム数は内部で `sampleRate * duration` から計算。
    func scheduleFadeIn(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        // 書き込み順序が重要: target → frames → generation の順。
        // generation を最後に書くことで、audio thread が「コマンドが揃った」と判断できる。
        renderState.pendingTargetAmplitude = defaultAmplitude
        renderState.pendingFadeFrames = frames
        renderState.pendingGeneration &+= 1
        logger.info("Drone fade-in scheduled: target=\(self.defaultAmplitude, privacy: .public) frames=\(frames) gen=\(self.renderState.pendingGeneration)")
    }

    /// fade-out をスケジュールする（現在の振幅から 0 まで線形下降）。
    /// - Parameter duration: 補間に使う秒数。
    func scheduleFadeOut(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        renderState.pendingTargetAmplitude = 0.0
        renderState.pendingFadeFrames = frames
        renderState.pendingGeneration &+= 1
        logger.info("Drone fade-out scheduled: target=0 frames=\(frames) gen=\(self.renderState.pendingGeneration)")
    }

    // MARK: - 状態参照

    /// 「鳴らす意図があるか」。最新の schedule が指示した target を見る
    /// （audio thread の補間進行とは独立に「ユーザー意図」を表す）。
    /// `AudioEngineController` が fade-out 中に再 start が走ったかを検知する用途で使う。
    var hasAudibleTarget: Bool {
        renderState.pendingTargetAmplitude > 0.0
    }
}
