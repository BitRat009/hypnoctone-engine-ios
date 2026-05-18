import Foundation
import MediaPlayer
import os

/// Lock screen / Control Center に再生情報を出して、Lock screen からの再生・停止を受け付ける。
///
/// Sleep アプリとして「画面ロック中も継続再生 + Lock screen で停止できる」UX を提供するために、
/// `MPNowPlayingInfoCenter` と `MPRemoteCommandCenter` を統合する。
///
/// - **NowPlayingInfo**: title "Hypnoctone" + artist (現在モード名) + playback state
/// - **Remote commands**: play / pause / stop / togglePlayPause を Lock screen から受け、
///   `AudioViewModel.start()` / `.stop()` を呼ぶ
///
/// `Info.plist` の `UIBackgroundModes` に `audio` を入れ、AVAudioSession のカテゴリを
/// `.playback` にしている前提で動く。これらは pbxproj と `AudioEngineController` で
/// 設定済み。
///
/// ## メモリと所有関係
/// `AudioViewModel` が strong に所有する。Remote command のハンドラ closure は ViewModel に
/// 弱参照させ、ViewModel が deinit された後に command がきても安全にする。
@MainActor
final class NowPlayingService {

    /// Lock screen の play/pause/stop ハンドラから呼ばれるアクション。
    /// closure に `[weak viewModel]` で渡され、ViewModel deinit 後の retain cycle を避ける。
    ///
    /// `@MainActor` 注釈: Remote command handler は MediaPlayer から任意スレッドで呼ばれるが、
    /// ViewModel の `start()` / `stop()` / toggle 系は `@MainActor` 隔離されているため、
    /// 呼び出し側で `Task { @MainActor in ... }` で hop する。closure 型自体にも `@MainActor` を
    /// 付けて呼び出し境界を明示する (Codex Task 24 High 指摘反映)。
    struct Actions {
        let start: @MainActor () -> Void
        let stop: @MainActor () -> Void
        /// `togglePlayPauseCommand` 用。再生中なら stop、停止中なら start に分岐する責務は
        /// ViewModel 側 (再生状態を持っているため)。
        let toggle: @MainActor () -> Void
    }

    private let logger = Logger(
        subsystem: "com.hypnoctone.HypnoctoneEngine",
        category: "NowPlayingService"
    )

    /// Remote command が既に setup 済みかのフラグ。重複登録防止。
    private var commandsRegistered = false

    /// Remote command の target object 参照を保持して、deinit 時に removeTarget するために必要。
    /// MPRemoteCommand.addTarget の戻り値 (Any) を保持する。
    private var registeredTargets: [(MPRemoteCommand, Any)] = []

    init() {}

    deinit {
        // Lock screen のコマンドハンドラを全部外す (アプリ deinit 時のクリーンアップ)。
        // @MainActor 隔離下なので nonisolated context から直接 removeTarget するのは
        // Swift 6 strict concurrency では警告だが、deinit のタイミング上避けられないため
        // この用途では許容 (MPRemoteCommand 自体は thread-safe な API)。
        for (command, target) in registeredTargets {
            command.removeTarget(target)
        }
    }

    // MARK: - Remote Command 設定

    /// Lock screen の play/pause/stop ハンドラを登録する。
    /// 重複登録を防ぐため一度のみ実行 (アプリのライフサイクル中 1 回)。
    /// - Parameter actions: 各コマンドで呼び出すアクション。`[weak viewModel]` で渡すこと。
    func setupRemoteCommands(actions: Actions) {
        guard !commandsRegistered else { return }
        commandsRegistered = true

        let center = MPRemoteCommandCenter.shared()

        // すべての handler は MainActor 隔離の Actions closure を呼ぶため、Task で hop する。
        // MediaPlayer は任意スレッドから handler を呼ぶ可能性があるため、これを省略すると
        // Swift concurrency 違反 (実機で TSan/strict mode で検出される)。

        // play: Lock screen の再生ボタン
        let playTarget = center.playCommand.addTarget { _ in
            Task { @MainActor in actions.start() }
            return .success
        }
        registeredTargets.append((center.playCommand, playTarget))

        // pause: 一時停止 (Hypnoctone では「停止」と同義扱い、fade-out → engine.stop())
        let pauseTarget = center.pauseCommand.addTarget { _ in
            Task { @MainActor in actions.stop() }
            return .success
        }
        registeredTargets.append((center.pauseCommand, pauseTarget))

        // stop: 明示的停止 (Control Center の stop ボタン)
        let stopTarget = center.stopCommand.addTarget { _ in
            Task { @MainActor in actions.stop() }
            return .success
        }
        registeredTargets.append((center.stopCommand, stopTarget))

        // togglePlayPause: イヤホンの再生ボタン等 (再生中なら停止、停止中なら再生)。
        // 内部状態は ViewModel の isPlaying が一次情報源。Actions.toggle が分岐する。
        let toggleTarget = center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in actions.toggle() }
            return .success
        }
        registeredTargets.append((center.togglePlayPauseCommand, toggleTarget))

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true

        logger.info("Remote commands registered (play / pause / stop / toggle)")
    }

    // MARK: - NowPlaying Info 更新

    /// Lock screen / Control Center に表示する Now Playing 情報を更新する。
    /// 再生状態 (`isPlaying`) が変わったときと、モードが変わったときに呼ぶ。
    /// - Parameters:
    ///   - isPlaying: 再生中か (= UI 上の "Playing" / "Stopped" 状態)
    ///   - modeLabel: 現在モードの表示名 (例: "Sleep Mode")
    func updateNowPlaying(isPlaying: Bool, modeLabel: String) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "Hypnoctone"
        info[MPMediaItemPropertyArtist] = modeLabel
        // playbackRate = 1.0 で「再生中」、0.0 で「停止中」と OS に伝える。
        // Lock screen の play/pause アイコンの切り替えに使われる。
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // 経過時間と長さは Hypnoctone では「無限再生」なので未設定 (Lock screen に時間表示なし)。
        // Sleep Timer が動いていれば残り時間を入れる選択肢もあるが、Sleep Timer は別 UI
        // 表示で完結しているので Now Playing 側は単純化する。
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Now Playing 情報をクリアする (アプリ終了時など、Lock screen から表示を消す用)。
    /// 通常は使わないが、デバッグやテスト用に保持。
    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
