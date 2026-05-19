import SwiftUI

/// Hypnoctone のオーディオビジュアライザー (Task 26)。
///
/// アプリアイコンと同じ「ぼんやり光る複数の重なった sine wave」のモチーフを
/// 動的アニメーションで表現する。リアル audio FFT は使わず、TimelineView の時刻
/// 関数で procedural に sine 波を生成することで、Sleep アプリ向けの省電力と
/// audio thread の安全性を両立する。
///
/// 4 voice (TONE / DRONE / SUB / GRAIN) を 1 本ずつ計 4 本の sine wave で表現:
/// - TONE (中高音 E4/A4): 中波長、中速、中振幅
/// - DRONE (A3): 中波長、中速、大振幅
/// - SUB (A1): 長波長、ゆっくり、大振幅
/// - GRAIN (高音 sparkle): 短波長、速い、小振幅
///
/// 各 voice の MUTE 状態で該当 wave が fade out (不透明度 0)、
/// isPlaying=false で全 wave が静止 (位相は Pause 直前の値で freeze) + 不透明度低下。
/// Mode 切替で global speed multiplier が変わる (SLEEP=0.6 / MEDITATE=0.3 等)。
///
/// ## パフォーマンス設計
/// - iOS 16+ Canvas + TimelineView(.animation) で GPU 加速描画
/// - **isPlaying=true** のときだけ TimelineView を使って 60fps 駆動。
/// - **isPlaying=false** のときは静的 Canvas を表示し、描画スケジュール自体を停止
///   (Codex Task 26 Medium 1 指摘反映)。
/// - 画面が描画対象でなくなれば SwiftUI の更新頻度は自然に落ちるため、
///   screen lock 中の追加コストは原則ゼロに近い (実装が保証する強い contract ではなく、
///   SwiftUI ライフサイクル上の期待値)。
/// - audio thread には一切タップせず、procedural 生成のみで描画する。
struct WaveVisualizerView: View {
    /// 再生中か。
    /// - true: TimelineView 駆動で 60fps 描画
    /// - false: 静的 Canvas で位相 freeze + 不透明度低下
    let isPlaying: Bool

    /// 各 voice の MUTE 状態を `VoiceGroup` をキーにした辞書で受け取る。
    /// 配列順序依存を排除するため、明示的なキー付与にした (Codex Task 26 Medium 3 反映)。
    /// 範囲外 / キー欠落は false (mute なし) として扱う (防御的)。
    let voiceMuted: [AudioEngineController.VoiceGroup: Bool]

    /// 現在のモード (speed multiplier の源)。
    let mode: Mode

    /// 再生開始時刻の基準。`onChange(of: isPlaying)` で「Resume 時に
    /// `pausedElapsed` 分だけ過去にずらす」ことで、Pause → Resume で wave が
    /// 同じ位相から継続する (位相ジャンプ防止、Codex Task 26 Medium 2 反映)。
    @State private var startDate = Date()

    /// Pause 直前の経過秒。Resume 時に startDate に戻して使う。
    @State private var pausedElapsed: TimeInterval = 0

    /// 4 voice 分の wave 静的パラメータを `VoiceGroup` キーでペア化。
    /// 配列順序依存を排除するため、明示的に group とペアで保持する。
    private static let waveParamsByGroup: [(group: AudioEngineController.VoiceGroup, params: WaveParams)] = [
        // TONE: 中高音、中波長、中速、中振幅
        (.tone,  WaveParams(xCycles: 1.5, timeFreq: 0.06,  amplitudeRatio: 0.18, baseOpacity: 0.55)),
        // DRONE: 中低音、中波長、中速、大振幅
        (.drone, WaveParams(xCycles: 1.0, timeFreq: 0.04,  amplitudeRatio: 0.22, baseOpacity: 0.65)),
        // SUB: 低音、長波長、ゆっくり、大振幅
        (.sub,   WaveParams(xCycles: 0.5, timeFreq: 0.025, amplitudeRatio: 0.30, baseOpacity: 0.45)),
        // GRAIN: 高音 sparkle、短波長、速い、小振幅
        (.grain, WaveParams(xCycles: 2.5, timeFreq: 0.10,  amplitudeRatio: 0.12, baseOpacity: 0.40)),
    ]

