import AVFoundation
import os

/// UI から音響処理を分離するためのコントローラ。
///
/// `AVAudioEngine` と `AVAudioSourceNode` を保持し、440Hz のサイン波を
/// リアルタイム生成する。音声ファイル・録音素材・ループ素材は一切使わない。
///
/// 想定する呼び出しスレッド: `start()` / `stop()` / `setVolume(_:)` はメインスレッド
/// （`AudioViewModel` 経由）から呼ぶ。render block のみオーディオスレッドで動く。
///
/// CI モード（環境変数 `CI_AUTOSTART` が設定されている場合）では、CoreAudio HAL
/// に依存しない `enableManualRenderingMode(.offline)` を使い、`start()` が
/// 3 秒分のサイン波を Documents/sine-440hz.wav に書き出す。これは Codemagic 等の
/// headless mac mini で AVAudioEngine がリアルタイム出力できないため
/// （Initialize: RPC timeout で SIGABRT する）。
final class AudioEngineController {

    // MARK: - 動作モード

    /// 動作モード。CI 起動時のみ offline に切り替え、それ以外は realtime。
    enum Mode {
        /// リアルタイムでスピーカに出力する通常モード。
        case realtime
        /// CoreAudio HAL を一切触らず offline で render し、Documents/sine-440hz.wav に書く。
        case offlineToWAV
    }

    // MARK: - 公開状態

    /// エンジンが動作中かどうか。メインスレッドからのみ参照する。
    private(set) var isRunning = false

    /// 現在の動作モード。
    let mode: Mode

    // MARK: - 内部プロパティ

    private let engine = AVAudioEngine()
    private let renderState: ToneRenderState
    private var sourceNode: AVAudioSourceNode?
    private let sourceFormat: AVAudioFormat?

    /// offline モードで manual rendering の有効化に成功したかどうか。
    /// false の場合、`startOfflineRender()` は CoreAudio HAL を触って SIGABRT する
    /// 可能性があるため何もせず return する（fail-closed）。
    private var manualRenderingActive = false

    private let logger = Logger(
        subsystem: "com.hypnoctone.HypnoctoneEngine",
        category: "AudioEngineController"
    )

    /// render block 用の固定サンプルレート。
    /// ハードウェアの実サンプルレートへの変換は `AVAudioEngine` が担う。
    private let renderSampleRate: Double = 44_100.0

    /// マスター音量の初期値（安全な小音量）。
    private let defaultVolume: Float = 0.5

    /// offline モードで一度に render するフレーム数。
    private let offlineMaxFrames: AVAudioFrameCount = 4_096

    /// offline モードで render する総秒数。
    private let offlineRenderSeconds: Double = 3.0

    // MARK: - 初期化

    /// - Parameter frequency: 生成するサイン波の周波数（Hz）。既定は 440Hz。
    /// - Parameter mode: 動作モード。`nil` のとき環境変数 `CI_AUTOSTART` の有無で自動判定。
    init(frequency: Double = 440.0, mode: Mode? = nil) {
        self.renderState = ToneRenderState(
            frequency: frequency,
            sampleRate: renderSampleRate
        )
        let resolvedMode: Mode
        if let mode = mode {
            resolvedMode = mode
        } else {
            resolvedMode = ProcessInfo.processInfo.environment["CI_AUTOSTART"] != nil
                ? .offlineToWAV
                : .realtime
        }
        self.mode = resolvedMode

        // 1ch / 44.1kHz / Float32 標準フォーマットをソース・manual rendering 両方で使い回す。
        self.sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: renderSampleRate,
            channels: 1
        )

        // offline モードでは attach / connect の前に manual rendering を有効化する必要がある。
        // realtime モードでは何もしない（mainMixerNode は通常通り outputNode 経由でハードウェアへ）。
        if resolvedMode == .offlineToWAV, let format = sourceFormat {
            do {
                try engine.enableManualRenderingMode(
                    .offline,
                    format: format,
                    maximumFrameCount: offlineMaxFrames
                )
                manualRenderingActive = true
                logger.info("manual rendering mode を有効化しました (offline)。")
            } catch {
                manualRenderingActive = false
                logger.error("manual rendering mode の有効化に失敗: \(error.localizedDescription, privacy: .public)")
                // fail-closed: 有効化失敗時はオーディオグラフ構築も engine.start() も行わない。
                // ここで return することで、その後の startOfflineRender() でも guard により短絡する。
                return
            }
        }

