import Foundation

/// サイン波生成と振幅補間（フェードイン / フェードアウト）に必要な状態を保持するクラス。
///
/// `DroneGenerator` の内部実装として使われる。`AVAudioSourceNode` の render block と
/// メインスレッド（fade スケジュール）の両方から参照される。
/// render block はリアルタイムのオーディオスレッドで実行されるため、
/// ここではアロケーション・ロック・I/O を行わず、単純な数値の読み書きだけに留める。
///
/// ## スレッドモデル（pending / active 分離）
///
/// data race を避けるため、状態を 3 つのグループに分ける:
///
/// 1. **Audio thread 単一所有**（writer も reader も audio thread のみ）
///    - `phase`, `currentAmplitude`, `activeTargetAmplitude`, `activeFadeFramesRemaining`,
///      `lastConsumedGeneration`
///    - render block 内で自由に読み書きできる。コンフリクトしない。
///
/// 2. **Main writer / Audio reader（pending command）**
///    - `pendingTargetAmplitude`, `pendingFadeFrames`, `pendingGeneration`
///    - メインスレッドの `scheduleFade*` がこれらを書く。
///    - 書き込み順序が重要: `pendingTarget` → `pendingFrames` → `pendingGeneration` の順。
///    - `pendingGeneration` は最後に書くことで「コマンドが揃ったこと」のマーカーになる。
///
/// 3. **定数**
///    - `frequency`, `sampleRate`, `phaseIncrement`, `twoPi`, `defaultAmplitude`
///
/// ## Audio thread の consume プロトコル（best-effort、厳密 atomicity は無し）
///
/// 各 render block の先頭で:
/// 1. `gen1 = pendingGeneration` を読む
/// 2. `gen1 != lastConsumedGeneration` なら新しいコマンドありと推定
/// 3. `pendingTargetAmplitude` と `pendingFadeFrames` を読む
/// 4. `gen2 = pendingGeneration` を再度読む
/// 5. `gen1 == gen2` なら「メインが書き込み中ではなさそう」と判断 → active に転記、`lastConsumedGeneration = gen1`
/// 6. `gen1 != gen2` ならメインが書き込み中 → このブロックは skip、次ブロックで再試行
///
/// ## なぜこの設計か（active 書き戻し競合の解消）
///
/// 以前は `fadeFramesRemaining` を main と audio の両方が書き換えていた。
/// main が `scheduleFadeOut` で 35280 を書いた直後に、audio が「前のブロックで進めた残り」
/// を書き戻して main の指示を消すケースがあった（Codex Task 6 レビュー High 指摘）。
///
/// この設計では:
/// - **active 変数群は audio thread の単一所有**（書き戻しの衝突なし）→ ここが本改善の核心
/// - pending 変数群は「最新の指示」を保持し、audio がブロック先頭で読む
/// - generation counter で「メインが書き込み中の中途半端な状態」を検出しようと試みる
///
/// ## 残る理論的リスク（重要：Swift memory model 上は依然 data race）
///
/// `pending*` フィールドへの cross-thread アクセスは plain class field なので、
/// Swift の memory model 上は data race のまま。具体的に残る穴:
///
/// - **store-store reordering**: Swift コンパイラ or CPU（特に ARM64）が
///   `pendingGeneration` の更新を `pendingTargetAmplitude`/`pendingFadeFrames` の書き込みより
///   先に観測可能にする可能性がある。その場合、audio が
///   `gen1 = new / target = 古い値 / frames = 古い値 / gen2 = new` を読み、
///   `gen1 == gen2` のチェックを通過して stale payload を accept する穴がある
///   （Codex データレース改善レビュー指摘）。
/// - **実用上の評価**:
///   - fade スケジュールは start / stop 押下時に発火するのみ（秒に 1 回以下）
///   - x86_64 は TSO で store-store 順序が比較的保たれるので穴は出にくい
///   - ARM64（シミュレータ・実機）では理論上ありうるが、発生したとしても
///     fade 時間が 1 サイクル分ズレる程度の聴感差にとどまる
///   - Sleep アプリの音質要件では「許容範囲のリスク」と判断
///
/// 厳密に解決するには Swift Atomics パッケージ（`swift-atomics`）の `ManagedAtomic<UInt32>` で
/// `pendingGeneration` を保護し、`Float` 値は `bitPattern` 経由で `UInt32` atomic に格納する。
/// iOS 18+ なら標準の `Synchronization.Atomic` が使える。これは別タスクとして積んでいる。
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

    // MARK: - Main writer / Audio reader（pending command）

    /// 次の fade で目指す振幅。メインスレッドが `scheduleFade*` で書く。
    /// 書き込み順序の制約: `pendingFadeFrames` より先に書くこと。
    var pendingTargetAmplitude: Float = 0.0

    /// 次の fade で使う総フレーム数。
    /// 書き込み順序の制約: `pendingTargetAmplitude` の後、`pendingGeneration` の前に書くこと。
    var pendingFadeFrames: Int = 0

    /// fade コマンドの世代番号。メインスレッドが `scheduleFade*` の **最後** にインクリメントする。
    /// この値が `lastConsumedGeneration` と違ったら、audio thread は新しいコマンドを consume する。
    var pendingGeneration: Int = 0

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
