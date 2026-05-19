import SwiftUI

/// アプリの初期画面。
///
/// 「音より前に出ない」ことを重視し、情報量と刺激を抑えた暗いレイアウトにする。
/// UI は状態を表示し操作を受け付けるだけで、音響処理は `AudioViewModel` 経由で
/// `AudioEngineController` に委譲する。
///
/// ## アクセシビリティ (Task 29)
/// - フォントは `.font(.system(.body, design: .rounded).weight(...))` のように
///   semantic スタイルで指定し、Dynamic Type に追従する (拡大上限 `xxLarge` で
///   レイアウト崩壊を防ぐ)。
/// - 各操作要素に `accessibilityLabel` / `accessibilityValue` / `accessibilityHint` を付与。
/// - 装飾用ビュー (WaveVisualizer / PulseView) は VoiceOver から隠す。
struct MainView: View {
    @StateObject private var viewModel = AudioViewModel()

    var body: some View {
        ZStack {
            Theme.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 16) {
                header
                Spacer(minLength: 4)
                visualizer
                Spacer(minLength: 4)
                statusText
                modeSelector
                musicInfo
                transportButton
                volumeControl
                timerLabel
            }
            .padding(.horizontal, 24)
            // Task 30 で modeSelector が 5 mode 2 行 grid 化して縦 +56pt 増えた影響で、
            // 既存の `.padding(.vertical, 40)` だと iPhone 画面の usable height を超えて
            // header が status bar に被るようになった (artifacts_038 で発覚)。
            // top は safe area + status bar で十分余白があるので 12pt まで縮め、
            // bottom も home indicator 余白を考慮しつつ 24pt に。spacing 20→16 と
            // 合わせて total 約 -76pt 圧縮し、Dynamic Type デフォルト設定で確実に収める。
            // Dynamic Type 大設定での layout 崩れは Phase 8 実機検証で再評価。
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        // Dynamic Type は xxLarge までを許容。XL/XXL 以上は文字が大きくなりすぎて
        // 4 mode ボタンや 6 timer preset ボタンの横並びが崩れるため上限を設ける。
        // accessibility 設定 (Accessibility Large) 群はサポートしない (Sleep アプリの
        // 限られた画面構成では full accessibility text size は現実的でない)。
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear(perform: handleCIAutostart)
    }

    /// CI（Codemagic 等）からの自動再生フック。
    ///
    /// 通常起動では何もしない。`CI_AUTOSTART` 環境変数が設定されている場合のみ、
    /// UI が落ち着いた頃合いで自動的に再生を開始する。これは録画＋音声キャプチャで
    /// 440Hz サイン波を確認するための仕掛けで、本番ビルドには影響しない。
    private func handleCIAutostart() {
        guard ProcessInfo.processInfo.environment["CI_AUTOSTART"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            viewModel.start()
        }
    }

    // MARK: - 構成要素

    /// 中央のビジュアルブロック (Task 26)。
    /// アプリアイコン (wave-plus) と同じモチーフの動的波形 (WaveVisualizerView) を
    /// 全幅で背景に敷き、その上に既存の PulseView (中央発光ハロー + コア) を重ねる。
    /// 240pt 高さで縦方向を固定し、上下 Spacer で中央配置する。
    ///
    /// Task 29: 装飾要素なので `.accessibilityHidden(true)` で VoiceOver から隠す
    /// (再生状態は statusText で別途読み上げる)。
    private var visualizer: some View {
        ZStack {
            WaveVisualizerView(
                isPlaying: viewModel.isPlaying,
                voiceMuted: voiceMuteByGroup,
                mode: viewModel.currentMode
            )
            PulseView(isActive: viewModel.isPlaying)
        }
        .frame(height: 240)
        .accessibilityHidden(true)
    }

