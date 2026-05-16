import AVFoundation
import Combine
import os

/// UI から音響処理を分離するためのコントローラ。
///
/// `AVAudioEngine` のライフサイクル管理（start / stop / fade スケジューリング）と
/// `AVAudioSession` の設定を担う。実際のサンプル生成は `DroneGenerator` 3 声
/// （rootNote + 5度 + オクターブ、平均律 12 TET、L/R 微小 detune、各声に独立 LFO で pitch vibrato、
///  各声に第 2 / 第 3 倍音で楽器的温かみ）と
/// `NoiseGenerator`（ピンクノイズ + 雨音風 lowpass + cutoff LFO、L/R 独立 PRNG/filter）に委譲し、
/// `mainMixerNode` で並列ミックスする。全 generator に同じ envelope LFO（37 秒周期 / ±7.5%）を
/// 適用して「全体が一緒に呼吸」する呼吸感を作る。
/// 周波数は `Note` (MIDI 番号ベース) で扱い、UI に音名 (A3 / E4 / A4 等) を表示できる
/// 基盤を持つ (Task 15)。
/// 出力フォーマットは 2ch stereo（Task 10 から）。
/// 音声ファイル・録音素材・ループ素材は一切使わない。
///
/// ## 想定する呼び出しスレッド
/// クラス全体を `@MainActor` で隔離し、`start()` / `stop()` / `setVolume(_:)` を含む
/// 全 public/internal メソッドはメインスレッドからのみ呼ぶ。render block のみ
/// オーディオスレッドで動くが、render block 内では各 generator の内部 state を
/// 直接読み書きするだけで本クラスのメソッドは呼ばない。
///
/// ## フェード（Task 5 / Task 8 / Task 9）
/// `start()` で 0.8 秒の fade-in、`stop()` で 0.8 秒の fade-out を行う。
/// fade は多声 `DroneGenerator` 全てと `NoiseGenerator` に同期的に仕掛ける
/// （UX 上 Sleep モード全体の fade として揃える）。
/// 補間ロジックは各 generator の render block 内。`stop()` は fade-out 完了まで
/// 待ってから engine を止めるため `Task { @MainActor in ... }` を内部で起動し、
/// `Task.sleep(0.8s)` 後に engine.stop()。fade-out 中に `start()` が呼ばれた場合は
/// 保留中の停止タスクを取り消す。Stop 連打時のレース対策として世代番号
/// （`stopGeneration`）で識別する。
///
/// ## CI モード
/// 環境変数 `CI_AUTOSTART` が設定されている場合、CoreAudio HAL に依存しない
/// `enableManualRenderingMode(.offline)` を使い、`start()` が
/// 「fade-in → 定常 → fade-out」を含む WAV を Documents/sleep-mix.wav に書き出す。
/// WAV には Drone 3 声（A3 220 / E4 329.63 / A4 440 Hz、平均律、L/R 微小 detune）+ Noise（ピンクノイズ、L/R 独立）が
/// mixer でミックスされた 2ch stereo として記録される。
/// Codemagic 等の headless mac mini で AVAudioEngine がリアルタイム出力できない
/// （Initialize: RPC timeout で SIGABRT する）対策。
@MainActor
final class AudioEngineController: ObservableObject {

    // MARK: - 動作モード

    /// 動作モード。CI 起動時のみ offline に切り替え、それ以外は realtime。
    enum Mode {
        /// リアルタイムでスピーカに出力する通常モード。
        case realtime
        /// CoreAudio HAL を一切触らず offline で render し、Documents/sleep-mix.wav に書く。
        case offlineToWAV
    }

    // MARK: - 公開状態

    /// エンジンが動作中かどうか。
    /// fade-out 中は `true` のままで、engine.stop() 完了後に `false` になる。
    private(set) var isRunning = false

    /// 現在の動作モード。
    let mode: Mode

    /// 現在の root note。Drone 3 声はこの note を基準に [+0, +7, +12] semitone で展開される。
    let rootNote: Note

