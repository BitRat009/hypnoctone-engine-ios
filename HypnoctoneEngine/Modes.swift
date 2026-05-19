import Foundation

/// アプリの 6 モード (ATMÓS 風 + Task 30 で BINAURAL / Task 31 で GROUNDING 追加)。
///
/// 各モードは `ModePreset` で audio engine の各種 amp / grain rate / reverb wet / 表示単位 /
/// (BINAURAL のみ) L/R 絶対 Hz 差を切り替える。切替は `AudioEngineController.setMode(_:)`
/// で行うが、現状は **Stop 状態でのみ可能** (ATMÓS の "Stop playback to change mode" と同じ設計)。
///
/// 各モードの音響特徴 (audio path での違いの記述、医療効果の主張は避ける):
/// - **SLEEP**: 低音重心・grain 疎・reverb 強め (BPM 30)
/// - **FOCUS**: 中音域・ノイズ強め・grain 控えめ (BPM 60)
/// - **MEDITATE**: 重低音・極ゆっくり・深い reverb (BPM 6)
/// - **RELAX**: 中域明るめ・grain 多め (BPM 75)
/// - **BINAURAL**: root voice (A3) を L/R 絶対 5Hz 差で再生、他 voice は控えめ (5 Hz、Task 30)
///
/// 厳密な業界標準は無く、上記は Hypnoctone の音色アイデンティティとしての初期プリセット。
/// 実機テストで聴感調整する想定。
enum Mode: String, CaseIterable, Identifiable {
    case sleep
    case focus
    case meditate
    case relax
    case binaural
    case grounding

    var id: String { rawValue }

    /// UI 表示用の大文字ラベル (ATMÓS と同じ)。
    var label: String {
        switch self {
        case .sleep:     return "SLEEP"
        case .focus:     return "FOCUS"
        case .meditate:  return "MEDITATE"
        case .relax:     return "RELAX"
        case .binaural:  return "BINAURAL"
        case .grounding: return "GROUNDING"
        }
    }

    /// このモードに紐付くプリセット値。
    var preset: ModePreset {
        switch self {
        case .sleep:     return .sleep
        case .focus:     return .focus
        case .meditate:  return .meditate
        case .relax:     return .relax
        case .binaural:  return .binaural
        case .grounding: return .grounding
        }
    }
}

/// UI 上の「リズム表示」単位。`ModePreset.rhythmDisplay` で mode 別に切り替える
/// (Codex Task 30 Medium 反映で `bpm: Int` 兼用を廃止)。
///
/// - `.bpm(N)`: 既存 4 mode (SLEEP/FOCUS/MEDITATE/RELAX) で「モードの体感速度」を BPM で
/// - `.hz(N)`: BINAURAL mode でビート周波数を Hz で
///
/// 将来 BINAURAL 内で δ(2Hz)/θ(5Hz)/α(10Hz)/β(20Hz) を切り替える拡張時は `.hz` の値だけ
/// 変えれば UI 表示は自動追従する。
enum RhythmDisplay {
    case bpm(Int)
    case hz(Double)

    /// UI 表示用の文字列 (例: "BPM 30" / "5 Hz")。
    var displayText: String {
        switch self {
        case .bpm(let n): return "BPM \(n)"
        case .hz(let v):  return "\(formatted(v)) Hz"
        }
    }

    /// VoiceOver 用の発話文字列 (例: "Beats per minute 30" / "5 hertz")。
    var accessibilityText: String {
        switch self {
        case .bpm(let n): return "Beats per minute \(n)"
        case .hz(let v):  return "\(formatted(v)) hertz"
        }
    }

    /// 整数値 (例: 5.0 → "5") と小数値 (例: 5.5 → "5.5") を見やすく整形する。
    private func formatted(_ v: Double) -> String {
        if v == v.rounded() {
            return String(Int(v))
        }
        return String(format: "%.1f", v)
    }
}

/// 1 モードのプリセット値。AudioEngineController がこの値を読んで全 generator のパラメータを更新する。
///
/// 簡素化方針 (Task 21 初期実装):
/// - **rootNote / scale は全モード共通 (A3 MajPentatonic)** で audio path を簡略化
/// - 切替対象は: 各 drone amp / noise amp / grain rate / grain amp / reverb wet / 表示 BPM 等
/// - 実機テスト後に「FOCUS は中音域に、MEDITATE は重低音に」のような root 切替が必要になったら拡張
///
/// Task 30 で `binauralBeatHz: Double?` を追加。non-nil の mode (= BINAURAL) では root voice を
/// 既存 cent ベース detune の代わりに絶対 Hz 差で L/R 分割する (StereoDetuneMode 経由)。
/// 他 voice (sub/5th/octave) は既存と同じ cent detune を維持。
///
/// `rhythmDisplay` は UI 表示用の単位 (BPM or Hz)。audio engine には影響しない。
/// 内部の LFO/envelope 周期は全 mode 共通で、Mode 切替の聴感差は amp バランス + grain trigger
/// 頻度 + reverb 深さ + (BINAURAL のみ) L/R 絶対 Hz 差 で表現する。
struct ModePreset {
    /// Drone[0] = sub bass voice の amp (A1=55Hz)。
    let subAmp: Float