    /// `viewModel.voiceGroups` を `[VoiceGroup: Bool]` 辞書に変換した MUTE 状態。
    /// WaveVisualizerView は配列順序依存を避けるため辞書で受け取る設計
    /// (Codex Task 26 Medium 3 反映)。
    private var voiceMuteByGroup: [AudioEngineController.VoiceGroup: Bool] {
        Dictionary(uniqueKeysWithValues: viewModel.voiceGroups.map { ($0.group, $0.isMuted) })
    }

    /// アプリ名と現在モード名。Task 22 で subtitle を `viewModel.currentModeLabel` 動的化
    /// ("Sleep Mode" / "Focus Mode" / "Meditate Mode" / "Relax Mode")。
    /// Task 29: 元 30pt/14pt 固定 → `.title.weight(.light)` / `.subheadline` で Dynamic Type 対応。
    private var header: some View {
        VStack(spacing: 6) {
            Text("Hypnoctone")
                .font(.system(.title, design: .rounded).weight(.light))
                .foregroundColor(Theme.primaryText)
            Text(viewModel.currentModeLabel)
                .font(.system(.subheadline, design: .rounded))
                .tracking(2)
                .foregroundColor(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hypnoctone, \(viewModel.currentModeLabel)")
    }

    /// 再生状態テキスト。Task 29: 元 15pt 固定 → `.callout` で Dynamic Type 対応 +
    /// VoiceOver に "Playback playing" / "Playback stopped" と明示。
    private var statusText: some View {
        Text(viewModel.statusText)
            .font(.system(.callout, design: .rounded))
            .foregroundColor(Theme.secondaryText)
            .accessibilityLabel(viewModel.isPlaying ? "Playback playing" : "Playback stopped")
    }

    /// 5 モード切替セレクタ (Task 22 で 4 mode 導入、Task 30 で BINAURAL 追加)。
    /// - 現在モードは Theme.accent でハイライト、他モードはサブテキスト色
    /// - canChangeMode = false (再生中・fade-out 中) なら全ボタン無効化 + 補足メッセージ
    /// - Rhythm 表示 (preset.rhythmDisplay) を右側に小さく ("BPM N" or "N Hz")
    /// - 切替は Stop 状態のみ可能 (audio 層の Task 21 setMode が isRunning ガード)
    ///
    /// Task 30: 5 mode を 3 列 LazyVGrid で配置 (上段 SLEEP/FOCUS/MEDITATE、下段 RELAX/BINAURAL/空)。
    /// 5 mode 横並びは iPhone SE 幅 + Dynamic Type 大設定で潰れるため Grid 化 (Codex Task 30 Medium 反映)。
    private var modeSelector: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: modeGridColumns, spacing: 6) {
                ForEach(viewModel.allModes) { mode in
                    modeButton(mode: mode)
                }
            }
            // canChangeMode が false (= 再生中 / fade-out 中) のときは補足メッセージで誘導する。
            // BINAURAL モード中は "Headphones recommended" を表示 (Codex Task 30 Low 反映)。
            // BPM/Hz 表示は常時出して「このモードのリズム感」を視覚化する。
            HStack {
                modeNotice
                Spacer()
                Text(viewModel.rhythmDisplayText)
                    .font(.system(.caption2, design: .rounded))
                    .tracking(1)
                    .foregroundColor(Theme.secondaryText)
                    .accessibilityLabel(viewModel.rhythmDisplayAccessibilityText)
            }
            .padding(.horizontal, 2)
        }
    }

    /// 3 列 grid 用 GridItem 配列。flexible で等幅に分配される。
    private var modeGridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 6),
         GridItem(.flexible(), spacing: 6),
         GridItem(.flexible(), spacing: 6)]
    }

    /// BPM/Hz 表示行の左側に出す補足メッセージ。
    /// 優先順位: canChangeMode=false の警告 > BINAURAL の headphone 推奨。
    @ViewBuilder
    private var modeNotice: some View {
        if !viewModel.canChangeMode {
            Text("Stop playback to change mode")
                .font(.system(.caption2, design: .rounded))
                .foregroundColor(Theme.secondaryText)
                .opacity(0.7)
        } else if viewModel.isBinauralMode {
            Text("Headphones recommended")
                .font(.system(.caption2, design: .rounded))
                .foregroundColor(Theme.secondaryText)
                .opacity(0.7)
        }
    }

    /// 1 モード分のボタン。現在モードはハイライト、他モードはサブ色。
    /// canChangeMode が false なら全ボタン半透明 + tap 無効。
    ///
    /// Tap target: Apple HIG の 44pt 最小推奨を満たすため `.frame(minHeight: 44)`。
    /// MEDITATE (8 文字) が iPhone SE 幅で詰まらないよう `minimumScaleFactor(0.7)` で
    /// 縮小も許容 (Codex Task 22 High/Low 指摘反映)。
    /// アクセシビリティ: 現在モードに `.accessibilityValue("Current mode")`、
    /// disabled に `.accessibilityHint("Stop playback to change mode")` で VoiceOver 補足。
    /// Task 29: font を `.caption2.weight(.medium)` で Dynamic Type 対応。
    private func modeButton(mode: Mode) -> some View {
        let isCurrent = (viewModel.currentMode == mode)
        let canChange = viewModel.canChangeMode

        return Button {
            viewModel.setMode(mode)
        } label: {
            Text(mode.label)
                .font(.system(.caption2, design: .rounded).weight(.medium))
                .tracking(1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(isCurrent ? Theme.primaryText : Theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accent.opacity(isCurrent ? 0.35 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.accent.opacity(isCurrent ? 0.6 : 0.20), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canChange)
        // canChangeMode false のとき全体を薄く (disabled モード示唆)。現在モードボタンも一緒に薄くなる
        // のは「触れない状態」を一貫表現するため。
        .opacity(canChange ? 1.0 : 0.5)
        .accessibilityLabel(mode.label)
        .accessibilityValue(isCurrent ? "Current mode" : "")
        .accessibilityHint(canChange ? "" : "Stop playback to change mode")
    }

    /// 音楽理論ベースの情報表示（Task 15 で追加、Task 20 で 4 voice グループ + MUTE に再構築）。
    /// ATMÓS の UI を倣い、Scale 名の下に TONE / DRONE / SUB / GRAIN の 4 列を横並びで表示する。
    /// 各列は: ラベル (TONE 等) + Note 名 (E4·A4 / A3 / A1 / C#5/E5/F#5/A5) + MUTE ボタン。
    /// MUTE ボタンは tap でトグルし、audio 層は 10ms ramp で 0/1 に補間 (クリックなし)。
    /// Stopped 状態でも見えるので CI screenshot で UI 確認可能。
    private var musicInfo: some View {
        VStack(spacing: 12) {
            Text("Scale \(viewModel.rootNoteName) \(viewModel.scaleName)")
                .font(.system(.caption, design: .rounded))
                .tracking(1)
                .foregroundColor(Theme.secondaryText)
                .accessibilityLabel("Scale \(viewModel.rootNoteName) \(viewModel.scaleName)")
            voiceGrid
        }
    }

    /// 4 voice グループの横並びグリッド (ATMÓS 風)。
    /// `voiceGroups` の各要素は `Identifiable` (VoiceGroupItem) なので id 引数不要。
    private var voiceGrid: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.voiceGroups) { vg in
                voiceCell(
                    label: vg.label,
                    noteName: vg.noteName,
                    isMuted: vg.isMuted,
                    muteExtraHint: muteExtraHint(for: vg.group)
                ) {
                    viewModel.toggleMute(vg.group)
                }
            }
        }
    }

    /// 特定 voice グループの MUTE ボタンに追加で出す accessibility hint (Task 30)。
    /// 現状は BINAURAL モード中の DRONE のみ「binaural beat を担う voice なので mute すると
    /// 効果が消える」旨を VoiceOver に伝える (Codex Task 30 Medium 反映で UX 注意喚起)。
    private func muteExtraHint(for group: AudioEngineController.VoiceGroup) -> String? {
        if viewModel.isBinauralMode && group == .drone {
            return "DRONE carries the binaural beat. Muting it removes the beat."
        }
        return nil
    }

    /// 1 voice 分のセル: ラベル / Note 名 / MUTE ボタン。
    /// MUTE 状態のとき: ボタンを点灯色、Note 名を半透明化して視覚的に「停止中」と分かるように。
    ///
    /// Task 29: voice ラベルと note 名を 1 つの accessibility element として読み上げる
    /// (例: "TONE voice, E4 and A4, playing")。MUTE ボタンは別個に label + value + hint。
    /// note 名の "·" / "/" 区切りは VoiceOver が読みづらいので "and" に置換する。
    /// Task 30: `muteExtraHint` で mode 固有の追加 hint を渡せる (例: BINAURAL + DRONE)。
    private func voiceCell(
        label: String,
        noteName: String,
        isMuted: Bool,
        muteExtraHint: String? = nil,
        onMuteTap: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            VStack(spacing: 6) {
                Text(label)
                    .font(.system(.caption2, design: .rounded))
                    .tracking(1.5)
                    .foregroundColor(Theme.secondaryText)
                Text(noteName)
                    .font(.system(.footnote, design: .rounded).weight(.light))
                    .foregroundColor(isMuted ? Theme.secondaryText : Theme.primaryText)
                    .opacity(isMuted ? 0.4 : 1.0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) voice, \(spokenNoteName(noteName)), \(isMuted ? "muted" : "playing")")

            Button(action: onMuteTap) {
                Text("MUTE")
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .tracking(1)
                    .foregroundColor(isMuted ? Theme.accent : Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent.opacity(isMuted ? 0.30 : 0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.accent.opacity(isMuted ? 0.6 : 0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) mute")
            .accessibilityValue(isMuted ? "On" : "Off")
            .accessibilityHint(combinedMuteHint(label: label, extra: muteExtraHint))
        }
        .frame(maxWidth: .infinity)
    }

    /// MUTE ボタン用の accessibility hint を組み立てる。
    /// 基本: "Toggle <label> voice mute"。`extra` 非 nil なら "Toggle ... . <extra>" を結合。
    private func combinedMuteHint(label: String, extra: String?) -> String {
        let base = "Toggle \(label) voice mute"
        guard let extra = extra, !extra.isEmpty else { return base }
        return "\(base). \(extra)"
    }

    /// "E4·A4" や "C#5/E5/F#5/A5" のような note 名表記を VoiceOver 用に変換する。
    /// "·" / "/" 区切りは VoiceOver では読み上げが不自然なため "and" で置換。
    private func spokenNoteName(_ noteName: String) -> String {
        return noteName
            .replacingOccurrences(of: "·", with: " and ")
            .replacingOccurrences(of: "/", with: " and ")
    }

    /// Start / Stop ボタン。Task 29: font を `.body.weight(.medium)` で Dynamic Type 対応 +
    /// VoiceOver に意図を伝える label/hint を追加。
    private var transportButton: some View {
        Button {
            viewModel.toggle()
        } label: {
            Text(viewModel.isPlaying ? "Stop" : "Start")
                .font(.system(.body, design: .rounded).weight(.medium))
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
        .accessibilityLabel(viewModel.isPlaying ? "Stop" : "Start")
        .accessibilityHint(viewModel.isPlaying ? "Stops the ambient audio" : "Starts the ambient audio")
    }

    /// Volume スライダー。
    /// Task 29: Slider に `.accessibilityValue("Volume \(percent)%")` で VoiceOver に
    /// 現在値を percentage で announce。
    private var volumeControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Volume")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundColor(Theme.secondaryText)
                Spacer()
            }
            Slider(value: $viewModel.volume, in: 0.0...1.0)
                .tint(Theme.accent)
                .accessibilityLabel("Volume")
                // 丸めは `Int(...)` 切り捨てではなく `.rounded()` で表示と操作感を揃える
                // (Codex Task 29 Low 反映)。
                .accessibilityValue("\(Int((viewModel.volume * 100).rounded())) percent")
        }
    }

    /// Sleep Timer 行 (Task 23, ATMÓS の "SLEEP TIMER" を機能化)。
    /// - Stop 状態 (`sleepTimerRemainingSeconds == nil`): Off/15/30/45/60/90 分のプリセットボタン
    /// - 再生中 (カウントダウン進行中): "Sleep Timer · mm:ss" の残り時間表示
    /// タイマー設定値 (`sleepTimerMinutes`) はハイライト、他はサブ色。
    /// 時間切れで自動的に stop() が走る (= fade-out → engine.stop()、ViewModel 側で実装)。
    private var timerLabel: some View {
        VStack(spacing: 6) {
            if viewModel.sleepTimerRemainingSeconds != nil {
                // 再生中 (カウントダウン中): 残り時間表示
                timerCountdownView
            } else {
                // Stop 状態: プリセット選択ボタン
                timerPresetButtons
            }
        }
    }

    /// 再生中のカウントダウン表示。
    /// "Sleep Timer · 14:32" 形式。タイマー Off のときは「カウントダウンなし」なので
    /// この view は呼ばれない (timerLabel が presetButtons 側を表示)。
    private var timerCountdownView: some View {
        Text("Sleep Timer · \(viewModel.sleepTimerRemainingText)")
            .font(.system(.caption, design: .rounded))
            .tracking(1)
            .foregroundColor(Theme.primaryText)
            .accessibilityLabel("Sleep Timer remaining \(viewModel.sleepTimerRemainingText)")
    }

    /// Off/15/30/45/60/90 分のプリセットボタン横並び。
    /// 現在の選択値はアクセント色、他はサブ色。再生中は表示されない (countdownView が代替)。
    private var timerPresetButtons: some View {
        HStack(spacing: 6) {
            Text("Timer")
                .font(.system(.caption2, design: .rounded))
                .tracking(1)
                .foregroundColor(Theme.secondaryText)
            ForEach(viewModel.sleepTimerPresetMinutes, id: \.self) { mins in
                timerPresetButton(minutes: mins)
            }
        }
    }

    /// 1 プリセット分のボタン。`minutes == nil` は "OFF"、それ以外は "15m" / "30m" 等。
    /// 現在選択中の値は Theme.accent でハイライト。
    ///
    /// Tap target: `minHeight: 32` は Apple HIG 推奨 44pt より小さい妥協。理由は画面下端で
    /// 横並び 6 ボタン + "Timer" ラベルの幅制約 (iPhone SE 約 320pt - padding) で 44pt を
    /// 揃えると幅も縦も詰まる。Sleep Timer 選択は起動時に 1 度だけの操作なので、頻繁な
    /// 誤タップは想定しにくく許容範囲とした。実機聴感調整後に Menu/Picker 化や 2 行 grid 化を
    /// 検討する余地あり (Codex Task 23 Medium 指摘: 将来改善候補)。
    private func timerPresetButton(minutes: Int?) -> some View {
        let isCurrent = (viewModel.sleepTimerMinutes == minutes)
        let label: String = minutes.map { "\($0)m" } ?? "Off"

        return Button {
            viewModel.setSleepTimer(minutes: minutes)
        } label: {
            Text(label)
                .font(.system(.caption2, design: .rounded).weight(.medium))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(isCurrent ? Theme.primaryText : Theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.accent.opacity(isCurrent ? 0.35 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Theme.accent.opacity(isCurrent ? 0.6 : 0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(minutes.map { "\($0) minute timer" } ?? "Timer off")
        .accessibilityValue(isCurrent ? "Selected" : "")
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}
