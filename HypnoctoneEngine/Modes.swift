import Foundation

/// アプリの 4 モード (ATMÓS 風)。SLEEP / FOCUS / MEDITATE / RELAX の動作プロファイル。
///
/// 各モードは `ModePreset` で audio engine の各種 amp / grain rate / reverb wet を切り替える。
/// 切替は `AudioEngineController.setMode(_:)` で行うが、現状は **Stop 状態でのみ可能**
/// (ATMÓS の "Stop playback to change mode" と同じ設計)。これにより engine.stop() 完了後の
/// audio thread が動いていない状態でしか generator のパラメータを書き換えないため、
/// thread safety を atomic publish なしで確保できる。
///
/// 各モードの音響特徴 (脳波研究・音響心理学・既存アプリの慣行に基づく方向性):
/// - **SLEEP**: 低音重心・grain 疎・reverb 強め (δ-θ 波 0.5〜8Hz 領域、眠気誘導)
/// - **FOCUS**: 中音域・ノイズ強め (集中の壁)・grain 控えめ (β 波 14〜20Hz、集中)
/// - **MEDITATE**: 重低音・極ゆっくり・深い reverb (θ 波 4〜8Hz、瞑想)
/// - **RELAX**: 中域明るめ・grain 多め (α 波 8〜13Hz、覚醒維持リラックス)
///
/// 厳密な業界標準は無く、上記は Hypnoctone の音色アイデンティティとしての初期プリセット。
/// 実機テストで聴感調整する想定。
enum Mode: String, CaseIterable, Identifiable {
    case sleep
    case focus
    case meditate
    case relax

    var id: String { rawValue }

    /// UI 表示用の大文字ラベル (ATMÓS と同じ)。
    var label: String {
        switch self {
        case .sleep:    return "SLEEP"
        case .focus:    return "FOCUS"
        case .meditate: return "MEDITATE"
        case .relax:    return "RELAX"
        }
    }

    /// このモードに紐付くプリセット値。
    var preset: ModePreset {
        switch self {
        case .sleep:    return .sleep
        case .focus:    return .focus
        case .meditate: return .meditate
        case .relax:    return .relax
        }
    }
}

/// 1 モードのプリセット値。AudioEngineController がこの値を読んで全 generator のパラメータを更新する。
///
/// 簡素化方針 (Task 21 初期実装):
/// - **rootNote / scale は全モード共通 (A3 MajPentatonic)** で audio path を簡略化
/// - 切替対象は: 各 drone amp / noise amp / grain rate / grain amp / reverb wet / 表示 BPM のみ
/// - 実機テスト後に「FOCUS は中音域に、MEDITATE は重低音に」のような root 切替が必要になったら拡張
///
/// `bpm` は audio engine には影響せず UI 表示用 (ATMÓS の "BPM 30" 表記を再現)。
/// 内部の LFO/envelope 周期も共通 (Task 20 までの値を保持) で、Mode 切替の聴感差は
/// あくまで amp バランス + grain trigger 頻度 + reverb 深さ で表現する。
struct ModePreset {
    /// Drone[0] = sub bass voice の amp (A1=55Hz)。
    let subAmp: Float

    /// Drone[1] = root voice の amp (A3=220Hz)。
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

    /// UI 表示用の BPM 値 (audio engine には影響しない)。
    /// ATMÓS の "BPM 30" 表記と同じく「モードの体感速度」を数字化したもの。
    let bpm: Int

    // MARK: - 4 モードの初期プリセット

    /// SLEEP モード (デフォルト、Task 20 までの現状を維持):
    /// 低音重心 (sub 込み) / grain 適度 / reverb 強め / BPM 30。
    /// δ-θ 波領域の「眠気誘導」音響。
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
        bpm: 30
    )

    /// FOCUS モード:
    /// sub を切って中音域寄り / ノイズ強め (集中の壁) / grain 控えめ / reverb 控えめ / BPM 60。
    /// β 波領域の「集中」音響。
    static let focus = ModePreset(
        subAmp: 0.0,        // sub を実質 mute (集中時は重低音不要)
        rootAmp: 0.12,
        fifthAmp: 0.06,
        octaveAmp: 0.04,
        noiseAmp: 0.10,     // ノイズを強めて「集中の壁」(コーヒーショップ的)
        grainTriggersPerSecond: 0.8,
        grainAmp: 0.03,
        grainPitches: [554.37, 659.26, 739.99, 880.00],
        reverbWetDryMix: 25.0,  // 空間を狭く (集中阻害しない)
        bpm: 60
    )

    /// MEDITATE モード:
    /// 重低音強め / grain 極疎 / reverb 深い / BPM 6 (10 秒呼吸サイクル相当)。
    /// θ 波領域の「瞑想・内省」音響。シンギングボウル/ドローン系。
    static let meditate = ModePreset(
        subAmp: 0.07,       // 重低音を強めて瞑想感
        rootAmp: 0.18,
        fifthAmp: 0.10,
        octaveAmp: 0.06,
        noiseAmp: 0.04,     // ノイズ抑えて静寂感
        grainTriggersPerSecond: 0.3,  // 極疎 (約 3 秒に 1 発)
        grainAmp: 0.05,
        grainPitches: [554.37, 659.26, 739.99, 880.00],
        reverbWetDryMix: 65.0,  // 深い空間
        bpm: 6
    )

    /// RELAX モード:
    /// 中域明るめ / grain 多め / reverb 中程度 / BPM 75。
    /// α 波領域の「リラックスするが覚醒維持」音響。
    static let relax = ModePreset(
        subAmp: 0.04,
        rootAmp: 0.13,
        fifthAmp: 0.07,
        octaveAmp: 0.05,
        noiseAmp: 0.07,
        grainTriggersPerSecond: 1.5,  // やや密 (明るい sparkle)
        grainAmp: 0.05,
        grainPitches: [554.37, 659.26, 739.99, 880.00],
        reverbWetDryMix: 35.0,
        bpm: 75
    )
}