    /// 現在のスケール (将来の generative pitch selection で参照)。
    let scale: Scale

    /// 現在鳴っている Drone 3 声の note 群（UI 表示用、Task 16 から動的に変化）。
    /// 初期値は [root, root+7 (5th), root+12 (octave)]。PitchScheduler が時間軸で
    /// 候補リストから選び直すたびに更新される。
    @Published private(set) var currentDroneNotes: [Note]

    // MARK: - PitchScheduler (Task 16: ATMÓS 化 Step 2 — generative pitch selection)

    /// 各 voice の note 候補リスト。PitchScheduler がここから「現在 note を除いた」中から
    /// ランダム選択する。3 voices (root / 5th / octave) × 4 候補。Scale 内に収める設計。
    private let pitchCandidates: [[Note]]

    /// 各 voice の pitch 切替 interval（秒）。素数寄りで揃わない（Task 11 LFO と同じ思想）。
    /// CI (offlineToWAV) モードでは × 0.1 にして 4 秒 WAV 内で 2-3 回切替を観測できるようにする。
    private let pitchIntervals: [Double] = [19.0, 23.0, 13.0]

    /// Pitch 切替の glide 時間（秒）。realtime は 3 秒の遅い補間、CI は 0.5 秒で速く確認。
    private let pitchGlideSeconds: Double

    /// 各 voice 独立の pitch 更新 Task（start で起動、stop で cancel）。
    private var pitchUpdateTasks: [Task<Void, Never>] = []

    // MARK: - 内部プロパティ

    private let engine = AVAudioEngine()

    /// Sleep モード基底音を担う Drone（持続音）生成器の配列。
    /// 多声構成（root / root+7semitone / root+12semitone = 基音 + 完全 5度 + オクターブ）で
    /// 和音的な厚みを出す。Task 15 で平均律 (12 TET) に統一（後の generative pitch selection
    /// で「スケール内任意の音切替」と整合させるため）。純正律時の 1.5 ratio から
    /// 平均律 2^(7/12) ≈ 1.4983 に変わり 5度で 0.4Hz 程度の差が出るが、Sleep の LFO/envelope
    /// 揺らぎに紛れて聴感差は小さい想定。
    private let droneGenerators: [DroneGenerator]

    /// Sleep モードで Drone に重ねるピンクノイズ生成器。
    /// `mainMixerNode` で Drone と並列にミックスされる。
    private let noiseGenerator: NoiseGenerator

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

