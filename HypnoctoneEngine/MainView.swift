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

            VStack(spacing: 20) {
                header
                Spacer(minLength: 4)
                PulseView(isActive: viewModel.isPlaying)
                Spacer(minLength: 4)
                statusText
                modeSelector
                musicInfo
                transportButton
                volumeControl
                timerLabel
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        }
        .preferredColorScheme(.dark)
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

    /// アプリ名と現在モード名。Task 22 で subtitle を `viewModel.currentModeLabel` 動的化
    /// ("Sleep Mode" / "Focus Mode" / "Meditate Mode" / "Relax Mode")。
    private var header: some View {
        VStack(spacing: 6) {
            Text("Hypnoctone")
                .font(.system(size: 30, weight: .light, design: .rounded))
                .foregroundColor(Theme.primaryText)
            Text(viewModel.currentModeLabel)
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

    /// 4 モード切替セレクタ (Task 22, ATMÓS 風 SLEEP/FOCUS/MEDITATE/RELAX)。
    /// - 現在モードは Theme.accent でハイライト、他モードはサブテキスト色
    /// - canChangeMode = false (再生中・fade-out 中) なら全ボタン無効化 + 補足メッセージ
    /// - BPM 表示 (preset.bpm) を右側に小さく
    /// - 切替は Stop 状態のみ可能 (audio 層の Task 21 setMode が isRunning ガード)
    private var modeSelector: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(viewModel.allModes) { mode in
                    modeButton(mode: mode)
                }
            }
            // canChangeMode が false (= 再生中 / fade-out 中) のときは補足メッセージで誘導する。
            // 一方 BPM 表示は常時出して「このモードのリズム感」を視覚化する。
            HStack {
                if !viewModel.canChangeMode {
                    Text("Stop playback to change mode")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundColor(Theme.secondaryText)
                        .opacity(0.7)
                }
                Spacer()
                Text("BPM \(viewModel.bpm)")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .tracking(1)
                    .foregroundColor(Theme.secondaryText)
            }
            .padding(.horizontal, 2)
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
    private func modeButton(mode: Mode) -> some View {
        let isCurrent = (viewModel.currentMode == mode)
        let canChange = viewModel.canChangeMode

        return Button {
            viewModel.setMode(mode)
        } label: {
            Text(mode.label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
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
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .tracking(1)
                .foregroundColor(Theme.secondaryText)
            voiceGrid
        }
    }

    /// 4 voice グループの横並びグリッド (ATMÓS 風)。
    /// `voiceGroups` の各要素は `Identifiable` (VoiceGroupItem) なので id 引数不要。
    private var voiceGrid: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.voiceGroups) { vg in
                voiceCell(label: vg.label, noteName: vg.noteName, isMuted: vg.isMuted) {
                    viewModel.toggleMute(vg.group)
                }
            }
        }
    }

    /// 1 voice 分のセル: ラベル / Note 名 / MUTE ボタン。
    /// MUTE 状態のとき: ボタンを点灯色、Note 名を半透明化して視覚的に「停止中」と分かるように。
    private func voiceCell(label: String, noteName: String, isMuted: Bool, onMuteTap: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .tracking(1.5)
                .foregroundColor(Theme.secondaryText)
            Text(noteName)
                .font(.system(size: 13, weight: .light, design: .rounded))
                .foregroundColor(isMuted ? Theme.secondaryText : Theme.primaryText)
                .opacity(isMuted ? 0.4 : 1.0)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Button(action: onMuteTap) {
                Text("MUTE")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
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
        }
        .frame(maxWidth: .infinity)
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
