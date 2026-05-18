import AVFoundation
import Combine
import os

/// UI から音響処理を分離するためのコントローラ。
///
/// `AVAudioEngine` のライフサイクル管理（start / stop / fade スケジューリング）と
/// `AVAudioSession` の設定を担う。実際のサンプル生成は `DroneGenerator` 4 声
/// （sub bass + rootNote + 5度 + オクターブ、平均律 12 TET、L/R 微小 detune、各声に独立 LFO で
///  pitch vibrato、各声に第 2 / 第 3 倍音で楽器的温かみ）と
/// `NoiseGenerator`（ピンクノイズ + 雨音風 lowpass + cutoff LFO、L/R 独立 PRNG/filter）と
/// `GrainGenerator`（粒状音響: 短い windowed サイン波を疎にトリガ、L/R 独立、scale 内の高音域
///  4 候補から sample-and-hold で pitch 選択）に委譲し、`mainMixerNode` で並列ミックスする。
/// 全 generator に同じ envelope LFO（37 秒周期 / ±7.5%）を適用して「全体が一緒に呼吸」する
/// 呼吸感を作る。
/// 周波数は `Note` (MIDI 番号ベース) で扱い、UI に音名 (A3 / E4 / A4 等) を表示できる
/// 基盤を持つ (Task 15)。デフォルト音域は A1 / A3 / E4 / A4 (55 / 220 / 329.63 / 440 Hz)、
/// 倍音 ×2/×3 で更に上の帯域までカバー。
/// Task 16 で generative pitch selection を実装したが、聴感調整 (テルミン感) のためユーザー判断で
/// 現在は **OFF** にしている (`generativePitchEnabled = false`)。コード基盤は残っており、
/// flag を反転すれば即復活する。
/// Task 17 で `AVAudioUnitReverb` を mainMixer の後段に挟み、ATMÓS 的な空間的な広がりを付与
/// (factoryPreset = .largeHall, wetDryMix = 40)。音色や音域は変えず、空間だけ拡張する方針。
/// Task 18 で sub bass (A1 = 55Hz, amp 0.05) を 4 声目として先頭に追加し、ATMÓS 的な重心の低い
/// 空間を作る。sub の倍音 (110Hz / 165Hz) が root (220Hz) と自然に音響的に接続する。
/// Task 19 で GrainGenerator (粒状音響) を追加。Drone/Noise の上に高音域 (C#5/E5/F#5/A5) の
/// 短い「粒」を疎にトリガし、ATMÓS 的な「ぽつりぽつりと光る音」を重ねる。reverb tail と
/// 組み合わせて「shimmer」感を作る。
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
/// 「fade-in → 定常 → fade-out + reverb tail」を含む WAV を Documents/sleep-mix.wav に書き出す。
/// WAV には Drone 4 声（A1 55 / A3 220 / E4 329.63 / A4 440 Hz 固定、平均律、L/R 微小 detune）
/// + Noise（ピンクノイズ、L/R 独立）+ Grain（C#5/E5/F#5/A5 から sample-and-hold、L/R 独立 trigger）
/// が mixer でミックスされ、AVAudioUnitReverb (.largeHall) を通った 2ch stereo として記録される。
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

    /// VoiceGroup → mute 対応 generator を統一的に扱うための薄いラッパー。
    /// DroneGenerator と GrainGenerator は protocol を共有していないため、
    /// 関連値で 1 段抽象化する（NoiseGenerator は voice group に紐付かないため含めない）。
    ///
    /// `@MainActor` 必須: `setMuted` / `isMuted` は `@MainActor` 隔離の Generator メソッドを呼ぶため
    /// ネスト enum 自体も `@MainActor` で囲まないと Swift 5.7+ で isolation 違反コンパイルエラーに
    /// なる（Codex Task 20 ビルドエラー診断指摘）。
    @MainActor
    private enum VoiceMutable {
        case drone(DroneGenerator)
        case grain(GrainGenerator)

        func setMuted(_ muted: Bool) {
            switch self {
            case .drone(let g): g.setMuted(muted)
            case .grain(let g): g.setMuted(muted)
            }
        }

        var isMuted: Bool {
            switch self {
            case .drone(let g): return g.isMuted
            case .grain(let g): return g.isMuted
            }
        }
    }

    // MARK: - Voice グループ (Task 20)

    /// ATMÓS 風の 4 voice グループ。UI から各グループを mute / unmute するための識別子。
    /// 内部の generator マッピングは:
    ///   - `.tone`: droneGenerators[2] (E4) + droneGenerators[3] (octave A4) を統合した中高域メロディ位置
    ///   - `.drone`: droneGenerators[1] (root A3) の持続音
    ///   - `.sub`: droneGenerators[0] (sub bass A1) の重低音
    ///   - `.grain`: grainGenerator の高音域 shimmer
    /// Noise は ATMÓS UI に対応する voice グループが無いため背景レイヤーとして
    /// 常時 ON 扱い（UI 上の mute 対象外）。
    enum VoiceGroup: String, CaseIterable {
        case tone
        case drone
        case sub
        case grain

        /// UI 表示用の短いラベル（ATMÓS と同じ大文字表記）。
        var label: String {
            switch self {
            case .tone:  return "TONE"
            case .drone: return "DRONE"
            case .sub:   return "SUB"
            case .grain: return "GRAIN"
            }
        }
    }

    // MARK: - 公開状態

    /// エンジンが動作中かどうか。
    /// fade-out 中は `true` のままで、engine.stop() 完了後に `false` になる。
    /// Task 21 で @Published 化: UI 側 (AudioViewModel.canChangeMode) が fade-out 完了を
    /// 待ってからモード切替を有効化するため (Codex Task 21 High 指摘)。
    @Published private(set) var isRunning = false

    /// 現在の動作モード。
    let mode: Mode

    /// 現在の root note。Drone 4 声はこの note を基準に [-24, +0, +7, +12] semitone で展開される
    /// (Task 18 で sub bass A1 を追加)。`rootNote.midiNumber >= 24` を満たす必要がある
    /// (sub voice が MIDI 範囲 0..<128 に収まるため)。
    let rootNote: Note

    /// 現在のスケール (将来の generative pitch selection で参照)。
    let scale: Scale

    /// 現在鳴っている Drone 4 声の note 群（UI 表示用、Task 16 から動的に変化）。
    /// 初期値は [root-24 (sub), root, root+7 (5th), root+12 (octave)]。PitchScheduler が
    /// 時間軸で候補リストから選び直すたびに更新される。
    @Published private(set) var currentDroneNotes: [Note]

    /// 現在のモード (Task 21, ATMÓS 風 4 モード切替)。
    /// デフォルトは `.sleep` (Task 20 までの動作と互換)。
    /// 切替は `setMode(_:)` で行うが、現状は Stop 状態でのみ可能 (engine 動作中は ignore + 警告ログ)。
    @Published private(set) var currentMode: Mode = .sleep

    // MARK: - PitchScheduler (Task 16: ATMÓS 化 Step 2 — generative pitch selection)

    /// 各 voice の note 候補リスト。PitchScheduler がここから「現在 note を除いた」中から
    /// ランダム選択する。4 voices (sub / root / 5th / octave) × 4 候補。Scale 内に収める設計。
    private let pitchCandidates: [[Note]]

    /// 各 voice の pitch 切替 interval（秒）。互いに約分しにくい値で揃わない（Task 11 LFO と同じ思想）。
    /// CI (offlineToWAV) モードでは × 0.1 にして 4 秒 WAV 内で 2-3 回切替を観測できるようにする。
    /// Task 18 で sub voice 用に 31.0s を先頭追加 (一番ゆっくり変化)。
    private let pitchIntervals: [Double] = [31.0, 19.0, 23.0, 13.0]

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

    /// Task 19: 粒状音響（granular synthesis）生成器。短い windowed サイン波を疎にトリガし、
    /// Drone + Noise の上に高音域の shimmer を重ねる。`mainMixerNode` で並列ミックス。
    /// reverb tail と組み合わせて ATMÓS 的な「ぽつりと光る音」を作る。
    private let grainGenerator: GrainGenerator

    /// Task 17: mainMixer の後段に挟むリバーブ。ATMÓS 的な「広い空間に漂う」没入感を作る。
    /// factoryPreset = .largeHall (中〜大ホールの広がり、cathedral 系より自然な減衰)。
    /// wetDryMix = 40.0 で wet 40% / dry 60% の控えめバランス
    /// (Drone の音像が後ろに引きすぎず、空間情報だけ載る程度)。
    /// AVAudioUnit は manual rendering mode と互換なので CI offline render でも動作する。
    private let reverbNode: AVAudioUnitReverb

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

    /// offline モードで render する総秒数（fade-in + 定常 + fade-out + reverb tail）。
    /// Task 16 で 4.0s → 16.0s に延長 (generative pitch 検証用)。
    /// Task 17 で 16.0s → 18.0s に再延長: AVAudioUnitReverb の tail (~1.5s) を捉えるための余裕。
    /// 構造: fade-in 0.8s + 定常 14.4s + fade-out 0.8s + reverb tail 2.0s = 18.0s。
    /// なお実 WAV 長は `totalFrames = baseTotalFrames + buffer.frameCapacity` の影響で
    /// 約 18.09s になる (render block snapshot 遅延を吸収するための末尾余裕)。
    /// reverb tail 区間 (16.0〜18.0s) で「fade-out 後にも残響が続いている」ことを CI で検証する。
    private let offlineRenderSeconds: Double = 18.0

    /// fade-out 完了から WAV 末尾までの reverb tail 区間 (秒)。
    /// `offlineRenderSeconds - (fadeIn + 定常 + fadeOut)` で算出され、CI 検証側の
    /// tail 観察区間 (>= 16.0s) と一致する。
    private let reverbTailSeconds: Double = 2.0

    /// fade-in の所要秒数。
    private let fadeInSeconds: Double = 0.8

    /// fade-out の所要秒数。
    private let fadeOutSeconds: Double = 0.8

    // MARK: - 初期化

    /// - Parameter rootNote: Drone 多声構成の基音 (root)。既定は **A3 (= 220Hz)**。
    ///   Drone 4 声は [root-24semi (sub), root, root+7semi (5度), root+12semi (octave)] で展開される
    ///   → デフォルトでは A1 / A3 / E4 / A4 (55 / 220 / 329.63 / 440 Hz)。
    ///   Task 18 で sub bass voice (A1) を追加して ATMÓS 的な重心の低い空間を作る。
    /// - Parameter scale: 音階。既定は A Major Pentatonic。
    /// - Parameter mode: 動作モード。`nil` のとき環境変数 `CI_AUTOSTART` の有無で自動判定。
    init(
        rootNote: Note = Note(name: "A3") ?? Note(midiNumber: 57),
        scale: Scale = .majorPentatonic,
        mode: Mode? = nil
    ) {
        // Task 18 で sub voice を rootNote - 24 semitone (= 2 オクターブ下) に置くため、
        // rootNote.midiNumber は最低でも 24 (= C0) 以上である必要がある。default A3 (57) は満たす。
        // 違反するとここで明確に止まる (Note(midiNumber:) の precondition より読みやすい failure)。
        // sub (root-24) と octave (root+12) の両端を MIDI 0..<128 に収めるための範囲。
        // 下限 24 = sub voice の MIDI が >= 0、上限 115 = octave voice の MIDI が <= 127。
        precondition((24...115).contains(rootNote.midiNumber),
                     "AudioEngineController: rootNote.midiNumber must be in 24...115 to fit sub (root-24) and octave (root+12) in valid MIDI range. got \(rootNote.midiNumber)")
        self.rootNote = rootNote
        self.scale = scale
        // 4 声構成: sub (root-24semi = A1) / root / 5度 (root+7) / octave (root+12)。
        // sub は Task 18 で追加した重低音レイヤー。既存 3 声の下に薄く敷いて重心を下げる。
        // sub の倍音 (×2=110Hz / ×3=165Hz) が root (220Hz) と自然に音響的に接続する。
        let droneIntervals = [-24, 0, 7, 12]
        let initialDroneNotes = droneIntervals.map { Note(midiNumber: rootNote.midiNumber + $0) }
        self.currentDroneNotes = initialDroneNotes

        // Pitch 候補リスト: 各 voice の音域内候補。
        // **Task 16 で導入した generative pitch は現在 OFF** (startPitchScheduler が起動しない、
        // inline scheduler も skip)。コード基盤と候補リストは将来再有効化のために残してある。
        // ユーザーフィードバック: 「初期のころの静かな方が良い、高音要らない」
        //                       → Task 14 までの静的 drone (倍音 + envelope) 状態に戻す。
        // Step 2 で動的選択を再開するときは startPitchScheduler() を有効化すれば即復活する。
        // ⚠ 再有効化時の注意 (Task 18 追加): sub voice が独立に動くと root との整数倍関係が
        // 崩れて和声感や濁りが前に出る可能性。再開時は sub を root に追従させる、または
        // sub の候補を root に整合した狭い範囲に制限するのが安全。
        self.pitchCandidates = [
            // sub bass voice (重低音: A1 周辺、55-82Hz) — Task 18 で追加
            ["A1", "B1", "C#2", "E2"].compactMap(Note.init(name:)),
            // root voice (中音域: A3 周辺、220-330Hz)
            ["A3", "B3", "C#4", "E4"].compactMap(Note.init(name:)),
            // 5th voice (中高音域: E4 周辺、330-494Hz)
            ["E4", "F#4", "A4", "B4"].compactMap(Note.init(name:)),
            // octave voice (高音域: A4 周辺、440-659Hz)
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
        // Task 16 で CI WAV を 16s に延長したため、glide も realtime と同じ 3s で統一。
        // 短い glide (0.5s) は警報・サイレン的な聴感になることが artifacts_017 で実測されたため。
        self.pitchGlideSeconds = 3.0

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
        // 多声 Drone: sub bass / 基音 / 完全 5度 / オクターブ。振幅は基音強め、上倍音と sub を
        // 弱めて自然な厚みを作る。
        //
        // 各声に異なる LFO（pitch vibrato）周期・深さ・初期位相を割り当て、
        // 4 声のゆらぎが揃わない（時間軸で複雑に変化し続ける）ようにする。周期は
        // 13.7 / 17.3 / 23.1 / 29.0 秒で、互いに約分しにくい値の組み合わせのため
        // 聴感上の繰り返しが目立たない。
        //
        // Headroom 評価（Task 19 で grain 追加後、概算）:
        //   - sub (A1)  amp 0.05  ×  (基音 + 第2 + 第3) 1.3 = 0.065
        //   - root      amp 0.15  ×  1.3 = 0.195
        //   - 5度       amp 0.08  ×  1.3 = 0.104
        //   - octave    amp 0.05  ×  1.3 = 0.065
        //   - Drone 4 声合算 ≈ 0.429
        //   - Noise (Paul Kellet's + lowpass 統計信号) ≈ 0.08
        //   - Grain: 現在のパラメータ (期待 1 trig/s/ch, 次間隔 mean×0.5〜1.5 → 最低 0.5s, grain 60ms)
        //     では同一 channel での grain 重なりは起きないため、ch あたり瞬間 peak は 1 個分の 0.04。
        //     L/R 独立 trigger で稀に L/R が同時発火しても合計 peak は 0.04 を超えない（別 ch）。
        //     つまり grain は mixer 入口で peak 0.04 / ch を一時的に追加するレイヤーで、
        //     Drone + Noise の peak ≈ 0.51 に grain peak 0.04 を加えても 0.55 程度。
        //   - 合算 peak ≈ 0.55 → envelope multiplier 最大 1.075 で 0.59 前後
        //   - mainMixer outputVolume 0.5 を経由して 0.30 前後
        //   - reverb wet (Task 17) で RMS は +20-30% 上昇する。peak は基本同等だが、
        //     瞬間的に位相が揃って peak が +10-20% 程度上がる可能性は残る (CI 実測で確認)。
        // 16bit s16le 換算 (32767) でも余裕がある見込み。CI の WAV 検査でクリッピング無しを実測確認する。
        //
        // sub と reverb の相互作用:
        //   - 低周波 (55Hz) は `.largeHall` で tail が長く聴こえやすい (人間の聴覚特性)
        //   - 聴感で sub の reverb tail が膨らみすぎる場合、outputVolume を下げる（全体痩せる）
        //     より sub の defaultAmplitude を 0.04 等に下げる方がバランス維持
        //   - もしくは将来 sub だけ reverb send を弱める経路に分ける
        //
        // 倍音設定: 第 2 倍音 (× 2) を基音の 20%、第 3 倍音 (× 3) を 10%。
        // 偶数 + 奇数の自然な組み合わせで、ハーモニウム / オルガン系の温かみを出す。
        // sub bass (A1=55Hz) の生成倍音は 110Hz/165Hz。root (220Hz=A3) は sub の「暗示される
        // 第 4 倍音」位置にあたるが整数倍関係でうなりは生じず、110/165/220 の音響的接続が自然。
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

        // initialDroneNotes[0]=sub (A1), [1]=root (A3), [2]=5度 (E4), [3]=octave (A4)。
        // 各 frequency は Note が平均律 (12 TET) で計算 (55 / 220 / 329.63 / 440 Hz)。
        //
        // sub bass (Task 18) の LFO 設定:
        //   - 周期 29.0s: 既存 13.7/17.3/23.1 と互いに約分しにくい値の組み合わせで揃わない
        //   - depth 2.0cent: 重低音は LFO が「うねり」として聴こえやすいので控えめ
        //   - initialPhase 3π/2: 既存 0 / π/2 / π と 4 等分位相で同位相タイミングを避ける
        self.droneGenerators = [
            DroneGenerator(
                format: format, frequency: initialDroneNotes[0].frequency,
                lfoPeriodSeconds: 29.0, lfoDepthCents: 2.0, lfoInitialPhase: .pi * 1.5,
                harmonics: harmonics,
                envelopePeriodSeconds: envelopePeriod, envelopeDepth: envelopeDepth,
                envelopeInitialPhase: envelopeInitialPhase,
                defaultAmplitude: 0.05
            ),
            DroneGenerator(
                format: format, frequency: initialDroneNotes[1].frequency,
                lfoPeriodSeconds: 17.3, lfoDepthCents: 2.5, lfoInitialPhase: 0.0,
                harmonics: harmonics,
                envelopePeriodSeconds: envelopePeriod, envelopeDepth: envelopeDepth,
                envelopeInitialPhase: envelopeInitialPhase,
                defaultAmplitude: 0.15
            ),
            DroneGenerator(
                format: format, frequency: initialDroneNotes[2].frequency,
                lfoPeriodSeconds: 23.1, lfoDepthCents: 2.0, lfoInitialPhase: .pi / 2,
                harmonics: harmonics,
                envelopePeriodSeconds: envelopePeriod, envelopeDepth: envelopeDepth,
                envelopeInitialPhase: envelopeInitialPhase,
                defaultAmplitude: 0.08
            ),
            DroneGenerator(
                format: format, frequency: initialDroneNotes[3].frequency,
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

        // Task 19: 粒状音響レイヤー。Drone 4 声の上に scale 内の高音域 (C#5/E5/F#5/A5) で
        // 短い grain (60ms) を疎にトリガする。L/R 独立、各 channel あたり 1 trigger/sec 期待。
        // pitch 候補は A Major Pentatonic の 5/6 オクターブ目から: C#5/E5/F#5/A5
        // (440Hz の root に対し 1〜2 オクターブ上、Drone と協和)。
        // 同時 active 8 grain プールで余裕。grain 1 個 peak 0.04 / 同時 2-3 個重なって max 0.12。
        // reverb の tail で「shimmer」が長く尾を引き、ATMÓS 的な空間感に貢献する。
        let grainPitches: [Double] = [
            Note(name: "C#5")?.frequency ?? 554.37,
            Note(name: "E5")?.frequency ?? 659.26,
            Note(name: "F#5")?.frequency ?? 739.99,
            Note(name: "A5")?.frequency ?? 880.00,
        ]
        self.grainGenerator = GrainGenerator(
            format: format,
            defaultAmplitude: 0.04,
            grainDurationSeconds: 0.06,
            expectedTriggersPerSecond: 1.0,
            pitchFrequencies: grainPitches,
            maxActiveGrains: 8,
            envelopePeriodSeconds: envelopePeriod,
            envelopeDepth: envelopeDepth,
            envelopeInitialPhase: envelopeInitialPhase
        )

        // Task 17: ATMÓS 的な空間広がりのためのリバーブ。
        // `.largeHall` は中〜大ホール (RT60 数秒) の自然な減衰で、cathedral 系より響き
        // 過ぎず Drone の輪郭が残る。wetDryMix=40 は wet 40% / dry 60% の控えめバランス。
        // 音量に対する影響: wet 成分はエネルギーを時間軸に分散するため peak は基本同等、
        // RMS は最大で +20〜30% 程度上昇。瞬間的に位相が揃って peak が +10-20% 上がる
        // 可能性は残るため、最終的には CI の WAV 検査で実測確認する。
        // 既存の mainMixer.outputVolume = 0.5 で十分余裕がある見込み。
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 40.0
        self.reverbNode = reverb

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
            // 多声 Drone のいずれか、Noise、または Grain が audible なら fade-out 中ではない。
            let anyDroneAudible = self.droneGenerators.contains(where: { $0.hasAudibleTarget })
            if anyDroneAudible || self.noiseGenerator.hasAudibleTarget || self.grainGenerator.hasAudibleTarget {
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

    // MARK: - Mode 切替 (Task 21)

    /// モードを切り替える (SLEEP / FOCUS / MEDITATE / RELAX)。
    ///
    /// **engine 動作中は ignore + 警告ログ** (ATMÓS の "Stop playback to change mode" と同じ設計)。
    /// 各 generator のパラメータ (defaultAmplitude / grain rate / grain pitches) を書き換える際に
    /// audio thread が動いていない状態を保証するため。realtime / offline どちらでも engine.stop()
    /// 完了後 (isRunning=false) なら呼べる。
    ///
    /// Reverb wetDryMix だけは AVAudioUnit のスレッド安全な property なので engine 動作中でも
    /// 設定可能だが、設計の一貫性のため Stop 中に限定する。
    /// - Parameter mode: 切替先のモード。
    /// - Returns: 適用に成功したら true、isRunning ガードで弾かれたら false。
    @discardableResult
    func setMode(_ mode: Mode) -> Bool {
        guard !isRunning else {
            logger.warning("setMode は engine 停止中のみ可能 (isRunning=true)。再生中のモード切替は ignore。")
            return false
        }
        applyPreset(mode.preset)
        currentMode = mode
        logger.info("Mode switched to: \(mode.rawValue, privacy: .public)")
        return true
    }

    /// プリセット値を全 generator + reverb に一括適用する。
    /// `setMode` 内部実装。直接呼ばないこと (isRunning ガードを通さないため)。
    private func applyPreset(_ preset: ModePreset) {
        // 4 voice 構成の invariant 明示 (Codex Task 21 Medium 指摘)。
        // 将来 voice 数を変える場合、ここの index アクセスと ModePreset のフィールドを揃えること。
        precondition(droneGenerators.count == 4,
                     "applyPreset requires exactly 4 drone voices (sub/root/5th/octave). got \(droneGenerators.count)")
        // Drone 4 voice の amp 更新 (配列順: sub / root / 5th / octave)。
        droneGenerators[0].setDefaultAmplitude(preset.subAmp)
        droneGenerators[1].setDefaultAmplitude(preset.rootAmp)
        droneGenerators[2].setDefaultAmplitude(preset.fifthAmp)
        droneGenerators[3].setDefaultAmplitude(preset.octaveAmp)

        // Noise の amp 更新。
        noiseGenerator.setDefaultAmplitude(preset.noiseAmp)

        // Grain の amp / trigger rate / pitch 候補を更新。
        grainGenerator.setDefaultAmplitude(preset.grainAmp)
        grainGenerator.setTriggerRate(triggersPerSecond: preset.grainTriggersPerSecond)
        grainGenerator.setPitches(preset.grainPitches)

        // Reverb の wet/dry ミックス比を更新。AVAudioUnitReverb の wetDryMix は
        // AVAudioUnit のプロパティで、Stop 中なら確実に安全。
        reverbNode.wetDryMix = preset.reverbWetDryMix
    }

    // MARK: - Voice mute (Task 20)

    /// 指定 voice グループの mute 状態を設定する。10ms ramp で 0/1 に補間されるため
    /// 切替時のクリックノイズは出ない。stop fade-out 中・start fade-in 中の操作も安全。
    ///
    /// `.tone` は 2 つの DroneGenerator (E4+A4) に for ループで順次 setMuted する。
    /// 理論上「片方が先に flag store → audio block が割り込んで片方だけ ramp 開始」の
    /// 1 buffer (~5.8ms @ 256 frames) ずれが発生し得るが、メインスレッドの 2 回連続 atomic store は
    /// ns オーダーで、audio block 間隔 (5.8ms) を跨ぐ確率は実用上ゼロ。
    /// 厳密に同一 sample で揃えたい場合は将来 group-shared atomic flag に refactor する余地あり。
    /// - Parameters:
    ///   - group: 対象 voice グループ。
    ///   - muted: true で音を 0 に、false で 1.0 に向ける。
    func setMuted(_ group: VoiceGroup, _ muted: Bool) {
        for gen in generators(for: group) {
            gen.setMuted(muted)
        }
    }

    /// 指定 voice グループの現在の mute 意図を返す（UI 表示用）。
    /// グループに複数 generator が紐付く場合は、いずれかが muted なら true（UI の整合性のため）。
    func isMuted(_ group: VoiceGroup) -> Bool {
        let gens = generators(for: group)
        guard !gens.isEmpty else { return false }
        return gens.contains(where: { $0.isMuted })
    }

    /// VoiceGroup に紐付く mute 対応 generator 群（DroneGenerator + GrainGenerator）を統一的に扱う。
    /// 内部 droneGenerators 配列のインデックス対応: [0]=sub / [1]=root / [2]=5th / [3]=octave。
    /// MIDI 範囲制約で守られているので、precondition と整合する境界を維持。
    /// （メンバ変数 `droneGenerators` と関数名が衝突しないように、中間関数は持たず 1 メソッドで畳む）
    private func generators(for group: VoiceGroup) -> [VoiceMutable] {
        switch group {
        case .sub:   return [.drone(droneGenerators[0])]
        case .drone: return [.drone(droneGenerators[1])]
        case .tone:  return [.drone(droneGenerators[2]), .drone(droneGenerators[3])]
        case .grain: return [.grain(grainGenerator)]
        }
    }

    /// 指定 voice グループの代表 note 名（UI 表示用）。
    /// `.tone` は E4 + A4 統合のため `"E4·A4"` 形式で返す。`.grain` は trigger 時に random 選択
    /// なので候補リストの代表表記 `"C#5/E5/F#5/A5"` を返す。
    func displayNoteName(for group: VoiceGroup) -> String {
        switch group {
        case .sub:   return currentDroneNotes[0].name
        case .drone: return currentDroneNotes[1].name
        case .tone:  return "\(currentDroneNotes[2].name)·\(currentDroneNotes[3].name)"
        case .grain: return "C#5/E5/F#5/A5"
        }
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

    /// fade-in を全 Drone 声と Noise と Grain に依頼する。
    /// 各 generator は独立した state を持つが、UX 上は「Sleep モード全体の fade-in」として揃える。
    private func scheduleFadeIn() {
        for drone in droneGenerators {
            drone.scheduleFadeIn(duration: fadeInSeconds)
        }
        noiseGenerator.scheduleFadeIn(duration: fadeInSeconds)
        grainGenerator.scheduleFadeIn(duration: fadeInSeconds)
    }

    /// fade-out を全 Drone 声と Noise と Grain に依頼する。
    private func scheduleFadeOut() {
        for drone in droneGenerators {
            drone.scheduleFadeOut(duration: fadeOutSeconds)
        }
        noiseGenerator.scheduleFadeOut(duration: fadeOutSeconds)
        grainGenerator.scheduleFadeOut(duration: fadeOutSeconds)
    }

    // MARK: - PitchScheduler (Task 16)

    /// **Generative pitch スケジューラは現在 OFF** (Task 14 状態に戻したため)。
    /// コード基盤は残してあり、`generativePitchEnabled` を `true` にすれば即復活する。
    /// 将来 ATMÓS 化 Step 2 を再開するときに削除せずに済む。
    private let generativePitchEnabled = false

    /// 各 voice 用に独立した Task を起動し、interval ごとに `advanceVoicePitch(at:)` を呼ぶ。
    /// realtime モード専用。offline モードでは render ループ内で frame counter で代替する
    /// （Task.sleep は renderOffline 同期ループ中に進まないため）。
    private func startPitchScheduler() {
        guard generativePitchEnabled else { return }
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

        // fade-out 開始地点。Task 17 で reverb tail を末尾 `reverbTailSeconds` 秒に確保するため、
        // 「総尺 - tail - fade-out」を起点にする。つまり構造は:
        //   0〜0.8s: fade-in / 0.8〜15.2s: 定常 / 15.2〜16.0s: fade-out / 16.0〜18.0s: tail。
        // render block 内のスナップショット遅延（最大 frameCapacity フレーム）を吸収するため、
        // 総フレーム数に余裕（+ frameCapacity）を足して fade-out + tail が確実に末尾まで届くようにする。
        let baseTotalFrames = AVAudioFrameCount(renderSampleRate * offlineRenderSeconds)
        let totalFrames = baseTotalFrames + buffer.frameCapacity
        let fadeOutStartFrame = AVAudioFrameCount(
            renderSampleRate * (offlineRenderSeconds - reverbTailSeconds - fadeOutSeconds)
        )
        var rendered: AVAudioFrameCount = 0
        var fadeOutScheduled = false
        var transientRetries = 0
        let maxTransientRetries = 32
        var zeroFrameRetries = 0
        let maxZeroFrameRetries = 8

        // ---- inline PitchScheduler (offline 専用、Task 16) ----
        // WAV を 16s 化したので pitchIntervals (19/23/13s) を本番値そのままで使う。
        // - 16 秒 WAV 内で octave voice (13s) は 1 回、root (19s) と 5th (23s) は 0-1 回切替
        // - 「ATMÓS 的にゆっくり変化」が CI でも観測できる
        // - fade-in 0.8s 中の切替を避けるため、最初の発火を interval から開始 (= interval だけ遅延)
        //   (改善案: 必要なら開始 offset を fade-in 完了後にずらす)
        // realtime Task scheduler は startOfflineRender 内では使えない (同期ループで sleep 不可)。
        let pitchUpdateFrameIntervals: [AVAudioFrameCount] = pitchIntervals.map {
            AVAudioFrameCount(renderSampleRate * $0)
        }
        var nextPitchUpdateFrames: [AVAudioFrameCount] = pitchUpdateFrameIntervals

        while rendered < totalFrames {
            // fade-out 開始地点を越えたら一度だけ scheduleFadeOut。
            if !fadeOutScheduled && rendered >= fadeOutStartFrame {
                scheduleFadeOut()
                fadeOutScheduled = true
            }

            // inline PitchScheduler: 各 voice の次の update frame を越えたら advance。
            // generativePitchEnabled = false のときは skip (Task 14 状態維持)。
            if generativePitchEnabled {
                for i in 0..<droneGenerators.count {
                    if rendered >= nextPitchUpdateFrames[i] {
                        advanceVoicePitch(at: i)
                        nextPitchUpdateFrames[i] += pitchUpdateFrameIntervals[i]
                    }
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
    /// Task 17: mainMixer の後段に AVAudioUnitReverb を挟む
    /// (`mixer → reverb → outputNode`)。realtime / offline のどちらでも同じグラフ。
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

        // Task 19: Grain generator も Drone/Noise と同列に mainMixer に並列接続。
        engine.attach(grainGenerator.sourceNode)
        engine.connect(grainGenerator.sourceNode, to: engine.mainMixerNode, format: format)

        // Task 17: mainMixer → reverb → outputNode に切り替える。
        // mainMixerNode へのアクセスで暗黙的に outputNode への接続が生成されているので、
        // それを `disconnectNodeOutput` で切ってから reverb を挟む。
        // effect 入力 (mixer → reverb) は generator と同じ stereo 44.1kHz format を明示し、
        // 後段 (reverb → output) は output hardware (realtime で 48kHz 等になる可能性) に
        // 任せるため `format: nil`。offline 時は manualRenderingFormat が format と一致する。
        engine.attach(reverbNode)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: reverbNode, format: format)
        engine.connect(reverbNode, to: engine.outputNode, format: nil)

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
