import AVFoundation
import os

/// UI から音響処理を分離するためのコントローラ。
///
/// `AVAudioEngine` と `AVAudioSourceNode` を保持し、440Hz のサイン波を
/// リアルタイム生成する。音声ファイル・録音素材・ループ素材は一切使わない。
///
/// ## 想定する呼び出しスレッド
/// クラス全体を `@MainActor` で隔離し、`start()` / `stop()` / `setVolume(_:)` を含む
/// 全 public/internal メソッドはメインスレッドからのみ呼ぶ。render block のみ
/// オーディオスレッドで動くが、render block 内では `ToneRenderState` の値を
/// 直接読み書きするだけで本クラスのメソッドは呼ばない。
///
/// ## フェード（Task 5）
/// `start()` で 0.8 秒の fade-in、`stop()` で 0.8 秒の fade-out を行う。
/// サンプル単位の線形補間を `ToneRenderState` の `currentAmplitude` に対して
/// render block 内で行う。`stop()` は fade-out 完了まで待ってから engine を止めるため
/// 内部で `Task { @MainActor in ... }` を起動し、`Task.sleep(0.8s)` 後に engine.stop()。
/// fade-out 中に `start()` が呼ばれた場合は保留中の停止タスクを取り消す。
/// Stop 連打時のレース対策として世代番号（`stopGeneration`）で識別する。
///
/// ## CI モード
/// 環境変数 `CI_AUTOSTART` が設定されている場合、CoreAudio HAL に依存しない
/// `enableManualRenderingMode(.offline)` を使い、`start()` が
/// 「fade-in → 定常 → fade-out」を含む WAV を Documents/sine-440hz.wav に書き出す。
/// Codemagic 等の headless mac mini で AVAudioEngine がリアルタイム出力できない
/// （Initialize: RPC timeout で SIGABRT する）対策。
@MainActor
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

    /// エンジンが動作中かどうか。
    /// fade-out 中は `true` のままで、engine.stop() 完了後に `false` になる。
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

    /// fade-out 完了を待ってから engine を止めるための保留タスク。
    private var pendingStopTask: Task<Void, Never>?

    /// Stop 連打時のレース解消用世代番号。
    /// `stop()` を呼ぶたびにインクリメントし、Task は自分の世代がまだ最新かを確認してから finalize する。
    private var stopGeneration: Int = 0

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

    /// offline モードで render する総秒数（fade-in + 定常 + fade-out）。
    /// fade-in 0.8s + 定常 2.4s + fade-out 0.8s = 4.0s。
    private let offlineRenderSeconds: Double = 4.0

    /// fade-in の所要秒数。
    private let fadeInSeconds: Double = 0.8

    /// fade-out の所要秒数。
    private let fadeOutSeconds: Double = 0.8

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
                return
            }
        }

        buildAudioGraph()
    }

    // MARK: - 再生制御

    /// 再生を開始する（realtime: fade-in 開始、offline: fadeIn→定常→fadeOut の WAV を書く）。
    /// fade-out 中に呼ばれた場合は保留中の停止タスクを取り消し、現在地点から fade-in に切り替える。
    func start() {
        switch mode {
        case .realtime:
            startRealtime()
        case .offlineToWAV:
            startOfflineRender()
        }
    }

    /// 再生を停止する（fade-out → engine.stop() → AVAudioSession 無効化）。
    /// 同期的に戻るが、実際の停止は約 `fadeOutSeconds` 秒後に完了する。
    /// fade-out 中に `start()` が呼ばれたら停止はキャンセルされる。
    func stop() {
        guard isRunning else { return }
        // offline は自己完結ライフサイクル。外部からの stop は無視。
        guard mode == .realtime else { return }

        // 既存の保留停止を取り消して、最新の stop を採用する。
        pendingStopTask?.cancel()
        // 世代番号を更新し、この stop に対応する Task だけが finalize できるようにする。
        stopGeneration &+= 1
        let myGeneration = stopGeneration

        scheduleFadeOut()

        pendingStopTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.fadeOutSeconds * 1_000_000_000))
            } catch {
                // Task が cancel された = 再 start or 新しい stop が走った。finalize しない。
                return
            }
            // 自分が「最新の stop」でないなら finalize しない（連打レース対策）。
            guard myGeneration == self.stopGeneration else {
                self.logger.info("stop generation 不一致。finalize をスキップ (mine=\(myGeneration), latest=\(self.stopGeneration))。")
                return
            }
            // さらに二重チェック: 再 start で target が 0 でなくなっていれば finalize しない。
            if self.renderState.targetAmplitude > 0.0 {
                self.logger.info("fade-out 中に再 start を検知 (target>0)。engine.stop() をスキップ。")
                return
            }
            self.finalizeRealtimeStop()
        }
    }

    /// マスター音量を設定する。
    /// `mainMixerNode.outputVolume` への代入はフレームワーク側で滑らかに補間されるため、
    /// 値を急に変えてもクリックノイズが出にくい。
    /// - Parameter value: 音量（0.0〜1.0）。範囲外の値はクランプする。
    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0.0), 1.0)
        engine.mainMixerNode.outputVolume = clamped
    }

    // MARK: - realtime 起動

    /// `AVAudioSession` を有効化し、エンジンを realtime で開始し、fade-in を仕掛ける。
    /// 既に動作中（fade-out 中含む）なら保留 stop を取り消して fade-in を再仕掛けるだけ。
    private func startRealtime() {
        // fade-out 中の再 start を受け取れるよう、保留 stop を取り消す。
        pendingStopTask?.cancel()
        pendingStopTask = nil

        if !isRunning {
            guard configureAudioSession() else { return }
            do {
                try engine.start()
                isRunning = true
                logger.info("AVAudioEngine を realtime で開始しました。")
            } catch {
                isRunning = false
                logger.error("AVAudioEngine の開始に失敗: \(error.localizedDescription, privacy: .public)")
                return
            }
        } else {
            logger.info("既に再生中 / fade-out 中。fade-in に切り替えます。")
        }

        scheduleFadeIn()
    }

    /// fade-out 完了後の engine 停止と session 無効化。
    /// `@MainActor` 隔離下で呼ばれるため、AVAudioEngine / AVAudioSession の API は安全。
    private func finalizeRealtimeStop() {
        engine.stop()
        isRunning = false
        logger.info("fade-out 完了、AVAudioEngine を停止しました。")

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            logger.error("AVAudioSession の無効化に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - フェードスケジュール

    /// fade-in をスケジュールする（現在の振幅から `defaultAmplitude` まで線形に上昇）。
    /// render thread は `fadeFramesRemaining` フレームで `targetAmplitude` へ近づけて行く。
    /// メインスレッドは render state の現在値（`currentAmplitude` 等）を読まない設計。
    private func scheduleFadeIn() {
        renderState.targetAmplitude = renderState.defaultAmplitude
        renderState.fadeFramesRemaining = max(1, Int(renderSampleRate * fadeInSeconds))
        logger.info("fade-in 開始: target=\(self.renderState.defaultAmplitude, privacy: .public) frames=\(self.renderState.fadeFramesRemaining)")
    }

    /// fade-out をスケジュールする（現在の振幅から 0 まで線形に下降）。
    private func scheduleFadeOut() {
        renderState.targetAmplitude = 0.0
        renderState.fadeFramesRemaining = max(1, Int(renderSampleRate * fadeOutSeconds))
        logger.info("fade-out 開始: target=0 frames=\(self.renderState.fadeFramesRemaining)")
    }

    // MARK: - offline render

    /// engine を manual rendering で start し、fade-in → 定常 → fade-out の WAV を書き出す。
    /// AVAudioSession は触らない（CoreAudio HAL を回避するため）。
    private func startOfflineRender() {
        guard manualRenderingActive else {
            logger.error("manual rendering が有効化されていないため offline render を中止します。")
            return
        }
        guard sourceFormat != nil else {
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

        // 0 秒地点で fade-in を仕掛ける。
        scheduleFadeIn()

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

        // fade-out 開始地点（総尺 - fade-out 秒数）。
        // render block 内のスナップショット遅延（最大 frameCapacity フレーム）を吸収するため、
        // 総フレーム数に余裕（+ frameCapacity）を足して fade-out が確実に 0 へ到達するようにする。
        let baseTotalFrames = AVAudioFrameCount(renderSampleRate * offlineRenderSeconds)
        let totalFrames = baseTotalFrames + buffer.frameCapacity
        let fadeOutStartFrame = AVAudioFrameCount(renderSampleRate * (offlineRenderSeconds - fadeOutSeconds))
        var rendered: AVAudioFrameCount = 0
        var fadeOutScheduled = false
        var transientRetries = 0
        let maxTransientRetries = 32
        var zeroFrameRetries = 0
        let maxZeroFrameRetries = 8

        while rendered < totalFrames {
            // fade-out 開始地点を越えたら一度だけ scheduleFadeOut。
            if !fadeOutScheduled && rendered >= fadeOutStartFrame {
                scheduleFadeOut()
                fadeOutScheduled = true
            }

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
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = defaultVolume
        engine.prepare()
    }

    /// サイン波を生成する `AVAudioSourceNode` を作る。
    ///
    /// render block 内ではアロケーション・ロック・I/O・UI 更新を行わない。
    /// `renderState` を強参照でキャプチャするが、`renderState` は他オブジェクトを
    /// 参照しないため循環参照は発生しない（`self` はキャプチャしない）。
    ///
    /// ## 振幅補間（fade）
    /// メインスレッドは `targetAmplitude` と `fadeFramesRemaining` だけを書き換える。
    /// render thread はサンプル単位に `(target - current) / framesRemaining` で increment を
    /// 計算し、`current` を `target` へ近づける。`framesRemaining` を 1 ずつ減らし、0 で
    /// 補間を止めて `target` に張り付く。これにより 1 ブロック中の target 変更にも自然に追従し、
    /// 累積誤差で target を越えることもない。
    private func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        let state = renderState

        return AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
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
