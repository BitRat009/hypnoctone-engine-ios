import SwiftUI

/// Hypnoctone のアプリエントリーポイント。
///
/// SwiftUI の App ライフサイクルを使用する。初回起動 (Task 28) なら `OnboardingView` を、
/// それ以外なら `MainView` を表示する。`CI_AUTOSTART` 環境変数があるときは onboarding を
/// 強制スキップして既存 CI フロー (CI で MainView を直接起動して自動再生) を破壊しない。
@main
struct HypnoctoneEngineApp: App {
    @StateObject private var onboardingState = OnboardingState()

    var body: some Scene {
        WindowGroup {
            if onboardingState.shouldShowOnboarding {
                OnboardingView(onComplete: {
                    onboardingState.markCompleted()
                })
            } else {
                MainView()
            }
        }
    }
}

/// Onboarding 表示要否の判定と完了通知を担う ViewModel (Task 28)。
///
/// 起動時に `SettingsStore.hasCompletedOnboarding` と `CI_AUTOSTART` 環境変数を見て、
/// 表示要否を決める。完了時は SettingsStore に書き戻し、`@Published` で UI を切り替える。
@MainActor
final class OnboardingState: ObservableObject {
    /// 現在 onboarding を表示すべきか。`HypnoctoneEngineApp` の WindowGroup の分岐条件。
    @Published private(set) var shouldShowOnboarding: Bool

    init() {
        // CI_AUTOSTART 環境変数がある (= Codemagic / Xcode の CI 自動再生フロー) なら
        // onboarding をスキップして MainView に直行する。これで既存 CI フロー
        // (artifacts に screenshot/WAV を出す動作) を破壊しない。
        let isCI = ProcessInfo.processInfo.environment["CI_AUTOSTART"] != nil

        // SettingsStore は @MainActor なので init context (も @MainActor) から安全に読める。
        let completed = SettingsStore.shared.hasCompletedOnboarding

        self.shouldShowOnboarding = !completed && !isCI
    }

    /// Onboarding 完了時に呼ぶ。SettingsStore に永続化し、画面を MainView に切り替える。
    func markCompleted() {
        SettingsStore.shared.hasCompletedOnboarding = true
        shouldShowOnboarding = false
    }
}
