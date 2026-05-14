import Foundation

/// サイン波生成に必要な状態を保持するクラス。
///
/// `AudioEngineController` と `AVAudioSourceNode` の render block の両方から参照される。
/// render block はリアルタイムのオーディオスレッドで実行されるため、
/// ここではアロケーション・ロック・I/O を行わず、単純な数値の読み書きだけに留める。
///
/// - Note: `phase` は render block（オーディオスレッド）からのみ書き換える。
///   将来フェードイン / フェードアウトを実装する際は、`amplitude` を
///   render block 内でサンプル単位に補間する想定でこの構造を用意している。
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

    /// 基本振幅。安全のため小音量に固定する。
    /// マスター音量は `AVAudioEngine.mainMixerNode.outputVolume` 側で調整するため、
    /// ここはクリッピングを避けるための控えめな固定値とする。
    let amplitude: Float

    /// - Parameters:
    ///   - frequency: サイン波の周波数（Hz）。
    ///   - sampleRate: レンダリングのサンプルレート（Hz）。
    ///   - amplitude: 基本振幅（0.0〜1.0）。既定は小音量の 0.2。
    init(frequency: Double, sampleRate: Double, amplitude: Float = 0.2) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.amplitude = amplitude
        self.phaseIncrement = twoPi * frequency / sampleRate
    }
}
