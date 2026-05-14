import SwiftUI

/// Hypnoctone のアプリエントリーポイント。
///
/// SwiftUI の App ライフサイクルを使用し、最初の画面として `MainView` を表示する。
@main
struct HypnoctoneEngineApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}
