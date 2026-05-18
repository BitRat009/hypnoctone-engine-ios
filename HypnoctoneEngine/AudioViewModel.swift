import Foundation
import Combine

/// UI と `AudioEngineController` の橋渡しをする ViewModel。
///
/// 音響処理そのものは持たず、再生状態と音量を SwiftUI へ公開することに専念する。
/// これにより UI（`MainView`）と音響処理（`AudioEngineController`）を分離する。
///
/// ## isPlaying と controller.isRunning の関係（Task 5 以降）
/// `isPlaying` は「ユーザーが再生を望んでいるか」を表す UI 状態であり、
/// fade-in / fade-out のような過渡状態を待たずに即時反映する。
/// 一方 `controller.isRunning` は engine の実際の稼働状態で、fade-out 中も `true` のまま。
/// この 2 つは意図的に分離している（Stop ボタンを押したらすぐ UI に反映したいため）。
@MainActor
final class AudioViewModel: ObservableObject {

    /// ユーザーが再生を望んでいるか（UI 反映用、fade を待たない）。
    @Published private(set) var isPlaying = false

    /// マスター音量（0.0〜1.0）。Volume スライダーとバインドする。
    @Published var volume: Double = 0.5 {
        didSet {
            controller.setVolume(Float(volume))
        }
    }

    /// 再生状態を表す表示用テキスト。
    var statusText: String {
        isPlaying ? "Playing" : "Stopped"
    }

    /// 現在の root note 名（"A3" 等）。UI 表示用。
    var rootNoteName: String { controller.rootNote.name }

    /// 現在のスケール名（"MajPentatonic" 等）。UI 表示用。
    var scaleName: String { controller.scale.shortName }

    /// 4 voice グループ (TONE/DRONE/SUB/GRAIN) の表示用 1 行（UI 表示用、Task 20）。
    /// `Identifiable` 準拠の struct にしておくと SwiftUI の ForEach に直接渡せる
    /// （tuple labeled keypath は SwiftUI + Xcode 16 系で診断が不安定になりやすいため避ける、
    /// Codex Task 20 ビルドエラー診断指摘）。
    struct VoiceGroupItem: Identifiable {
        let group: AudioEngineController.VoiceGroup
        let label: String
        let noteName: String
        let isMuted: Bool

        var id: AudioEngineController.VoiceGroup { group }
    }

    /// 4 voice グループの表示用配列（UI 表示用、Task 20）。
    /// 順序は `AudioEngineController.VoiceGroup.allCases` と同じ ([.tone, .drone, .sub, .grain])。
    /// `controller.currentDroneNotes` の @Published 変化は init で forward しているので
    /// 動的 pitch 変化 (Task 16 再有効化時) でも UI が自動更新される。
    var voiceGroups: [VoiceGroupItem] {
        AudioEngineController.VoiceGroup.allCases.map { g in
            VoiceGroupItem(
                group: g,
                label: g.label,
                noteName: controller.displayNoteName(for: g),
                isMuted: controller.isMuted(g)
            )
        }
    }

    private let controller: AudioEngineController

    /// `controller.objectWillChange` を `self.objectWillChange` に forward するための保持。
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameter controller: 音響処理コントローラ。テスト時に差し替えられるよう注入可能。
    ///
    /// `AudioEngineController` は `@MainActor` 隔離されているため、デフォルト引数式
    /// （呼び出し側の nonisolated context で評価される）から `AudioEngineController()` を
    /// 直接呼ぶとコンパイルエラーになる。引数を Optional にしておき、init 本体
    /// （MainActor 隔離下）で生成することでこの制約を回避する。
    init(controller: AudioEngineController? = nil) {
        let resolved = controller ?? AudioEngineController()
        self.controller = resolved
        resolved.setVolume(Float(volume))

        // controller の @Published 変化 (currentDroneNotes 等) を ViewModel にも forward。
        // これで MainView の musicInfo (droneNoteNames を読む) が generative pitch 変化を
        // 自動的に再描画する。
        resolved.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// 再生 / 停止をトグルする。
    func toggle() {
        isPlaying ? stop() : start()
    }

    /// 再生を開始する。fade-in は `AudioEngineController` 側で 0.8 秒かけて行われる。
    /// `controller.start()` が成功した時のみ `isPlaying` を `true` にする。
    /// `AVAudioSession` 有効化や `engine.start()` が失敗した場合は `isPlaying` を `false` の
    /// まま維持し、UI と engine の整合性を保つ（Codex Task 5 レビュー指摘 5 への対応）。
    func start() {
        if controller.start() {
            isPlaying = true
        }
    }

    /// 再生を停止する。fade-out 開始を依頼するが、UI 上は即時 Stopped 表示にする。
    func stop() {
        controller.stop()
        isPlaying = false
    }

    /// 指定 voice グループの mute / unmute をトグルする（Task 20）。
    /// audio 層は 10ms ramp で 0/1 に補間するためクリックノイズなし。
    /// objectWillChange を明示的に発火して UI を即時更新する（controller 側は @Published
    /// プロパティではなく atomic flag を更新するだけなので forward が走らない）。
    func toggleMute(_ group: AudioEngineController.VoiceGroup) {
        let next = !controller.isMuted(group)
        controller.setMuted(group, next)
        objectWillChange.send()
    }

    // MARK: - Mode 切替 (Task 21)

    /// 現在のモード (UI 表示用)。`controller.currentMode` の @Published 変化は init で
    /// objectWillChange を forward しているので UI に自動反映される。
    var currentMode: Mode { controller.currentMode }

    /// header subtitle 用のモード表記 ("Sleep Mode" / "Focus Mode" / "Meditate Mode" / "Relax Mode")。
    /// Modes.swift の `label` は ATMÓS 風の大文字 ("SLEEP") なので、header 用の Capitalized 表記は
    /// ここで生成する (UI 一貫性: header は タイトルケース、ボタンは大文字)。
    var currentModeLabel: String {
        switch controller.currentMode {
        case .sleep:    return "Sleep Mode"
        case .focus:    return "Focus Mode"
        case .meditate: return "Meditate Mode"
        case .relax:    return "Relax Mode"
        }
    }

    /// UI 表示用 BPM (ATMÓS の "BPM 30" 表記再現)。
    var bpm: Int { controller.currentMode.preset.bpm }

    /// UI に表示する全モード一覧 (ボタングリッド用)。`Mode.allCases` を直接公開する。
    var allModes: [Mode] { Mode.allCases }

    /// 現在のモードで Mode 切替可能か (Stop 状態でのみ可能、Task 21 設計)。
    /// UI でモードボタンを enable/disable する判定に使う。
    /// - `!isPlaying`: ユーザーが Stop ボタンを押した直後の即時反映
    /// - `!controller.isRunning`: fade-out 完了まで待つ (engine がまだ生きているうちは false)
    /// 両方の AND で「fade-out 完了後の完全 Stop 状態」を判定する (Codex Task 21 High 指摘反映)。
    var canChangeMode: Bool { !isPlaying && !controller.isRunning }

    /// モードを切り替える (Task 21)。
    /// `isPlaying` 中 (engine 動作中) は controller 側で ignore される。
    /// 成功時のみ objectWillChange を発火 (controller の @Published currentMode 経由でも
    /// 通知は走るが、即時反映を保証するため明示送信)。
    func setMode(_ mode: Mode) {
        if controller.setMode(mode) {
            objectWillChange.send()
        }
    }
}