    /// - Parameter rootNote: Drone 多声構成の基音 (root)。既定は A3 (= 220Hz)。
    ///   Drone 3 声は [root, root+7semi (5度), root+12semi (octave)] で展開される。
    /// - Parameter scale: 音階 (将来の generative pitch selection で参照)。
    ///   既定は A Major Pentatonic (ATMÓS と同じ Sleep 向け定番)。
    /// - Parameter mode: 動作モード。`nil` のとき環境変数 `CI_AUTOSTART` の有無で自動判定。
    init(
        rootNote: Note = Note(name: "A3") ?? Note(midiNumber: 57),
        scale: Scale = .majorPentatonic,
        mode: Mode? = nil
    ) {
        self.rootNote = rootNote
        self.scale = scale
        // 3 声構成: root / root+7semi (5度) / root+12semi (octave)。これが起動時の初期 note。
        let droneIntervals = [0, 7, 12]
        let initialDroneNotes = droneIntervals.map { Note(midiNumber: rootNote.midiNumber + $0) }
        self.currentDroneNotes = initialDroneNotes

        // Pitch 候補リスト: 各 voice の音域を保ったまま Scale 内 (A Major Pentatonic) からランダム選択する。
        // ATMÓS 観察と同じ「voice ごとの音域固定 + 候補内で動的選択」設計。
        // A Major Pentatonic = A, B, C#, E, F# の 5 音から各 voice の音域内 4 つを抜粋。
        //
        // **Step 2 制約**: `rootNote` (default A3) と `scale` (default majorPentatonic) を
        // 公開 init で受けているが、現状この候補リストは A3 + majorPentatonic 固定で
        // ベタ書きしている。別 root/scale を渡すと初期 droneNotes と候補リストのキーが
        // ずれるので注意。将来 Step 2.5+ で `Scale.notes(root:octaves:)` と音域フィルタで
        // 動的構築に切り替える予定 (Codex Task 16 Medium 指摘)。
        self.pitchCandidates = [
            // root voice (中音域: A3 周辺)
            ["A3", "B3", "C#4", "E4"].compactMap(Note.init(name:)),
            // 5th voice (中高音域: E4 周辺)
            ["E4", "F#4", "A4", "B4"].compactMap(Note.init(name:)),
            // octave voice (高音域: A4 周辺)
            ["A4", "B4", "C#5", "E5"].compactMap(Note.init(name:)),
        ]
        let resolvedMode: Mode
        if let mode = mode {
            resolvedMode = mode
        } else {
            resolvedMode = ProcessInfo.processInfo.environment["CI_AUTOSTART"] != nil
                ? .offlineToWAV
                : .realtime
        }
        self.mode = resolvedMode
        // CI モードでは glide も短く（0.5s）、realtime は 3s の落ち着いた補間。
        self.pitchGlideSeconds = resolvedMode == .offlineToWAV ? 0.5 : 3.0

        // 2ch (stereo) / 44.1kHz / Float32 標準フォーマット。
        // Task 10 で stereo 化: 各 Drone は L/R で detune したサイン波、Noise は L/R 独立 PRNG。
        // 標準パラメータなので実用上 nil にならないが、念のため fatalError でガード。
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: renderSampleRate,
            channels: 2
        ) else {
            fatalError("AVAudioFormat(standardFormatWithSampleRate: \(renderSampleRate), channels: 2) returned nil")
        }

        // Generator を先に作る（engine の rendering mode とは独立に source node を構築できる）。
        // 多声 Drone: 基音 / 完全 5度 / オクターブ。振幅は基音強め、上倍音を弱めて
        // 自然な厚みを作る。
        //
        // 各声に異なる LFO（pitch vibrato）周期・深さ・初期位相を割り当て、
        // 3 声のゆらぎが揃わない（時間軸で複雑に変化し続ける）ようにする。周期は素数寄りの
        // 13.7 / 17.3 / 23.1 秒で、互いに約分しにくい比のため聴感上の繰り返しが目立たない。
        //
        // Headroom 評価（Task 14 で envelope LFO ±7.5% multiplier 追加）:
        //   - Drone 3 声 × （基音 + 第2倍音 0.2 + 第3倍音 0.1）= 0.28 × 1.3 = 0.364
        //   - Noise は Paul Kellet's filter + lowpass の統計信号 ≈ 0.08
        //   - 合算 ≈ 0.4 → envelope multiplier 最大 1.075 で 0.43 前後
        //   - mainMixer outputVolume 0.5 を経由するので最終的に 0.22 前後
        // 16bit s16le 換算 (32767) でも余裕がある見込み。CI の WAV 検査でクリッピング無しを実測確認する。
        //
        // 倍音設定: 第 2 倍音 (× 2) を基音の 20%、第 3 倍音 (× 3) を 10%。
        // 偶数 + 奇数の自然な組み合わせで、ハーモニウム / オルガン系の温かみを出す。
        let harmonics: [(Double, Float)] = [(2.0, 0.2), (3.0, 0.1)]

        // Envelope LFO（呼吸感）: 全 generator 共通の 37 秒周期 / ±7.5%。
        // pitch LFO（13〜23秒）よりさらに遅い超低周波で、Sleep アプリ全体が一緒に呼吸する。
        //
        // 同期の仕組み: 各 generator は独立した envelopePhase を持つが、同じ周期・初期位相で
        // 初期化し、各 render block が同じ frame 数分だけ phase を進めることで実用上同期する。
        // これは AVAudioEngine が「同一 mixer に並列接続された source node に同じ pull 履歴で
        // 同じ frame 数を要求する」という現行構成での想定に依存する。将来 format converter や
        // node bypass、サブグラフ分岐が入る場合は「共有 sample clock から sin を計算」または
        // 「mixer 後段に 1 つの共通 envelope」へ移行する必要がある。
        let envelopePeriod: Double = 37.0
        let envelopeDepth: Float = 0.075
        let envelopeInitialPhase: Double = 0.0

