import Foundation
import Atomics

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

    /// L チャネル用の 1 サンプル位相増分（ラジアン）。**LFO 中立時の基準値**。
    /// LFO 有効時、render block 先頭で `phaseIncrementLeft * lfoModRatio` を計算して
    /// そのブロック内のサンプル進行に使う。
    let phaseIncrementLeft: Double

    /// R チャネル用の 1 サンプル位相増分（ラジアン）。**LFO 中立時の基準値**。
    let phaseIncrementRight: Double

    /// 定常状態の基本振幅。
    let defaultAmplitude: Float

    // MARK: - LFO（pitch vibrato）— 定数

    /// LFO 深さ（cent、±この値で pitch が揺れる）。0 なら LFO 無効。
    /// 例: 2.5cent なら 220Hz 基音時に ±0.32Hz の周期的 detune。
    let lfoDepthCents: Double

    /// LFO の 1 サンプルあたり位相増分（ラジアン）。`2π / (lfoPeriodSeconds × sampleRate)`。
    let lfoPhaseIncrement: Double

    // MARK: - Audio thread 単一所有（writer/reader とも audio thread のみ）

    /// L チャネルの現在の位相（ラジアン）。
    var phaseLeft: Double = 0.0

    /// R チャネルの現在の位相（ラジアン）。
    var phaseRight: Double = 0.0

    /// LFO（pitch vibrato）の現在位相（ラジアン）。audio thread 単一所有。
    /// 1 ブロック (frameCount サンプル) 進めるたびに `lfoPhaseIncrement * frameCount` だけ加算。
    var lfoPhase: Double

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
    ///   - defaultAmplitude: 定常時の基本振幅（0.0〜1.0）。既定は小音量の 0.2。
    init(
        frequency: Double,
        sampleRate: Double,
        detuneCents: Double = 2.0,
        lfoPeriodSeconds: Double = 0.0,
        lfoDepthCents: Double = 0.0,
        lfoInitialPhase: Double = 0.0,
        defaultAmplitude: Float = 0.2
    ) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.defaultAmplitude = defaultAmplitude

        // cent → 周波数比: ratio = 2^(cents/1200)
        let halfCents = detuneCents / 2.0
        let ratioLow = pow(2.0, -halfCents / 1200.0)
        let ratioHigh = pow(2.0, halfCents / 1200.0)
        self.frequencyLeft = frequency * ratioLow
        self.frequencyRight = frequency * ratioHigh

        self.phaseIncrementLeft = twoPi * frequencyLeft / sampleRate
        self.phaseIncrementRight = twoPi * frequencyRight / sampleRate

        // LFO 計算: period > 0 のとき有効、それ以外は increment=0 で実質無効化。
        self.lfoDepthCents = lfoDepthCents
        if lfoPeriodSeconds > 0 {
            self.lfoPhaseIncrement = twoPi / (lfoPeriodSeconds * sampleRate)
        } else {
            self.lfoPhaseIncrement = 0.0
        }
        self.lfoPhase = lfoInitialPhase
    }
}
