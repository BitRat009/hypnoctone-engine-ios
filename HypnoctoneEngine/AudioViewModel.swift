import Foundation
import Combine

/// UI と `AudioEngineController` の橋渡しをする ViewModel。
///
/// 音響処理そのものは持たず、再生状態と音量を SwiftUI へ公開することに専念する。
/// これにより UI（`MainView`）と音響処理（`AudioEngineController`）を分離する。
@MainActor
final class AudioViewModel: ObservableObject {

    /// 再生中かどうか。
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

    private let controller: AudioEngineController

    /// - Parameter controller: 音響処理コントローラ。テスト時に差し替えられるよう注入可能にする。
    init(controller: AudioEngineController = AudioEngineController()) {
        self.controller = controller
        controller.setVolume(Float(volume))
    }

    /// 再生 / 停止をトグルする。
    func toggle() {
        isPlaying ? stop() : start()
    }

    /// 再生を開始する。
    func start() {
        controller.start()
        isPlaying = controller.isRunning
    }

    /// 再生を停止する。
    func stop() {
        controller.stop()
        isPlaying = controller.isRunning
    }
}
