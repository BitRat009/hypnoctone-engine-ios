import SwiftUI

/// 画面中央に表示する静かな円形パルス。
///
/// 再生中であることを「ゆっくりした呼吸」のように示すための表現。
/// 音には反応せず、約8秒周期でゆっくり拡大・縮小するだけに留める
/// （音に細かく反応するビジュアライザーにはしない）。
struct PulseView: View {
    /// 再生中かどうか。`true` のときだけゆっくり脈動する。
    let isActive: Bool

    /// 脈動の1サイクル（秒）。6〜10秒の範囲で、ここでは8秒とする。
    private let period: Double = 8.0

    /// 拡大状態。アニメーションのトグルに使う。
    @State private var expanded = false

    /// Reduce Motion 設定 (Task 29)。`true` なら脈動アニメーションを無効化し、
    /// 静的な「最終到達状態」だけ表示する (動きに弱いユーザー配慮)。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // 外側の淡いハロー。
            Circle()
                .fill(Theme.accent.opacity(0.08))
                .frame(width: 240, height: 240)
                .scaleEffect(expanded ? 1.08 : 0.92)

            // 内側のコア。
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.accent.opacity(0.45),
                            Theme.accent.opacity(0.12)
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 110
                    )
                )
                .frame(width: 180, height: 180)
                .scaleEffect(expanded ? 1.04 : 0.96)
                .opacity(isActive ? 1.0 : 0.5)
        }
        .animation(pulseAnimation, value: expanded)
        .onAppear { updatePulse() }
        .onChange(of: isActive) { _ in updatePulse() }
    }

    /// 再生中はゆっくり往復し続け、停止中は静かに収束するアニメーション。
    /// Task 29: Reduce Motion 設定時は `nil` を返してアニメーションを完全に無効化
    /// (expanded の遷移は即時適用される)。
    private var pulseAnimation: Animation? {
        if reduceMotion { return nil }
        if isActive {
            return .easeInOut(duration: period / 2).repeatForever(autoreverses: true)
        } else {
            return .easeInOut(duration: 1.2)
        }
    }

    /// `isActive` に合わせて脈動の状態を切り替える。
    private func updatePulse() {
        expanded = isActive
    }
}

struct PulseView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            PulseView(isActive: true)
        }
    }
}
