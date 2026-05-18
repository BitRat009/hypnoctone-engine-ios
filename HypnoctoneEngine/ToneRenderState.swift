import Foundation
import Atomics

/// 1 つの倍音（harmonic partial）の状態。基音に対する周波数比と振幅係数、
/// および L/R 別の位相情報を保持する。`ToneRenderState.harmonics` 配列の要素として使われる。
///
/// 倍音の phaseIncrement は **render block 内で `基音 phaseIncrement × ratio × lfoMod` として
/// 都度計算**する。これにより Task 16 の generative pitch (setFrequency による glide で
/// 基音 phaseIncrement が動く) にも倍音が自動連動する。
struct HarmonicVoice {
    /// 基音に対する周波数比（2.0 = 第 2 倍音、3.0 = 第 3 倍音）。
    let ratio: Double

    /// 基音振幅に対する相対振幅（0.2 なら基音の 20%）。
    let amplitudeFactor: Float

    /// L チャネルの現在位相（audio thread が単一所有で更新）。
    var phaseLeft: Double

    /// R チャネルの現在位相（audio thread が単一所有で更新）。
    var phaseRight: Double
}

/// サイン波生成と振幅補間（フェードイン / フェードアウト）に必要な状態を保持するクラス。
///
/// `DroneGenerator` の内部実装として使われる。`AVAudioSourceNode` の render block と
/// メインスレッド（fade スケジュール）の両方から参照される。
/// render block はリアルタイムのオーディオスレッドで実行されるため、
/// ここではアロケーション・ロック・I/O を行わず、単純な数値の読み書きだけに留める。
///
/// ## スレッドモデル（pending / active 分離 + odd/even seqlock）
///
/// data race を完全に排除するため、状態を 3 つのグループに分ける:
///
/// 1. **Audio thread 単一所有**（writer も reader も audio thread のみ）
///    - `phase`, `currentAmplitude`, `activeTargetAmplitude`, `activeFadeFramesRemaining`,
///      `lastConsumedGeneration`
///    - render block 内で自由に読み書きできる。コンフリクトしない。
///
/// 2. **Main writer / Audio reader（pending command）** — **全 atomic**
///    - `pendingTargetAmplitudeBits`（Float の bitPattern を保持）, `pendingFadeFrames`,
///      `pendingGeneration`
///    - メインスレッドの `scheduleFade*` が odd/even seqlock writer プロトコルで publish。
///    - audio thread が render block で seqlock reader プロトコルで consume。
///
/// 3. **定数**
///    - `frequency`, `sampleRate`, `phaseIncrement`, `twoPi`, `defaultAmplitude`
///
/// ## なぜ odd/even seqlock + atomic が必要か（Task 7 で厳密化した経緯）
///
/// 以前（Task 6）は `pendingTargetAmplitude` を plain `Float` にして seqlock 風プロトコルで
/// 凌いでいたが、以下 2 種類の race が理論的に残っていた:
///
/// - **store-store reordering**: コンパイラ・CPU が `pendingGeneration` の更新を
///   `pendingTargetAmplitude` / `pendingFadeFrames` の書き込みより先に observable にする
///   可能性があり、audio が stale payload を accept する穴があった。
/// - **plain field 上の torn read**: Float の 4 バイトが部分的に書き換えられ得る（実機
///   ARM64 でアラインされた 32bit access は実用上 atomic だが、Swift memory model 上は UB）。
///
/// Task 7 第 1 弾で `pending*` をすべて `ManagedAtomic` 化し、release/acquire memory ordering
/// を pendingGeneration に乗せ、reader 側で gen を pre/post 2 回 acquire-load する
/// seqlock 風プロトコルにした。しかし Codex 2 回目レビューで残課題が判明:
///
/// - **writer mid-payload window**: writer が target/frames を書き終え、まだ gen を
///   increment していない瞬間に reader が走ると、`g1 == g2` を通過してしまい、
///   新 payload を旧 generation 名義で commit する穴があった。
///
/// Task 7 第 2 弾（現状）で odd/even seqlock に切り替えた:
///
/// - **publish 順序**（main 側）:
///   1. `gen.wrappingIncrement(.acquiringAndReleasing)` — odd（書き込み中マーカー）。
///      `.acquiringAndReleasing` で後続 payload store が odd marker より前に
///      出ないことを保証する（`.releasing` だけだと「以前の操作」しか release できず、
///      後続 store の前倒しを防げない）。
///   2. `target.store(.relaxed)` / `frames.store(.relaxed)`
///   3. `gen.wrappingIncrement(.releasing)` — even（公開済みマーカー）。
///      payload store の publish と「writer 完了」の通知を兼ねる。
///
/// - **observe 順序**（audio 側）:
///   1. `g1 = gen.load(.acquiring)`
///   2. `g1` が odd なら writer 書き込み中 → skip
///   3. `g1 == lastConsumedGeneration` なら新コマンド無し → skip
///   4. `target.load(.relaxed)` / `frames.load(.relaxed)`
///   5. `g2 = gen.load(.acquiring)`
///   6. `g1 == g2` で reader 読み中に writer が割り込まなかったと確定 → commit
///   7. 不一致なら skip（次ブロックで retry）
///
/// odd/even により「writer mid-payload」が gen の奇数性で表現され、reader 側で確実に
/// 検出できる。`g1 == g2` の post-check も併用することで「reader が target/frames を
/// 読んだ後に writer が走った」ケースも検出できる。これで multi-field snapshot の
/// 整合性が完全に保証される。
///
/// ## 補足: なぜ `lastConsumedGeneration` は atomic ではないか
///
/// audio thread の単一所有なので race しない。render block の入口で読み、commit 時に書き、
/// 同一スレッド内で完結する。初期値 0（even）。最初の writer が gen を 1 → 2 と進めるので
/// reader は gen=2 を新コマンドとして consume できる。
final class ToneRenderState {

