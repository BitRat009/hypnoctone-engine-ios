import AVFoundation
import os

/// UI から音響処理を分離するためのコントローラ。
///
/// `AVAudioEngine` と `AVAudioSourceNode` を保持し、440Hz のサイン波を
/// リアルタイム生成する。音声ファイル・録音素材・ループ素材は一切使わない。
///
/// 想定する呼び出しスレッド: `start()` / `stop()` / `setVolume(_:)` はメインスレッド
/// （`AudioViewModel` 経由）から呼ぶ。render block のみオーディオスレッドで動く。
final class AudioEngineController {

    // MARK: - 公開状態

    /// エンジンが動作中かどうか。メインスレッドからのみ参照する。
    private(set) var isRunning = false

    // MARK: - 内部プロパティ

    private let engine = AVAudioEngine()
    private let renderState: ToneRenderState
    private var sourceNode: AVAudioSourceNode?

    private let logger = Logger(
        subsystem: "com.hypnoctone.HypnoctoneEngine",
        category: "AudioEngineController"
    )

    /// render block 用の固定サンプルレート。
    /// ハードウェアの実サンプルレートへの変換は `AVAudioEngine` が担う。
    private let renderSampleRate: Double = 44_100.0

    /// マスター音量の初期値（安全な小音量）。
    private let defaultVolume: Float = 0.5

    // MARK: - 初期化

    /// - Parameter frequency: 生成するサイン波の周波数（Hz）。既定は 440Hz。
    init(frequency: Double = 440.0) {
        self.renderState = ToneRenderState(
            frequency: frequency,
            sampleRate: renderSampleRate
        )
        buildAudioGraph()
    }

    // MARK: - 再生制御

    /// `AVAudioSession` を有効化し、エンジンを開始する。
    /// すでに動作中の場合は何もしない。
    func start() {
        guard !isRunning else { return }

        guard configureAudioSession() else {
            return
        }

        do {
            try engine.start()
            isRunning = true
            logger.info("AVAudioEngine を開始しました。")
        } catch {
            isRunning = false
            logger.error("AVAudioEngine の開始に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// エンジンを停止し、`AVAudioSession` を無効化する。
    /// 停止してもオーディオグラフは破棄しないため、再度 `start()` で再生を再開できる。
    func stop() {
        guard isRunning else { return }

        engine.stop()
        isRunning = false
        logger.info("AVAudioEngine を停止しました。")

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            logger.error("AVAudioSession の無効化に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// マスター音量を設定する。
    ///
    /// `AudioViewModel`（`@MainActor`）経由でメインスレッドから呼ばれる想定。
    /// `mainMixerNode.outputVolume` への代入はフレームワーク側で滑らかに補間されるため、
    /// 値を急に変えてもクリックノイズが出にくい。
    /// - Parameter value: 音量（0.0〜1.0）。範囲外の値はクランプする。
    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0.0), 1.0)
        engine.mainMixerNode.outputVolume = clamped
    }

    // MARK: - セットアップ

    /// オーディオグラフを構築する。初期化時に一度だけ呼ぶ。
    private func buildAudioGraph() {
        guard let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: renderSampleRate,
            channels: 1
        ) else {
            logger.error("ソースフォーマットの生成に失敗しました。")
            return
        }

        let node = makeSourceNode(format: sourceFormat)
        self.sourceNode = node

        engine.attach(node)
        // `mainMixerNode` へアクセスすると outputNode への接続が自動生成される。
        // モノラル → ステレオ、44.1kHz → ハードウェアレートの変換はエンジンが行う。
        engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
        engine.mainMixerNode.outputVolume = defaultVolume
        engine.prepare()
    }

    /// サイン波を生成する `AVAudioSourceNode` を作る。
    ///
    /// render block 内ではアロケーション・ロック・I/O・UI 更新を行わない。
    /// `renderState` を強参照でキャプチャするが、`renderState` は他オブジェクトを
    /// 参照しないため循環参照は発生しない（`self` はキャプチャしない）。
    private func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        let state = renderState

        return AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            // 無音ではなく実際に信号を生成していることを明示する。
            isSilence.pointee = false

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            let amplitude = state.amplitude
            let increment = state.phaseIncrement
            let twoPi = state.twoPi
            var phase = state.phase

            for frame in 0..<Int(frameCount) {
                let sample = Float(sin(phase)) * amplitude
                phase += increment
                if phase >= twoPi {
                    phase -= twoPi
                }
                for buffer in ablPointer {
                    let bufferPointer = UnsafeMutableBufferPointer<Float>(buffer)
                    bufferPointer[frame] = sample
                }
            }

            state.phase = phase
            return noErr
        }
    }

    /// `AVAudioSession` を `.playback` カテゴリで設定し、有効化する。
    /// - Returns: 設定に成功した場合は `true`。失敗時はログを出して `false` を返す。
    private func configureAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            return true
        } catch {
            logger.error("AVAudioSession の設定に失敗: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