    /// Drone[1] = root voice の amp (A3=220Hz)。BINAURAL では binaural beat の主成分。
    let rootAmp: Float

    /// Drone[2] = 5th voice の amp (E4=329.63Hz)。
    let fifthAmp: Float

    /// Drone[3] = octave voice の amp (A4=440Hz)。
    let octaveAmp: Float

    /// Noise (ピンクノイズ + lowpass) の amp。
    let noiseAmp: Float

    /// Grain trigger 期待値 (1 channel あたり 1 秒間に発火する grain 数)。
    let grainTriggersPerSecond: Double

    /// Grain 1 個あたりの最大 amp。
    let grainAmp: Float

    /// Grain 候補 pitch (Hz)。trigger 時に uniform random で選ばれる。
    /// 通常は scale (A MajPentatonic) 内の高音域 4 候補。
    let grainPitches: [Double]

    /// Reverb の wet/dry ミックス比 (0.0〜100.0、AVAudioUnitReverb.wetDryMix と同等)。
    let reverbWetDryMix: Float

    /// UI 表示用のリズム単位 (Task 30 で `bpm: Int` から拡張)。
    /// `.bpm(N)` または `.hz(N)`。audio engine には影響しない。
    let rhythmDisplay: RhythmDisplay

    /// BINAURAL mode 用: root voice (DRONE [1]) の L/R 絶対 Hz 差 (Task 30)。
    /// `nil`: 既存 cent ベース detune を維持 (4 mode 用)。
    /// non-nil: L = centerFreq - beatHz/2、R = centerFreq + beatHz/2 で固定。
    let binauralBeatHz: Double?

    /// GROUNDING mode 用: sub voice (DRONE [0]) の中央周波数を override (Task 31)。
    /// `nil`: A1=55Hz default (既存 5 mode)。
    /// non-nil: 指定 Hz に setFrequency。GROUNDING では G2≒98Hz で「100Hz 帯の低音レイヤー」を提供。
    let subBassFrequencyHz: Double?

    // MARK: - 6 モードの初期プリセット

    /// SLEEP モード (デフォルト、Task 20 までの現状を維持):
    /// 低音重心 (sub 込み) / grain 適度 / reverb 強め / BPM 30。
    static let sleep = ModePreset(
        subAmp: 0.05,
        rootAmp: 0.15,
        fifthAmp: 0.08,
        octaveAmp: 0.05,
        noiseAmp: 0.08,
        grainTriggersPerSecond: 1.0,
        grainAmp: 0.04,
        grainPitches: [554.37, 659.26, 739.99, 880.00],  // C#5 / E5 / F#5 / A5
        reverbWetDryMix: 40.0,
        rhythmDisplay: .bpm(30),
        binauralBeatHz: nil,
        subBassFrequencyHz: nil
    )

    /// FOCUS モード:
    /// sub を切って中音域寄り / ノイズ強め / grain 控えめ / reverb 控えめ / BPM 60。
    static let focus = ModePreset(
        subAmp: 0.0,
        rootAmp: 0.12,
        fifthAmp: 0.06,
        octaveAmp: 0.04,
        noiseAmp: 0.10,
        grainTriggersPerSecond: 0.8,
        grainAmp: 0.03,
        grainPitches: [554.37, 659.26, 739.99, 880.00],
        reverbWetDryMix: 25.0,
        rhythmDisplay: .bpm(60),
        binauralBeatHz: nil,
        subBassFrequencyHz: nil
    )

    /// MEDITATE モード:
    /// 重低音強め / grain 極疎 / reverb 深い / BPM 6 (10 秒呼吸サイクル相当)。
    static let meditate = ModePreset(
        subAmp: 0.07,
        rootAmp: 0.18,
        fifthAmp: 0.10,
        octaveAmp: 0.06,
        noiseAmp: 0.04,
        grainTriggersPerSecond: 0.3,
        grainAmp: 0.05,
        grainPitches: [554.37, 659.26, 739.99, 880.00],
        reverbWetDryMix: 65.0,
        rhythmDisplay: .bpm(6),
        binauralBeatHz: nil,
        subBassFrequencyHz: nil
    )