    // MARK: - 定数

    /// 生成するサイン波の中心周波数（Hz）。L/R の幾何平均がこの値になる
    /// （L = freq × 2^(-detune/2400), R = freq × 2^(detune/2400) なので √(fL × fR) = freq）。
    let frequency: Double

    /// L チャネル用の実周波数（Hz）。中心から detune の半分だけ低い側。
    let frequencyLeft: Double

    /// R チャネル用の実周波数（Hz）。中心から detune の半分だけ高い側。
    let frequencyRight: Double

    /// レンダリングに使うサンプルレート（Hz）。
    let sampleRate: Double

    /// 2π（位相の1周）。
    let twoPi: Double = 2.0 * Double.pi

    /// L/R detune の cent 値。setFrequency 時に L/R 別 phaseIncrement を再計算するため保持。
    let detuneCents: Double

    /// 定常状態の基本振幅。
    /// Task 21 で var 化: Mode 切替 (Stop 状態のみ) で `setDefaultAmplitude` から更新可能。
    /// scheduleFadeIn が次回読み取った時に最新値が target になる。
    /// audio thread が動いていない時 (engine.stop() 完了後) のみ書き換える契約。
    var defaultAmplitude: Float

    // MARK: - Audio thread 単一所有 — current pitch（glide 中に書き換わる）

    /// L チャネル用の 1 サンプル位相増分（ラジアン、**LFO 中立時**）。
    /// Task 16 から var: setFrequency による glide で audio thread がサンプル単位で
    /// `targetPhaseIncrementLeft` に向けて補間する。LFO mod は render block で別途乗算。
    var phaseIncrementLeft: Double

    /// R チャネル用の 1 サンプル位相増分（ラジアン、**LFO 中立時**）。
    var phaseIncrementRight: Double

    /// Glide target（音名切替先の phaseIncrement）。audio thread 単一所有。
    /// pending pitch command を seqlock で consume したときに pending から転記される。
    var targetPhaseIncrementLeft: Double

    /// Glide target（R チャネル）。
    var targetPhaseIncrementRight: Double

    /// Glide の残りフレーム数。> 0 の間サンプル単位で phaseIncrement を target に近づける。
    var glideFramesRemaining: Int = 0

