import AVFoundation
import os

/// Sleep モード基底音となる Drone（持続音）を生成する。
///
/// 現段階では単一周波数のサイン波を生成するだけ。将来的に倍音や微妙な
/// モジュレーション、複数声の重ね合わせを加える余地を残した分離レイヤー。
/// `AudioEngineController` がこの Generator を保持し、`AVAudioEngine` に attach する。
///
/// ## スレッドモデル
/// - 構築・fade スケジュールは `@MainActor` の `AudioEngineController` から呼ばれる
/// - render block は audio thread（realtime）または main thread（offline）で AVAudioEngine から呼ばれる
/// - render block は `ToneRenderState` の値を直接 read/write するだけで、Generator 本体のメソッドは呼ばない
///
/// ## fade ロジック
/// `scheduleFadeIn(durationFrames:)` / `scheduleFadeOut(durationFrames:)` で
/// メインスレッドが目標振幅と残りフレーム数を設定する。実際のサンプル単位補間は
/// `AVAudioSourceNode` の render block 内で行う。詳細は `ToneRenderState` のコメント参照。
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
        // renderState は class なので参照渡し、書き換えは render block 経由で行われる。
        let state = renderState

        self.sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            isSilence.pointee = false

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            let phaseIncrement = state.phaseIncrement
            let twoPi = state.twoPi
            var phase = state.phase

            // ブロック先頭で fade 状態をスナップショット。
            var amplitude = state.currentAmplitude
            let target = state.targetAmplitude
            var framesRemaining = state.fadeFramesRemaining

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
            state.fadeFramesRemaining = framesRemaining
            return noErr
        }
    }

    // MARK: - フェードスケジュール

    /// fade-in をスケジュールする（現在の振幅から `defaultAmplitude` まで線形上昇）。
    /// - Parameter duration: 補間に使う秒数。フレーム数は内部で `sampleRate * duration` から計算。
    func scheduleFadeIn(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        renderState.targetAmplitude = defaultAmplitude
        renderState.fadeFramesRemaining = frames
        logger.info("Drone fade-in: target=\(self.defaultAmplitude, privacy: .public) frames=\(frames)")
    }

    /// fade-out をスケジュールする（現在の振幅から 0 まで線形下降）。
    /// - Parameter duration: 補間に使う秒数。フレーム数は内部で `sampleRate * duration` から計算。
    func scheduleFadeOut(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        renderState.targetAmplitude = 0.0
        renderState.fadeFramesRemaining = frames
        logger.info("Drone fade-out: target=0 frames=\(frames)")
    }

    // MARK: - 状態参照

    /// 目標振幅が 0 より大きい（=「鳴らすつもり」状態）。
    /// `AudioEngineController` が fade-out 中に再 start が走ったかを検知する用途で使う。
    /// 音量そのものではなく「鳴らす意図があるか」を意味する API。
    var hasAudibleTarget: Bool {
        renderState.targetAmplitude > 0.0
    }
}
