import SwiftUI

/// アプリの初期画面。
///
/// 「音より前に出ない」ことを重視し、情報量と刺激を抑えた暗いレイアウトにする。
/// UI は状態を表示し操作を受け付けるだけで、音響処理は `AudioViewModel` 経由で
/// `AudioEngineController` に委譲する。
struct MainView: View {
    @StateObject private var viewModel = AudioViewModel()

    var body: some View {
        ZStack {
            Theme.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 36) {
                header
                Spacer(minLength: 12)
                PulseView(isActive: viewModel.isPlaying)
                Spacer(minLength: 12)
                statusText
                transportButton
                volumeControl
                timerLabel
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 56)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 構成要素

    /// アプリ名とモード表示。
    private var header: some View {
        VStack(spacing: 6) {
            Text("Hypnoctone")
                .font(.system(size: 30, weight: .light, design: .rounded))
                .foregroundColor(Theme.primaryText)
            Text("Sleep Mode")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .tracking(2)
                .foregroundColor(Theme.secondaryText)
        }
    }

    /// 再生状態テキスト。
    private var statusText: some View {
        Text(viewModel.statusText)
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .foregroundColor(Theme.secondaryText)
    }

    /// Start / Stop ボタン。
    private var transportButton: some View {
        Button {
            viewModel.toggle()
        } label: {
            Text(viewModel.isPlaying ? "Stop" : "Start")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundColor(Theme.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.accent.opacity(viewModel.isPlaying ? 0.35 : 0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.accent.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// Volume スライダー。
    private var volumeControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Volume")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundColor(Theme.secondaryText)
                Spacer()
            }
            Slider(value: $viewModel.volume, in: 0.0...1.0)
                .tint(Theme.accent)
        }
    }

    /// Timer の仮表示（この段階では機能は未実装）。
    private var timerLabel: some View {
        Text("Timer: Off")
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundColor(Theme.secondaryText)
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}
