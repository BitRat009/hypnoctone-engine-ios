import SwiftUI

/// 初回起動時に表示する Onboarding 画面 (Task 28)。
///
/// App Store からアプリをダウンロードしたユーザー向けに、Hypnoctone の位置付け / 4 モード /
/// Lock screen 連携 / Sleep Timer / Volume の使い方を 3 ページに分けて簡潔に伝える。
/// 最終ページの "Get Started" tap で `onComplete` が呼ばれ、`SettingsStore` 経由で
/// `hasCompletedOnboarding = true` が永続化されて二度と表示されない。
///
/// ## デザイン
/// 本体と同じ `Theme.backgroundGradient` / `Theme.accent` / `.preferredColorScheme(.dark)`。
/// 「音より前に出ない」設計を踏襲し、情報量は最小限、文字は淡いグレー〜白、強調は accent のみ。
///
/// ## ナビゲーション
/// - 右上 **Skip** ボタン: どのページからでも完了可 (上級ユーザー向け)
/// - 下部 **Next / Get Started** ボタン: 次ページへ / 最終ページで完了
/// - 横スワイプ: TabView の page style で自然な操作感
///
/// ## CI 互換
/// HypnoctoneEngineApp が `CI_AUTOSTART` 環境変数を見て onboarding をスキップするので、
/// OnboardingView 自体は CI 環境を意識しない。
struct OnboardingView: View {
    /// 完了時のコールバック。`HypnoctoneEngineApp` から渡され、SettingsStore 更新と画面遷移を担う。
    let onComplete: () -> Void

    /// 現在表示中のページ index (0-based)。
    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Hypnoctone",
            subtitle: "Ambient audio for sleep, focus & rest",
            body: "深い呼吸のような ambient drone と粒状音響で、就寝・集中・瞑想・リラックスをサポートする音響アプリです。",
            symbolName: "waveform"
        ),
        OnboardingPage(
            title: "4 つのモード",
            subtitle: "SLEEP / FOCUS / MEDITATE / RELAX",
            body: "それぞれ脳波研究と音響心理学に基づいた音響プロファイルです。SLEEP は眠気誘導、FOCUS は集中、MEDITATE は瞑想、RELAX は覚醒維持リラックスを狙います。モード切替は Stop 状態でのみ可能です。",
            symbolName: "circle.grid.2x2"
        ),
        OnboardingPage(
            title: "便利な機能",
            subtitle: "Sleep Timer & Lock Screen 連携",
            body: "画面ロック中もバックグラウンドで再生が継続し、Lock Screen / Control Center から再生・停止できます。Sleep Timer で指定時間後に自動停止することもできます。",
            symbolName: "moon.zzz"
        ),
    ]

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // 右上 Skip ボタン (どのページからでも完了可、上級ユーザー向け)
                skipBar

                // 3 ページのスワイプビュー
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        pageContent(pages[i])
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                // 下部 Next / Get Started ボタン
                nextButton
            }
        }
        .preferredColorScheme(.dark)
        // Task 29: Dynamic Type は xxLarge までを許容 (MainView と揃える)。
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    // MARK: - 構成要素

    /// 右上 Skip ボタンを含むトップバー。
    /// Task 29: font を `.subheadline` で Dynamic Type 対応。
    private var skipBar: some View {
        HStack {
            Spacer()
            Button {
                onComplete()
            } label: {
                Text("Skip")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip onboarding")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    /// 1 ページの本文 (タイトル / サブタイトル / 説明文 / シンボル)。
    /// 本文は `ScrollView` で包んで、iPhone SE 系や Dynamic Type 大設定でも下部ボタンや
    /// page indicator と窮屈にならないようにする (Codex Task 28 Medium 反映)。
    private func pageContent(_ page: OnboardingPage) -> some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)

            // 中央のシンボル (SF Symbols)。アプリの accent 色で淡く光る。
            Image(systemName: page.symbolName)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundColor(Theme.accent)
                .frame(height: 100)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                // Task 29: title/subtitle/body も semantic font で Dynamic Type 対応。
                Text(page.title)
                    .font(.system(.title, design: .rounded).weight(.light))
                    .foregroundColor(Theme.primaryText)
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(.system(.subheadline, design: .rounded))
                    .tracking(2)
                    .foregroundColor(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            // 本文は ScrollView で包む。小画面 / Dynamic Type 大でレイアウト崩れ防止。
            ScrollView(showsIndicators: false) {
                Text(page.body)
                    .font(.system(.callout, design: .rounded))
                    .foregroundColor(Theme.primaryText.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
            }

            Spacer(minLength: 16)
        }
    }

    /// 下部 Next ボタン (最終ページで "Get Started" に変化)。
    /// accessibility hint で VoiceOver ユーザーに「次ページへ / 本編へ」の挙動を伝える。
    private var nextButton: some View {
        let isLast = currentPage >= pages.count - 1
        return Button {
            if isLast {
                onComplete()
            } else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentPage += 1
                }
            }
        } label: {
            Text(isLast ? "Get Started" : "Next")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundColor(Theme.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.accent.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
        .accessibilityHint(isLast ? "Opens the main player" : "Shows the next onboarding page")
    }
}

/// Onboarding 1 ページのコンテンツ定義。
private struct OnboardingPage {
    /// 大きく表示するタイトル ("Hypnoctone" / "4 つのモード" 等)。
    let title: String

    /// タイトル下のサブタイトル (英字 ATMÓS 風 tracking)。
    let subtitle: String

    /// 本文。1-2 文程度の短い説明。
    let body: String

    /// 中央に表示する SF Symbol 名 (デザインのアクセント)。
    let symbolName: String
}

struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onComplete: {})
    }
}
