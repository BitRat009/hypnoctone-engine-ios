import SwiftUI

/// Hypnoctone の配色定義。
///
/// 「夜の部屋で静かに音が呼吸している」イメージに合わせ、
/// 就寝直前でも眩しくない暗いトーンでまとめる。
/// 派手な色やネオン表現は使わない。
enum Theme {
    /// 背景グラデーション上部（深い紺）。
    static let backgroundTop = Color(red: 0.05, green: 0.06, blue: 0.12)

    /// 背景グラデーション下部（ほぼ黒）。
    static let backgroundBottom = Color(red: 0.02, green: 0.02, blue: 0.05)

    /// 主要テキスト（青みのある淡いグレー）。
    static let primaryText = Color(red: 0.82, green: 0.85, blue: 0.92)

    /// 補助テキスト（やや暗いグレー）。
    static let secondaryText = Color(red: 0.50, green: 0.54, blue: 0.64)

    /// 控えめな青紫のアクセント。
    static let accent = Color(red: 0.42, green: 0.40, blue: 0.72)

    /// 画面全体の背景グラデーション。
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
