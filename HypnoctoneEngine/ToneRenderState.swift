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

    /// 生成するサイン波の周波数（Hz）。
    let frequency: Double

    /// レンダリングに使うサンプルレート（Hz）。
    let sampleRate: Double

    /// 2π（位相の1周）。
    let twoPi: Double = 2.0 * Double.pi

    /// 1サンプルあたりの位相増分（ラジアン）。
    let phaseIncrement: Double

    /// 定常状態の基本振幅。
    let defaultAmplitude: Float

    // MARK: - Audio thread 単一所有（writer/reader とも audio thread のみ）

    /// 現在の位相（ラジアン）。
    var phase: Double = 0.0

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
    ///   - frequency: サイン波の周波数（Hz）。
    ///   - sampleRate: レンダリングのサンプルレート（Hz）。
    ///   - defaultAmplitude: 定常時の基本振幅（0.0〜1.0）。既定は小音量の 0.2。
    init(frequency: Double, sampleRate: Double, defaultAmplitude: Float = 0.2) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.defaultAmplitude = defaultAmplitude
        self.phaseIncrement = twoPi * frequency / sampleRate
    }
}