    /// 最後に consume した `pendingPitchGeneration` の値（pitch 用 odd/even seqlock）。
    var lastConsumedPitchGeneration: Int = 0

    // MARK: - LFO（pitch vibrato）— 定数

    /// LFO 深さ（cent、±この値で pitch が揺れる）。0 なら LFO 無効。
    /// 例: 2.5cent なら 220Hz 基音時に ±0.32Hz の周期的 detune。
    let lfoDepthCents: Double

    /// LFO の 1 サンプルあたり位相増分（ラジアン）。`2π / (lfoPeriodSeconds × sampleRate)`。
    let lfoPhaseIncrement: Double

    // MARK: - Envelope LFO（全体音量ゆらぎ / 呼吸感）— 定数

    /// Envelope LFO 深さ（multiplier の振幅。0.075 なら出力が 0.925〜1.075 で揺れる）。
    /// 0 なら envelope 無効（multiplier は常に 1.0）。
    let envelopeDepth: Float

    /// Envelope LFO の 1 サンプルあたり位相増分（ラジアン）。
    /// `2π / (envelopePeriodSeconds × sampleRate)`。Sleep 用途では超低周波 30〜60 秒周期。
    let envelopePhaseIncrement: Double

    // MARK: - Audio thread 単一所有（writer/reader とも audio thread のみ）

    /// L チャネルの現在の位相（ラジアン）。
    var phaseLeft: Double = 0.0

    /// R チャネルの現在の位相（ラジアン）。
    var phaseRight: Double = 0.0

    /// LFO（pitch vibrato）の現在位相（ラジアン）。audio thread 単一所有。
    /// 1 ブロック (frameCount サンプル) 進めるたびに `lfoPhaseIncrement * frameCount` だけ加算。
    var lfoPhase: Double

    /// 基音に加算する倍音群（audio thread 単一所有）。
    /// 各要素は `HarmonicVoice` で、ratio・amplitudeFactor・L/R 位相情報を持つ。
    /// 空配列なら倍音なし（純サイン波）。
    /// 倍音は基音と同じ LFO modRatio で揺らされ、L/R detune の比率も基音の倍率に追従する
    /// （第 2 倍音の L/R 差は基音の 2 倍 = ビート周期も 1/2 になる）。
    var harmonics: [HarmonicVoice]

    /// Envelope LFO の現在位相（ラジアン）。audio thread 単一所有。
    /// ブロックごとに `envelopePhaseIncrement × frameCount` 進めて 2π 折り返し。
    /// pitch LFO とは独立、全 generator で同じ初期位相を渡せば自然に同期する。
    var envelopePhase: Double

    /// 現在の振幅（サンプル単位に補間された値）。
    var currentAmplitude: Float = 0.0

    /// 現在 active な fade の目標振幅。pending を consume した時にここへ転記される。
    var activeTargetAmplitude: Float = 0.0

    /// 現在 active な fade の残りフレーム数。render block がサンプルごとに減算する。
    var activeFadeFramesRemaining: Int = 0

    /// 最後に consume した `pendingGeneration` の値。次に `pendingGeneration` が
    /// この値と違ったら新しいコマンドがあると判断する。
    var lastConsumedGeneration: Int = 0

    // MARK: - Main writer / Audio reader（pending command, 全 atomic）

    /// 次の fade で目指す振幅（Float の bitPattern を保持）。
    /// メインスレッドの `scheduleFade*` が **relaxed store**、
    /// audio thread が新世代観測後に **relaxed load** する。
    /// gen の release/acquire により実際の値は publish される。
    let pendingTargetAmplitudeBits = ManagedAtomic<UInt32>(0)

    /// 次の fade で使う総フレーム数。`pendingTargetAmplitudeBits` と同じく
    /// relaxed store / relaxed load で、publish は `pendingGeneration` の release/acquire 任せ。
    let pendingFadeFrames = ManagedAtomic<Int>(0)

    /// fade コマンドの世代番号。メインスレッドが `scheduleFade*` の **最後** に
    /// **releasing** で increment する。audio thread は **acquiring** で load し、
    /// `lastConsumedGeneration` と違ったら新しいコマンドがあると判断する。
    let pendingGeneration = ManagedAtomic<Int>(0)