        buildAudioGraph()
    }

    // MARK: - 再生制御

    /// 再生（または offline render）を開始する。
    /// すでに動作中の場合は何もしない。
    func start() {
        guard !isRunning else { return }

        switch mode {
        case .realtime:
            startRealtime()
        case .offlineToWAV:
            startOfflineRender()
        }
    }

    /// エンジンを停止する。
    /// 停止してもオーディオグラフは破棄しないため、再度 `start()` で再生を再開できる。
    func stop() {
        guard isRunning else { return }

        engine.stop()
        isRunning = false
        logger.info("AVAudioEngine を停止しました。")

        if mode == .realtime {
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: [.notifyOthersOnDeactivation]
                )
            } catch {
                logger.error("AVAudioSession の無効化に失敗: \(error.localizedDescription, privacy: .public)")
            }
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

    // MARK: - realtime 起動

    /// `AVAudioSession` を有効化し、エンジンを realtime で開始する。
    private func startRealtime() {
        guard configureAudioSession() else { return }

        do {
            try engine.start()
            isRunning = true
            logger.info("AVAudioEngine を realtime で開始しました。")
        } catch {
            isRunning = false
            logger.error("AVAudioEngine の開始に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - offline render

    /// engine を manual rendering で start し、Documents/sine-440hz.wav に書き出す。
    /// AVAudioSession は触らない（CoreAudio HAL を回避するため）。
    private func startOfflineRender() {
        // fail-closed: manual rendering が有効化されていない状態で engine.start() を呼ぶと
        // CoreAudio HAL を触りに行き、Codemagic のような headless mac では SIGABRT する。
        guard manualRenderingActive else {
            logger.error("manual rendering が有効化されていないため offline render を中止します。")
            return
        }
        guard let format = sourceFormat else {
            logger.error("sourceFormat が無いため offline render を中止します。")
            return
        }

        do {
            try engine.start()
            isRunning = true
            logger.info("AVAudioEngine を offline で開始しました。")
        } catch {
            logger.error("AVAudioEngine の offline 開始に失敗: \(error.localizedDescription, privacy: .public)")
            return
        }

        defer {
            engine.stop()
            isRunning = false
            logger.info("offline render が完了しました。")
        }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let outputURL = documentsURL?.appendingPathComponent("sine-440hz.wav") else {
            logger.error("Documents ディレクトリの解決に失敗しました。")
            return
        }
        // 古いファイルが残っていると AVAudioFile init が EXIST で失敗するので消す。
        try? FileManager.default.removeItem(at: outputURL)

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: renderSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            logger.error("AVAudioFile の生成に失敗: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else {
            logger.error("AVAudioPCMBuffer の生成に失敗しました。")
            return
        }

        let totalFrames = AVAudioFrameCount(renderSampleRate * offlineRenderSeconds)
        var rendered: AVAudioFrameCount = 0
        // `.cannotDoInCurrentContext` は一過性のステータスなので一定回数まで retry を許す。
        var transientRetries = 0
        let maxTransientRetries = 32
        // `.success` で frameLength == 0 が続くと無限ループするので連続 0 回数も上限を設ける。
        var zeroFrameRetries = 0
        let maxZeroFrameRetries = 8

        while rendered < totalFrames {
            let remaining = totalFrames - rendered
            let toRender = min(buffer.frameCapacity, remaining)
            do {
                let status = try engine.renderOffline(toRender, to: buffer)
                switch status {
                case .success:
                    if buffer.frameLength == 0 {
                        zeroFrameRetries += 1
                        if zeroFrameRetries >= maxZeroFrameRetries {
                            logger.error("renderOffline: frameLength=0 が連続 \(maxZeroFrameRetries) 回。中断。")
                            return
                        }
                        continue
                    }
                    zeroFrameRetries = 0
                    transientRetries = 0
                    try audioFile.write(from: buffer)
                    rendered += buffer.frameLength
                case .cannotDoInCurrentContext:
                    transientRetries += 1
                    if transientRetries >= maxTransientRetries {
                        logger.error("renderOffline: cannotDoInCurrentContext が連続 \(maxTransientRetries) 回。中断。")
                        return
                    }
                    continue
                case .insufficientDataFromInputNode:
                    logger.error("renderOffline: insufficientDataFromInputNode で中断。")
                    return
                case .error:
                    logger.error("renderOffline: error で中断。")
                    return
                @unknown default:
                    logger.error("renderOffline: 未知のステータス \(status.rawValue) で中断。")
                    return
                }
            } catch {
                logger.error("renderOffline / write 失敗: \(error.localizedDescription, privacy: .public)")
                return
            }
            _ = format
        }

        logger.info("WAV を書き出しました: \(outputURL.path, privacy: .public) (frames: \(rendered))")
    }

    // MARK: - セットアップ

    /// オーディオグラフを構築する。初期化時に一度だけ呼ぶ。
    /// realtime / offline どちらでも同じグラフ（mono 44.1kHz Float32）を使う。
    private func buildAudioGraph() {
        guard let format = sourceFormat else {
            logger.error("ソースフォーマットの生成に失敗しました。")
            return
        }

        let node = makeSourceNode(format: format)
        self.sourceNode = node

        engine.attach(node)
        // `mainMixerNode` へアクセスすると outputNode への接続が自動生成される。
        // manual rendering mode が有効ならハードウェアではなく manual output に向く。
        engine.connect(node, to: engine.mainMixerNode, format: format)
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
