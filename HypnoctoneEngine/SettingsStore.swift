import Foundation

/// Hypnoctone のユーザー設定を UserDefaults で永続化する store (Task 27)。
///
/// アプリ再起動後に以下の設定を復元するために使う:
/// - 現在のモード (SLEEP / FOCUS / MEDITATE / RELAX)
/// - マスター音量 (0.0〜1.0)
/// - 各 voice の MUTE 状態 (TONE / DRONE / SUB / GRAIN)
/// - Sleep Timer の選択値 (Off / 15 / 30 / 45 / 60 / 90 分)
///
/// 設定の **現在実行中のカウントダウン残り秒数** は永続化しない (セッション限定)。
/// 起動時に Sleep Timer の選択値だけ復元し、ユーザーが再度 Start を押した時点で
/// その選択値からカウントダウンを始める。
///
/// ## スレッド安全性
/// `@MainActor` 隔離。UserDefaults 自体は thread-safe だが、AudioViewModel / MainView との
/// 整合性 (UI 状態と同期して書き換える) を強制するためメインスレッド限定にしてある。
///
/// ## 互換性
/// UserDefaults キーは `"com.hypnoctone.settings.*"` で一元プレフィックスして、
/// 他アプリ / 他フレームワークの設定とは混在しない。古いバージョンのアプリで保存された
/// 値があっても、`Mode(rawValue:)` や数値範囲チェックで invalid なら default に
/// fallback してクラッシュさせない。
@MainActor
final class SettingsStore {
    /// プロセス全体で共有する store。AudioViewModel が init で読み込み + 各 setter で書き込む。
    static let shared = SettingsStore()

    /// UserDefaults キー定義。文字列を一箇所に集めて typo を防ぐ。
    private enum Keys {
        static let mode = "com.hypnoctone.settings.mode"
        static let volume = "com.hypnoctone.settings.volume"
        static let mutedTone = "com.hypnoctone.settings.muted.tone"
        static let mutedDrone = "com.hypnoctone.settings.muted.drone"
        static let mutedSub = "com.hypnoctone.settings.muted.sub"
        static let mutedGrain = "com.hypnoctone.settings.muted.grain"
        /// Sleep Timer 分。`-1` は "Off (nil)" を意味する sentinel。
        /// UserDefaults は `Int?` を直接保存できないため。
        static let sleepTimerMinutes = "com.hypnoctone.settings.sleepTimerMinutes"
        /// Onboarding 画面を一度完了したかどうか (Task 28)。
        /// 未保存 = false (初回起動なので onboarding を表示)。
        static let hasCompletedOnboarding = "com.hypnoctone.settings.hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    /// テスト時に `UserDefaults` を差し替えられるよう注入可能にしておく。
    /// 本番では `.standard` を使う。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 現在保存されているモード。未保存 / 不正値なら `.sleep` (デフォルト)。
    var mode: Mode {
        get {
            if let raw = defaults.string(forKey: Keys.mode), let m = Mode(rawValue: raw) {
                return m
            }
            return .sleep
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.mode) }
    }

    /// 0.0〜1.0 の音量。未保存なら 0.5、範囲外は clamp。
    /// `defaults.object(forKey:)` で nil チェックすることで「未保存 = 0.5 default」と
    /// 「明示的に 0.0 を保存した状態」を区別する。
    var volume: Double {
        get {
            guard defaults.object(forKey: Keys.volume) != nil else { return 0.5 }
            return min(max(defaults.double(forKey: Keys.volume), 0.0), 1.0)
        }
        set { defaults.set(min(max(newValue, 0.0), 1.0), forKey: Keys.volume) }
    }

    /// 各 voice の MUTE 状態を辞書で取得 / 保存する。
    /// `defaults.bool(forKey:)` は未保存時 false を返すので、未保存 = unmute (false) として
    /// 期待動作と一致する。
    var mutedGroups: [AudioEngineController.VoiceGroup: Bool] {
        get {
            return [
                .tone:  defaults.bool(forKey: Keys.mutedTone),
                .drone: defaults.bool(forKey: Keys.mutedDrone),
                .sub:   defaults.bool(forKey: Keys.mutedSub),
                .grain: defaults.bool(forKey: Keys.mutedGrain),
            ]
        }
        set {
            defaults.set(newValue[.tone]  ?? false, forKey: Keys.mutedTone)
            defaults.set(newValue[.drone] ?? false, forKey: Keys.mutedDrone)
            defaults.set(newValue[.sub]   ?? false, forKey: Keys.mutedSub)
            defaults.set(newValue[.grain] ?? false, forKey: Keys.mutedGrain)
        }
    }

    /// 単一 voice の MUTE 状態だけを更新する (toggleMute から個別呼出)。
    /// 配列丸ごと書き直すより atomic に近く、他 voice の状態への意図しない上書きを防ぐ。
    func setMuted(_ group: AudioEngineController.VoiceGroup, _ value: Bool) {
        let key: String
        switch group {
        case .tone:  key = Keys.mutedTone
        case .drone: key = Keys.mutedDrone
        case .sub:   key = Keys.mutedSub
        case .grain: key = Keys.mutedGrain
        }
        defaults.set(value, forKey: key)
    }

    /// Sleep Timer の選択値 (分)。`nil` で Off。未保存なら nil。
    ///
    /// `-1` sentinel で nil を表現する (UserDefaults は `Int?` を直接保存できないため、
    /// `object(forKey:)` の nil チェック + `integer(forKey:)` の組み合わせ)。
    ///
    /// Allowlist 検証: 過去のバグや手動書き換えで preset 外の値 (1, 9999 等) が保存されても、
    /// 「preset ボタンが選択状態にならないのに timer が動く」UX 矛盾を防ぐため、
    /// `allowedPresetMinutes` に含まれない値は `nil` に fallback する (Codex Task 27 Medium 反映)。
    var sleepTimerMinutes: Int? {
        get {
            guard defaults.object(forKey: Keys.sleepTimerMinutes) != nil else { return nil }
            let v = defaults.integer(forKey: Keys.sleepTimerMinutes)
            if v < 0 { return nil }
            return Self.allowedPresetMinutes.contains(v) ? v : nil
        }
        set {
            if let v = newValue {
                defaults.set(v, forKey: Keys.sleepTimerMinutes)
            } else {
                defaults.set(-1, forKey: Keys.sleepTimerMinutes)
            }
        }
    }

    /// Sleep Timer の許可された preset 分数 (`AudioViewModel.sleepTimerPresetMinutes` から
    /// nil/Off を除いたもの)。getter の validation に使う。
    /// `AudioViewModel` 側の preset 配列を変えるときはこちらも揃えること。
    private static let allowedPresetMinutes: Set<Int> = [15, 30, 45, 60, 90]

    /// Onboarding 画面を一度完了したかどうか (Task 28)。
    /// 未保存なら false (= 初回起動なので onboarding 表示)。
    /// `bool(forKey:)` は未保存時 false を返すので、これがそのまま default として機能する。
    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }
}