    var body: some View {
        Group {
            if isPlaying {
                // 再生中: TimelineView で 60fps 駆動。
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    Canvas { context, size in
                        let elapsed = timeline.date.timeIntervalSince(startDate)
                        renderWaves(context: context, size: size, t: elapsed)
                    }
                }
            } else {
                // 停止中: 静的 Canvas (描画スケジュール停止)。
                // pausedElapsed の位相で freeze するので Pause 直前の波形がそのまま残る。
                Canvas { context, size in
                    renderWaves(context: context, size: size, t: pausedElapsed)
                }
            }
        }
        .onChange(of: isPlaying) { playing in
            // iOS 16 互換のため `oldValue, newValue` 形式ではなく単引数版を使う。
            if playing {
                // Resume: 過去にずらした基準時刻にすることで、Pause 中も
                // 時間が流れていたかのように位相が継続する。
                startDate = Date().addingTimeInterval(-pausedElapsed)
            } else {
                // Pause: 現在の経過秒を保存して freeze。
                pausedElapsed = Date().timeIntervalSince(startDate)
            }
        }
        // MUTE / mode 切替時の不透明度・位相を 0.2 秒で滑らかに変化させる
        // (Codex Task 26 Low 1 反映、audio 側 10ms ramp との質感整合)。
        // Canvas 自体は per-frame 再描画なので、外側 modifier の animation は
        // ZStack の opacity / blur 変化には効くが Canvas 内部の opacity には届かない。
        // 代わりに Canvas closure 内で計算する opacity が onChange でアニメート
        // されるよう、`voiceMuted` 自体を animatable な辞書ではないので
        // ここでは `value: ...` 指定で update のタイミングを揃えるに留める。
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
    }

    /// 4 voice 分の wave を一括描画。
    private func renderWaves(context: GraphicsContext, size: CGSize, t: TimeInterval) {
        let speedMult = modeSpeedMultiplier()

        for (group, params) in Self.waveParamsByGroup {
            let isMuted = voiceMuted[group] ?? false
            let opacity = effectiveOpacity(base: params.baseOpacity, isMuted: isMuted)
            if opacity <= 0.001 { continue }
            drawWave(
                context: context,
                size: size,
                params: params,
                t: t,
                speedMult: speedMult,
                opacity: opacity
            )
        }
    }

    /// MUTE と isPlaying を反映した実効不透明度。
    /// - MUTE: 完全に非表示 (0)
    /// - Stop 状態: base × 0.3 で「淡く残る」程度に
    /// - Play 状態: base そのまま
    private func effectiveOpacity(base: Double, isMuted: Bool) -> Double {
        if isMuted { return 0 }
        return isPlaying ? base : base * 0.3
    }

    /// Mode 別の global speed 倍率。Modes.swift の bpm と方向性を合わせる
    /// (BPM が低いモード = wave がゆっくり)。
    /// 数値は初期値で、実機テスト後に Phase 7 で調整する想定。
    private func modeSpeedMultiplier() -> Double {
        switch mode {
        case .sleep:    return 0.6   // BPM 30
        case .focus:    return 1.0   // BPM 60
        case .meditate: return 0.3   // BPM 6 (極ゆっくり)
        case .relax:    return 0.8   // BPM 75
        }
    }

    /// 1 本の wave を「blur glow + sharp line」の 2 重描画で発光感込みで描く。
    /// アプリアイコン (wave-plus) の「ぼんやり光る波」を動的に再現するための工夫。
    private func drawWave(
        context: GraphicsContext,
        size: CGSize,
        params: WaveParams,
        t: TimeInterval,
        speedMult: Double,
        opacity: Double
    ) {
        let path = makeWavePath(size: size, params: params, t: t, speedMult: speedMult)

        // Glow layer: blur + 太め stroke で発光感を出す。
        var glowCtx = context
        glowCtx.addFilter(.blur(radius: 6))
        glowCtx.stroke(
            path,
            with: .color(Theme.accent.opacity(opacity * 0.6)),
            lineWidth: 3
        )

        // Sharp layer: blur なし、細めで芯を見せる。
        context.stroke(
            path,
            with: .color(Theme.accent.opacity(opacity)),
            lineWidth: 1.0
        )
    }

    /// `y(x, t) = centerY + amplitude * sin(2π * xCycles * x/W + 2π * timeFreq * t * speedMult)`
    /// で 1 本の sine wave を Path に展開する。steps=120 でビュー幅に対する解像度を確保。
    /// 解像度を上げ過ぎると CPU 負荷が増えるが、120 ステップなら 60fps でも余裕。
    private func makeWavePath(
        size: CGSize,
        params: WaveParams,
        t: TimeInterval,
        speedMult: Double
    ) -> Path {
        var path = Path()
        let steps = 120
        let centerY = size.height / 2
        let timePhase = 2.0 * .pi * params.timeFreq * t * speedMult

        for i in 0...steps {
            let normalizedX = Double(i) / Double(steps)
            let x = size.width * normalizedX
            let spatialPhase = normalizedX * (2.0 * .pi * params.xCycles)
            let y = centerY + params.amplitudeRatio * size.height * sin(spatialPhase + timePhase)
            let point = CGPoint(x: x, y: y)
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// 1 本の sine wave の固定パラメータ。
/// 4 voice (TONE / DRONE / SUB / GRAIN) ごとに 1 セット持つ。
private struct WaveParams {
    /// ビュー幅あたりの sine 波の山の数 (空間周波数)。
    /// 高 voice ほど大きい値 (短波長) になるよう設定する。
    let xCycles: Double

    /// 1 秒あたりの時間方向の周波数 (Hz)。
    /// 高 voice ほど速く揺れるよう設定する。
    let timeFreq: Double

    /// ビュー高さに対する振幅比 (0.0〜0.5)。
    /// 低 voice (SUB / DRONE) ほど大きい振幅、高 voice (GRAIN) ほど小さい振幅。
    let amplitudeRatio: Double

    /// MUTE / isPlaying 反映前の基本不透明度。
    /// 中音域 (DRONE / TONE) を主役として強く、SUB / GRAIN を脇役として弱めに。
    let baseOpacity: Double
}

struct WaveVisualizerView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            WaveVisualizerView(
                isPlaying: true,
                voiceMuted: [:],
                mode: .sleep
            )
            .frame(height: 240)
        }
    }
}
