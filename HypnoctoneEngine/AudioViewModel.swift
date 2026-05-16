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

    /// 現在鳴っている Drone 3 声の note 名（["A3", "E4", "A4"]）。UI 表示用。
    /// Task 16 から generative pitch selection で時間軸に変化する。
    /// `controller.currentDroneNotes` は @Published で、init で objectWillChange を
    /// forward しているので変化が UI に自動反映される。
    var droneNoteNames: [String] { controller.currentDroneNotes.map(\.name) }

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
}