    // MARK: - Main writer / Audio reader（pitch command, 全 atomic）— Task 16

    /// 次の pitch glide target の L チャネル phaseIncrement（Double の bitPattern を保持）。
    /// fade とは独立した odd/even seqlock で publish される。
    let pendingTargetPhaseIncrementLeftBits = ManagedAtomic<UInt64>(0)

    /// 次の pitch glide target の R チャネル phaseIncrement（Double bitPattern）。
    let pendingTargetPhaseIncrementRightBits = ManagedAtomic<UInt64>(0)

    /// Glide に使うフレーム数。0 で即時切替。
    let pendingGlideFrames = ManagedAtomic<Int>(0)

    /// pitch コマンドの世代番号。fade 用の `pendingGeneration` とは別の odd/even seqlock。
    /// 同じパターン: writer は .acquiringAndReleasing で odd → payload store → .releasing で even。
    let pendingPitchGeneration = ManagedAtomic<Int>(0)

    // MARK: - Main writer / Audio reader（mute, Task 20）

    /// Mute state。0 = unmuted (multiplier target 1.0) / 1 = muted (multiplier target 0.0)。
    /// メインスレッドの `setMuted(_:)` が relaxed store、audio thread が relaxed load する。
    /// fade コマンドとは独立した別レイヤー（出力 = generator_sample × fade_amp × mute_multiplier）で、
    /// stop fade-out 中の mute toggle や、mute 中の全体 fade-in も正しく合成される。
    /// 即時切替するとクリックノイズが出るので、render block 内で固定 step の per-sample 補間で
    /// `currentMuteMultiplier` を target に向ける（ramp 約 10ms）。
    let mutedFlag = ManagedAtomic<UInt8>(0)

    // MARK: - Audio thread 単一所有 — mute multiplier

    /// 現在の mute multiplier（補間後の値、0.0〜1.0）。
    /// render block が `mutedFlag` を観測し、target = (flag==0) ? 1.0 : 0.0 に向けて
    /// 1 サンプルあたり `muteRampStepPerFrame` だけ近づける。
    /// ramp 中の方向転換（mute → ramp 中 → unmute）も自然に対応（target が変わっても
    /// 現在値からそのまま新 target に向かう）。
    var currentMuteMultiplier: Float = 1.0

    // MARK: - 定数

    /// 1 サンプルあたりの mute ramp step（0〜1 範囲を `muteRampFrames` 分割）。
    /// `1.0 / (muteRampSeconds × sampleRate)`。10ms ramp で 44.1kHz なら 1/441 ≈ 0.00227。
    let muteRampStepPerFrame: Float

    // MARK: - 初期化