    /// RELAX モード:
    /// 中域明るめ / grain 多め / reverb 中程度 / BPM 75。
    static let relax = ModePreset(
        subAmp: 0.04,
        rootAmp: 0.13,
        fifthAmp: 0.07,
        octaveAmp: 0.05,
        noiseAmp: 0.07,
        grainTriggersPerSecond: 1.5,
        grainAmp: 0.05,
        grainPitches: [554.37, 659.26, 739.99, 880.00],
        reverbWetDryMix: 35.0,
        rhythmDisplay: .bpm(75),
        binauralBeatHz: nil,
        subBassFrequencyHz: nil
    )

    /// BINAURAL モード (Task 30): root voice を L/R 絶対 5Hz 差で再生して binaural beat を作る。
    /// 他 voice / noise / grain は控えめにして binaural の左右差を聴き取りやすくする。
    /// Reverb は 30 (4 mode より低め) で空間を狭めることで beat の明瞭性を保つ
    /// (Codex Task 30 Low 反映、50→30 に下げて左右差の聴感を優先)。
    /// ヘッドフォン推奨だがスピーカーでも害なし (両耳に違う周波数が届かないので「ただの 2 音」になる)。
    ///
    /// **音響特性の注意** (Codex Task 30 Medium 反映、実装後 review):
    /// - root voice の **harmonics** (2倍音 = 440Hz, 3倍音 = 660Hz) も L/R で比例的に差が出る:
    ///   基音 5Hz 差、2倍音 10Hz 差、3倍音 15Hz 差。「純粋な 5Hz beat」ではなく
    ///   「5/10/15Hz 複合差」の音色になる。聴感上は「重なる微小揺らぎ」として表現される。
    /// - root voice の **pitch LFO** (lfoDepthCents 2.5) も absoluteBeatHz mode で center を
    ///   微小に揺らすため、L/R 差は厳密 5.000Hz 固定ではなく約 5Hz の揺らぎを伴う。
    /// - 厳密 5Hz 固定 + harmonics 無効化が必要な場合は Phase 8 で BINAURAL 専用 API (harmonics
    ///   suppression や LFO bypass) を追加する余地あり。現状は実機聴感を優先して上記特性を許容。
    static let binaural = ModePreset(
        subAmp: 0.03,      // 重低音は薄め (binaural の知覚を阻害しないため)
        rootAmp: 0.22,     // root を強めにして binaural beat を聴きやすく
        fifthAmp: 0.04,    // 5度は控えめ (binaural beat の明瞭性優先)
        octaveAmp: 0.03,
        noiseAmp: 0.02,    // ノイズ極小
        grainTriggersPerSecond: 0.3,
        grainAmp: 0.03,
        grainPitches: [554.37, 659.26, 739.99, 880.00],
        reverbWetDryMix: 30.0,  // 4 mode より控えめで左右差を聴感優先
        rhythmDisplay: .hz(5.0),
        binauralBeatHz: 5.0,    // L=217.5Hz / R=222.5Hz (A3=220Hz 中心の ±2.5Hz)
        subBassFrequencyHz: nil
    )

    /// GROUNDING モード (Task 31): 100Hz 帯の低周波純音 + 6Hz binaural を複合した低周波重心 ambient。
    ///
    /// 「単音だと聞いていられない」問題を回避するため、以下を組み合わせる:
    /// - **SUB voice** を G2 (97.999Hz) に override → 100Hz 帯の低音レイヤー
    /// - **DRONE (root) voice** に 6Hz binaural beat (θ-α 境界、BINAURAL 5Hz より高め)
    /// - **NOISE / 5th / octave / GRAIN / REVERB** を控えめに敷いて「聞いていられる」音色の豊かさを確保
    ///
    /// 命名・説明文の方針: 「motion sickness / 乗り物酔い / 前庭神経」等の direct claim は避け、
    /// 「100Hz 中心の低周波 ambient と 6Hz binaural を組み合わせた静かな音響」程度の中立記述
    /// (App Store reject リスク回避)。科学的エビデンスは限定的なので効果を断定しない。
    static let grounding = ModePreset(
        subAmp: 0.12,           // 100Hz 帯純音を主役にして強め
        rootAmp: 0.10,          // 6Hz binaural beat 用、控えめ
        fifthAmp: 0.04,         // 音色豊かさのため薄く
        octaveAmp: 0.03,
        noiseAmp: 0.06,         // 低域ノイズ (cutoff は既存設定維持)
        grainTriggersPerSecond: 0.2,  // 極疎 (5 秒に 1 発、気にならない sparkle)
        grainAmp: 0.02,
        grainPitches: [554.37, 659.26, 739.99, 880.00],
        reverbWetDryMix: 40.0,  // SLEEP と同じ程度、BINAURAL より広め
        rhythmDisplay: .hz(6.0),
        binauralBeatHz: 6.0,    // root voice L=217Hz / R=223Hz (A3=220Hz 中心の ±3Hz)
        subBassFrequencyHz: 97.999  // G2 (MIDI 43、A3 から minor 7th 下)、100Hz 帯純音刺激候補
    )
}
