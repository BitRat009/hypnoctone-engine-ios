import Foundation

/// MIDI note 番号ベースで「音名 ↔ 周波数」を扱う型。
///
/// MIDI 標準: note 0 = C-1 (8.18Hz), note 60 = C4 (中央 C, 261.63Hz), note 69 = A4 (440Hz)。
/// 周波数は **平均律 (12 TET)** で計算する。これは ATMÓS など generative ambient アプリで
/// 標準的な選択で、後の Step 2 以降で「スケール内の任意の音を切り替える」ときに整合性が取れる。
///
/// Hypnoctone 既存の純正律 (5度=3/2=1.5) から平均律 (5度=2^(7/12)≈1.4983) に変わるので
/// 5度では 0.4Hz 程度の差が出るが、Sleep アプリ用途の LFO/envelope ゆらぎに紛れて
/// 聴感差は小さい想定。
struct Note: Equatable, Hashable {
    /// MIDI note 番号 (0..<128 が標準範囲)。
    let midiNumber: Int

    /// 平均律 (12 TET) での周波数 (Hz)。
    /// `freq = 440 × 2^((midi - 69) / 12)` （A4=440Hz 基準）
    var frequency: Double {
        440.0 * pow(2.0, Double(midiNumber - 69) / 12.0)
    }

    /// 音名表記 ("A3", "C#4" 等)。シャープは "#" で表記、フラットは使わない。
    var name: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = midiNumber / 12 - 1   // MIDI note 0 = C-1
        let pitch = names[midiNumber % 12]
        return "\(pitch)\(octave)"
    }

    init(midiNumber: Int) {
        // MIDI 標準範囲 0..<128 を強制。範囲外は呼び出し側のバグなので即座にクラッシュさせる
        // （Codex Task 15 指摘: name 計算の `midiNumber % 12` で負の index になる潜在バグの予防）。
        precondition((0..<128).contains(midiNumber),
                     "MIDI note number must be in 0..<128, got \(midiNumber)")
        self.midiNumber = midiNumber
    }

    /// 音名から構築。"A3", "C#4", "F#2", "C-1" 等。
    /// フラット (♭ や "b") は未対応。失敗時は nil。
    init?(name: String) {
        // 末尾の数字 (octave、マイナス記号も許容) を後ろから集める。
        var octaveDigits = ""
        for ch in name.reversed() {
            if ch.isNumber || ch == "-" {
                octaveDigits = String(ch) + octaveDigits
            } else {
                break
            }
        }
        guard !octaveDigits.isEmpty, let octave = Int(octaveDigits) else {
            return nil
        }
        let pitchPart = String(name.dropLast(octaveDigits.count))

        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        guard let pitchIndex = names.firstIndex(of: pitchPart) else {
            return nil
        }
        // MIDI 番号: (octave + 1) × 12 + pitch index で計算 (C-1 = MIDI 0)。
        let midi = (octave + 1) * 12 + pitchIndex
        // 範囲外 octave ("C-2" や "G10" 等) は init? として nil を返す。
        guard (0..<128).contains(midi) else { return nil }
        self.midiNumber = midi
    }
}

/// 音階 (スケール) — root note からの半音 interval 列で表す。
///
/// 例: Major Pentatonic = [0, 2, 4, 7, 9] (root 基準で 0/2/4/7/9 semitone 上の音)
/// C を root とすれば C, D, E, G, A の 5 音。
///
/// `notes(root:octaves:)` で展開して使う。Step 2 以降の generative pitch selection
/// で「スケール内の音をランダム/スケジュール選択」する基盤になる。
enum Scale {
    case majorPentatonic     // 5 音、明るく落ち着く
    case minorPentatonic     // 5 音、暗めで瞑想的
    case major               // 7 音、明朗
    case naturalMinor        // 7 音、落ち着いた暗さ
    case chromatic           // 12 音、全半音

    /// root を 0 とした半音 interval 列。
    var intervals: [Int] {
        switch self {
        case .majorPentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        case .major:           return [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor:    return [0, 2, 3, 5, 7, 8, 10]
        case .chromatic:       return Array(0..<12)
        }
    }

    /// UI 表示用の短い名前 (ATMÓS の "MajPentatonic" 等に倣う)。
    var shortName: String {
        switch self {
        case .majorPentatonic: return "MajPentatonic"
        case .minorPentatonic: return "MinPentatonic"
        case .major:           return "Major"
        case .naturalMinor:    return "Minor"
        case .chromatic:       return "Chromatic"
        }
    }

    /// スケール内の note を `root` から `octaves` 個の octave 範囲で展開して返す。
    ///
    /// 例: root=A3 (MIDI 57), octaves=2, majorPentatonic →
    ///   A3 B3 C#4 E4 F#4 / A4 B4 C#5 E5 F#5 （2 octave 分の 10 音）
    func notes(root: Note, octaves: Int) -> [Note] {
        precondition(octaves > 0, "octaves must be > 0")
        var result: [Note] = []
        for oct in 0..<octaves {
            for interval in intervals {
                result.append(Note(midiNumber: root.midiNumber + oct * 12 + interval))
            }
        }
        return result
    }
}
