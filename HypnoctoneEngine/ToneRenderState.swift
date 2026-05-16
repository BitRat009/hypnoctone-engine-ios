import Foundation

/// サイン波生成と振幅補間（フェードイン / フェードアウト）に必要な状態を保持するクラス。
///
/// `AudioEngineController` と `AVAudioSourceNode` の render block の両方から参照される。
/// render block はリアルタイムのオーディオスレッドで実行されるため、
/// ここではアロケーション・ロック・I/O を行わず、単純な数値の読み書きだけに留める。
///
/// ## スレッドモデル
///
/// - `phase` / `currentAmplitude` / `fadeFramesRemaining` は **オーディオスレッドからのみ書き換える**。
/// - `targetAmplitude` / `fadeFramesRemaining` は **メインスレッドが書き、オーディオスレッドが読み書きする**
///   （後者は audio thread が減算で更新もする現状実装。Task 6 レビュー時の Codex 指摘により、将来的には
///   pending/active 分離 + 単一 writer 化が望ましいと判断されている）。
///
/// メインスレッドは render block 内の状態（`currentAmplitude` 等）を読まない設計に寄せている
/// （Codex レビュー指摘 3 への対応）。fade スケジュールはメインスレッドが「目標振幅」と
/// 「そこへ到達するまでのフレーム数」だけを通知し、サンプル単位の補間は render thread が自前で計算する。
///
/// Swift には iOS 16 で使える組み込みの `Atomic<Float>` / `Atomic<Int>` が無い。
/// ARM64 / x86_64 では aligned な 32/64bit プリミティブの load/store は実質的に atomic（単一命令）で、
/// フェードのように人間の聴覚で許容される範囲の更新では tearing による聴感上の不具合は発生しない。
/// 厳密な atomic が必要になったら Swift Atomics パッケージ導入 or
/// iOS 18+ の `Synchronization.Atomic` に切り替える。
final class ToneRenderState {
    /// 生成するサイン波の周波数（Hz）。
    let frequency: Double

    /// レンダリングに使うサンプルレート（Hz）。
    let sampleRate: Double

    /// 2π（位相の1周）。render block 内で再計算しないよう事前に保持する。
    let twoPi: Double = 2.0 * Double.pi

    /// 1サンプルあたりの位相増分（ラジアン）。
    let phaseIncrement: Double

    /// 現在の位相（ラジアン）。オーディオスレッドからのみ更新する。
    var phase: Double = 0.0

    /// 現在の振幅（オーディオスレッドが各サンプルで補間して書き換える）。
    var currentAmplitude: Float = 0.0

    /// フェード残りフレーム数。
    /// メインスレッドが `scheduleFade*` で書き、オーディオスレッドが render block 内で減算する。
    /// 0 になったら補間を止めて `targetAmplitude` に張り付く。
    var fadeFramesRemaining: Int = 0

    /// フェードの目標振幅。メインスレッドが書き、オーディオスレッドが読む。
    var targetAmplitude: Float = 0.0

    /// 定常状態（フェード完了後）に到達する基本振幅。
    /// 安全のため小音量に固定。マスター音量は `mainMixerNode.outputVolume` で調整する。
    let defaultAmplitude: Float

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