        // initialDroneNotes[0]=root, [1]=5度, [2]=octave。各 frequency は Note が
        // 平均律 (12 TET) で計算 (A3=220Hz, E4=329.63Hz, A4=440Hz)。
        self.droneGenerators = [
            DroneGenerator(
                format: format, frequency: initialDroneNotes[0].frequency,
                lfoPeriodSeconds: 17.3, lfoDepthCents: 2.5, lfoInitialPhase: 0.0,
                harmonics: harmonics,
                envelopePeriodSeconds: envelopePeriod, envelopeDepth: envelopeDepth,
                envelopeInitialPhase: envelopeInitialPhase,
                defaultAmplitude: 0.15
            ),
            DroneGenerator(
                format: format, frequency: initialDroneNotes[1].frequency,
                lfoPeriodSeconds: 23.1, lfoDepthCents: 2.0, lfoInitialPhase: .pi / 2,
                harmonics: harmonics,
                envelopePeriodSeconds: envelopePeriod, envelopeDepth: envelopeDepth,
                envelopeInitialPhase: envelopeInitialPhase,
                defaultAmplitude: 0.08
            ),
            DroneGenerator(
                format: format, frequency: initialDroneNotes[2].frequency,
                lfoPeriodSeconds: 13.7, lfoDepthCents: 1.5, lfoInitialPhase: .pi,
                harmonics: harmonics,
                envelopePeriodSeconds: envelopePeriod, envelopeDepth: envelopeDepth,
                envelopeInitialPhase: envelopeInitialPhase,
                defaultAmplitude: 0.05
            ),
        ]
        // Noise: 雨音風 lowpass + cutoff LFO + Drone と同期する envelope LFO。
        self.noiseGenerator = NoiseGenerator(
            format: format,
            defaultAmplitude: 0.08,
            filterCutoffCenter: 2000.0,
            filterCutoffDepthHz: 400.0,
            filterLfoPeriodSeconds: 11.0,
            envelopePeriodSeconds: envelopePeriod,
            envelopeDepth: envelopeDepth,
            envelopeInitialPhase: envelopeInitialPhase
        )