    /// - Parameters:
    ///   - frequency: サイン波の中心周波数（Hz）。L/R は中心を保って `detuneCents` の半分ずつ
    ///     両側に振られる。
    ///   - sampleRate: レンダリングのサンプルレート（Hz）。
    ///   - detuneCents: L/R 間の周波数差（cent）。L=中心-detune/2、R=中心+detune/2 になる。
    ///     1 オクターブ = 1200 cent。Sleep 用途では 2 cent 程度で 220Hz 基音で約 4 秒周期の
    ///     ゆるいビートが出て「広がり感」と「ゆらぎ感」を兼ねる。0 を渡せば L=R で真 mono 互換。
    ///   - lfoPeriodSeconds: LFO（pitch vibrato）の周期（秒）。Sleep 用途では 10〜30 秒程度の
    ///     超低周波が自然。0 以下を渡せば LFO 無効（depth を 0 にしてもよい）。
    ///   - lfoDepthCents: LFO 深さ（cent、±この値で pitch が揺れる）。0 で LFO 無効。
    ///   - lfoInitialPhase: LFO の初期位相（ラジアン）。複数声で位相をずらしてゆらぎが揃わないようにする。
    ///   - harmonics: 基音に加算する倍音群。`(ratio, amplitudeFactor)` のタプル配列で、
    ///     例えば `[(2.0, 0.2), (3.0, 0.1)]` なら第 2 倍音を基音の 20%、第 3 倍音を 10% で混ぜる。
    ///     空配列なら純サイン波。各倍音の phase は 0 から開始する（基音と同位相）。
    ///   - envelopePeriodSeconds: Envelope LFO 周期（秒）。0 で envelope 無効。
    ///     Sleep 用途では 30〜60 秒の超低周波。
    ///   - envelopeDepth: Envelope LFO 深さ（multiplier の振幅）。0.075 なら出力が
    ///     0.925〜1.075 で揺れる。0 で envelope 無効。
    ///   - envelopeInitialPhase: Envelope LFO 初期位相（ラジアン）。複数 generator で
    ///     同じ値を渡せば「全体が同期して呼吸」する。
    ///   - defaultAmplitude: 定常時の基本振幅（0.0〜1.0）。既定は小音量の 0.2。
    init(
        frequency: Double,
        sampleRate: Double,
        detuneCents: Double = 2.0,
        lfoPeriodSeconds: Double = 0.0,
        lfoDepthCents: Double = 0.0,
        lfoInitialPhase: Double = 0.0,
        harmonics: [(ratio: Double, amplitudeFactor: Float)] = [],
        envelopePeriodSeconds: Double = 0.0,
        envelopeDepth: Float = 0.0,
        envelopeInitialPhase: Double = 0.0,
        defaultAmplitude: Float = 0.2
    ) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.detuneCents = detuneCents
        self.defaultAmplitude = defaultAmplitude

        // cent → 周波数比: ratio = 2^(cents/1200)
        let halfCents = detuneCents / 2.0
        let ratioLow = pow(2.0, -halfCents / 1200.0)
        let ratioHigh = pow(2.0, halfCents / 1200.0)
        self.frequencyLeft = frequency * ratioLow
        self.frequencyRight = frequency * ratioHigh

        let initialIncLeft = twoPi * frequencyLeft / sampleRate
        let initialIncRight = twoPi * frequencyRight / sampleRate
        self.phaseIncrementLeft = initialIncLeft
        self.phaseIncrementRight = initialIncRight
        // glide target は初期値として同じ値を入れる (glide=0 で即定常)
        self.targetPhaseIncrementLeft = initialIncLeft
        self.targetPhaseIncrementRight = initialIncRight

        // LFO 計算: period > 0 のとき有効、それ以外は increment=0 で実質無効化。
        self.lfoDepthCents = lfoDepthCents
        if lfoPeriodSeconds > 0 {
            self.lfoPhaseIncrement = twoPi / (lfoPeriodSeconds * sampleRate)
        } else {
            self.lfoPhaseIncrement = 0.0
        }
        self.lfoPhase = lfoInitialPhase

        // 倍音群を構築: ratio と amplitudeFactor のみ保持。
        // 倍音の L/R phaseIncrement は render block 内で「基音 phaseIncrement × ratio × lfoMod」
        // として都度計算するので、ここでは固定計算しない（Task 16 で setFrequency 時に
        // 基音 phaseIncrement が動くのに倍音も自動連動するため）。
        self.harmonics = harmonics.map { h in
            HarmonicVoice(
                ratio: h.ratio,
                amplitudeFactor: h.amplitudeFactor,
                phaseLeft: 0.0,
                phaseRight: 0.0
            )
        }

        // Envelope LFO 計算: period > 0 のとき有効、それ以外は increment=0 で実質無効化。
        self.envelopeDepth = envelopeDepth
        if envelopePeriodSeconds > 0 {
            self.envelopePhaseIncrement = twoPi / (envelopePeriodSeconds * sampleRate)
        } else {
            self.envelopePhaseIncrement = 0.0
        }
        self.envelopePhase = envelopeInitialPhase

        // Mute ramp 10ms: クリックノイズ回避できる最短時間（ASR の attack 系プラグインも同水準）。
        // 44.1kHz なら 441 sample で 0→1 / 1→0 を補間 → step = 1/441 ≈ 0.00227 / sample。
        self.muteRampStepPerFrame = Float(1.0 / (0.010 * sampleRate))
    }
}