        // offline モードでは attach / connect の前に manual rendering を有効化する必要がある。
        // realtime モードでは何もしない（mainMixerNode は通常通り outputNode 経由でハードウェアへ）。
        if resolvedMode == .offlineToWAV {
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
    /// - Returns: 成功した場合 true、失敗した場合 false。
    ///            呼び出し側（`AudioViewModel`）は false 時に `isPlaying` を up しないことで
    ///            UI と engine の整合性を保つ。`@discardableResult` は将来「結果を見ない直接呼び出し」
    ///            （ユニットテストなど）のために付けている。
    @discardableResult
    func start() -> Bool {
        switch mode {
        case .realtime:
            return startRealtime()
        case .offlineToWAV:
            return startOfflineRender()
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
        stopPitchScheduler()

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
            // さらに二重チェック: 再 start で target が audible に戻っていれば finalize しない。
            // 多声 Drone のいずれか、または Noise が audible なら fade-out 中ではない（再 start 後）。
            let anyDroneAudible = self.droneGenerators.contains(where: { $0.hasAudibleTarget })
            if anyDroneAudible || self.noiseGenerator.hasAudibleTarget {
                self.logger.info("fade-out 中に再 start を検知 (hasAudibleTarget)。engine.stop() をスキップ。")
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
    /// - Returns: 起動に成功した場合 true、`AVAudioSession` 有効化または `engine.start()` が失敗した場合 false。
    private func startRealtime() -> Bool {
        // fade-out 中の再 start を受け取れるよう、保留 stop を取り消す。
        pendingStopTask?.cancel()
        pendingStopTask = nil

        if !isRunning {
            guard configureAudioSession() else { return false }
            do {
                try engine.start()
                isRunning = true
                logger.info("AVAudioEngine を realtime で開始しました。")
            } catch {
                isRunning = false
                logger.error("AVAudioEngine の開始に失敗: \(error.localizedDescription, privacy: .public)")
                return false
            }
        } else {
            logger.info("既に再生中 / fade-out 中。fade-in に切り替えます。")
        }

        scheduleFadeIn()
        startPitchScheduler()
        return true
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

    /// fade-in を全 Drone 声と Noise に依頼する。
    /// 各 generator は独立した state を持つが、UX 上は「Sleep モード全体の fade-in」として揃える。
    private func scheduleFadeIn() {
        for drone in droneGenerators {
            drone.scheduleFadeIn(duration: fadeInSeconds)
        }
        noiseGenerator.scheduleFadeIn(duration: fadeInSeconds)
    }

    /// fade-out を全 Drone 声と Noise に依頼する。
    private func scheduleFadeOut() {
        for drone in droneGenerators {
            drone.scheduleFadeOut(duration: fadeOutSeconds)
        }
        noiseGenerator.scheduleFadeOut(duration: fadeOutSeconds)
    }

    // MARK: - PitchScheduler (Task 16)

    /// 各 voice 用に独立した Task を起動し、interval ごとに `advanceVoicePitch(at:)` を呼ぶ。
    /// realtime モード専用。offline モードでは render ループ内で frame counter で代替する
    /// （Task.sleep は renderOffline 同期ループ中に進まないため）。
    private func startPitchScheduler() {
        guard mode == .realtime else { return }
        stopPitchScheduler()
        for i in 0..<droneGenerators.count {
            let interval = pitchIntervals[i]
            let task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch {
                        return  // cancel された
                    }
                    guard let self = self, !Task.isCancelled else { return }
                    self.advanceVoicePitch(at: i)
                }
            }
            pitchUpdateTasks.append(task)
        }
        logger.info("PitchScheduler 起動 (\(self.pitchIntervals.count) voices)")
    }

    /// 全 voice の pitch 更新 Task を cancel して配列をクリア。
    private func stopPitchScheduler() {
        for task in pitchUpdateTasks {
            task.cancel()
        }
        pitchUpdateTasks.removeAll()
    }

    /// 指定 voice の次の pitch を「現在 note を除く候補から」ランダム選択し、generator に
    /// setFrequency(glideSeconds:) で渡す。`currentDroneNotes[i]` も更新して @Published 経由
    /// で UI 通知。
    private func advanceVoicePitch(at i: Int) {
        guard i < pitchCandidates.count, i < droneGenerators.count else { return }
        let candidates = pitchCandidates[i]
        let current = currentDroneNotes[i]
        let alternatives = candidates.filter { $0 != current }
        guard let next = alternatives.randomElement() else { return }
        droneGenerators[i].setFrequency(next.frequency, glideSeconds: pitchGlideSeconds)
        currentDroneNotes[i] = next
        logger.info("Voice[\(i)] pitch: \(current.name, privacy: .public) → \(next.name, privacy: .public)")
    }

    // MARK: - offline render

    /// engine を manual rendering で start し、fade-in → 定常 → fade-out の WAV を書き出す。
    /// AVAudioSession は触らない（CoreAudio HAL を回避するため）。
    /// - Returns: WAV を最後まで書ききった場合 true、途中失敗時 false。
    private func startOfflineRender() -> Bool {
        guard manualRenderingActive else {
            logger.error("manual rendering が有効化されていないため offline render を中止します。")
            return false
        }

        do {
            try engine.start()
            isRunning = true
            logger.info("AVAudioEngine を offline で開始しました。")
        } catch {
            logger.error("AVAudioEngine の offline 開始に失敗: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // 成功 / 中断のどちらでも engine は止める。defer 内で文言を分けるため flag を保持。
        var renderSucceeded = false
        defer {
            engine.stop()
            isRunning = false
            if renderSucceeded {
                logger.info("offline render が正常に完了しました。")
            } else {
                logger.error("offline render が途中中断のまま engine を停止しました。")
            }
        }

        // 0 秒地点で fade-in を仕掛ける。
        scheduleFadeIn()

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let outputURL = documentsURL?.appendingPathComponent("sleep-mix.wav") else {
            logger.error("Documents ディレクトリの解決に失敗しました。")
            return false
        }
        // 古いファイルが残っていると AVAudioFile init が EXIST で失敗するので消す。
        try? FileManager.default.removeItem(at: outputURL)

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: renderSampleRate,
            AVNumberOfChannelsKey: 2, // stereo (L/R 独立)
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
            return false
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else {
            logger.error("AVAudioPCMBuffer の生成に失敗しました。")
            return false
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

        // ---- inline PitchScheduler (offline 専用、Task 16) ----
        // CI モードでは pitchIntervals は本来 19/23/13s だが、4 秒 WAV では発火しない。
        // ×0.1 = 1.9/2.3/1.3s で 4 秒 WAV 内に 2-3 回発火させて generative 効果を CI で実証。
        // realtime Task scheduler は startOfflineRender 内では使えない (同期ループで sleep 不可)。
        let offlinePitchScale = 0.1
        let pitchUpdateFrameIntervals: [AVAudioFrameCount] = pitchIntervals.map {
            AVAudioFrameCount(renderSampleRate * $0 * offlinePitchScale)
        }
        var nextPitchUpdateFrames: [AVAudioFrameCount] = pitchUpdateFrameIntervals

        while rendered < totalFrames {
            // fade-out 開始地点を越えたら一度だけ scheduleFadeOut。
            if !fadeOutScheduled && rendered >= fadeOutStartFrame {
                scheduleFadeOut()
                fadeOutScheduled = true
            }

            // inline PitchScheduler: 各 voice の次の update frame を越えたら advance。
            for i in 0..<droneGenerators.count {
                if rendered >= nextPitchUpdateFrames[i] {
                    advanceVoicePitch(at: i)
                    nextPitchUpdateFrames[i] += pitchUpdateFrameIntervals[i]
                }
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
                            return false
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
                        return false
                    }
                    continue
                case .insufficientDataFromInputNode:
                    logger.error("renderOffline: insufficientDataFromInputNode で中断。")
                    return false
                case .error:
                    logger.error("renderOffline: error で中断。")
                    return false
                @unknown default:
                    logger.error("renderOffline: 未知のステータス \(status.rawValue) で中断。")
                    return false
                }
            } catch {
                logger.error("renderOffline / write 失敗: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        logger.info("WAV を書き出しました: \(outputURL.path, privacy: .public) (frames: \(rendered))")
        renderSucceeded = true
        return true
    }

    // MARK: - セットアップ

    /// オーディオグラフを構築する。初期化時に一度だけ呼ぶ。
    /// 多声 Drone（基音/5度/オクターブ）と Noise の sourceNode をすべて attach し、
    /// `mainMixerNode` に並列接続する（複数 source → mixer の和音構成）。
    private func buildAudioGraph() {
        // 全 generator が共有する format（`droneGenerators` の各要素も同じ format で構築済み）。
        let format = noiseGenerator.sourceFormat

        for drone in droneGenerators {
            engine.attach(drone.sourceNode)
            // `mainMixerNode` へアクセスすると outputNode への接続が自動生成される。
            // manual rendering mode が有効ならハードウェアではなく manual output に向く。
            // 複数 source を同じ mixer に connect するとフレームワーク側でミックスされる。
            engine.connect(drone.sourceNode, to: engine.mainMixerNode, format: format)
        }
        engine.attach(noiseGenerator.sourceNode)
        engine.connect(noiseGenerator.sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = defaultVolume
        engine.prepare()
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
