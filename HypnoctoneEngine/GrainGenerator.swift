import AVFoundation
import Atomics
import os

/// 粒状音響（granular synthesis）を生成する。
///
/// 短い windowed サイン波の「粒（grain）」を疎にトリガし、Drone + Noise の上に高音域の
/// shimmer / sparkle を重ねる音響レイヤー。ATMÓS 的な「ぽつりぽつりと光る音」を模倣する。
/// `AudioEngineController` がこの Generator を保持し、`AVAudioEngine` に attach する。
///
/// ## 設計
/// - 1 grain = cosine bell window で囲んだ固定 pitch のサイン波（60ms 程度）
/// - L/R 独立 trigger（次 trigger までの frame 数を uniform jitter で Poisson 過程近似）
/// - 固定容量プール（既定 8）を audio thread が単一所有、in-place 更新で allocation 禁止
/// - 同時発音数は plain cap（プール満杯時の新 trigger は捨てる）
/// - pitch は trigger 時に候補リストから uniform random で選択し、生存中は固定
///
/// ## スレッドモデル
/// - 構築・fade スケジュールはメインスレッド（`@MainActor` の `AudioEngineController` から呼ばれる）
/// - render block は audio thread（realtime）または main thread（offline）で AVAudioEngine から呼ばれる
/// - render block は `GrainRenderState` の値を直接 read/write するだけで Generator 本体のメソッドは呼ばない
///
/// ## fade ロジック（odd/even seqlock）
/// `DroneGenerator` / `NoiseGenerator` と同じプロトコル。詳細は `ToneRenderState` のコメント参照。
/// fade は **grain pool 全体に掛かる外側の振幅 envelope**。fade-out 中に既に発音中の grain は
/// window で自然に減衰しつつ、外側 envelope によってさらに弱くなる。
///
/// ## Window
/// cosine bell: `window(t) = 0.5 × (1 - cos(2π × t / total))`
/// `t = 0` で window = 0、中央で 1、`t = total - 1` で window は厳密に 0 ではないが
/// `t/total` ≈ `(total-1)/total` のため最終 sample は微小値（60ms / 44.1kHz で約 7e-7）。
/// クリックノイズは聴感上問題にならない水準。
@MainActor
final class GrainGenerator {

    // MARK: - 公開状態

    /// AVAudioEngine に attach する source node。
    let sourceNode: AVAudioSourceNode

    /// この Generator の出力フォーマット（stereo / Float32）。
    /// mono を渡された場合は L/R を平均化して 1ch にダウンミックスする（後方互換）。
    let sourceFormat: AVAudioFormat

    /// 定常時の振幅（fade 完了後の外側 envelope target）。
    let defaultAmplitude: Float

    /// レンダリングのサンプルレート（Hz）。
    let sampleRate: Double

    // MARK: - 内部

    private let renderState: GrainRenderState

    private let logger = Logger(
        subsystem: "com.hypnoctone.HypnoctoneEngine",
        category: "GrainGenerator"
    )

    // MARK: - 初期化

    /// - Parameters:
    ///   - format: source node の出力フォーマット。`AudioEngineController` で共有する。
    ///   - defaultAmplitude: 外側 envelope の定常時 target（fade 完了後の振幅）。
    ///     grain 1 個あたりの最大振幅もこれに比例する。
    ///   - grainDurationSeconds: 1 grain の長さ（秒）。0.04〜0.10 が自然な粒感。
    ///   - expectedTriggersPerSecond: 1 channel あたり 1 秒間の期待 trigger 数。
    ///   - pitchFrequencies: 候補 pitch（Hz）。各 grain は trigger 時に uniform random で選ぶ。
    ///   - maxActiveGrains: 同時 active grain の最大数。プール容量。
    ///   - envelopePeriodSeconds: Envelope LFO 周期（秒）。0 で無効。Drone と揃えて同期。
    ///   - envelopeDepth: Envelope LFO 深さ。
    ///   - envelopeInitialPhase: Envelope LFO 初期位相。
    init(
        format: AVAudioFormat,
        defaultAmplitude: Float = 0.04,
        grainDurationSeconds: Double = 0.06,
        expectedTriggersPerSecond: Double = 1.0,
        pitchFrequencies: [Double] = [554.37, 659.26, 739.99, 880.00],
        maxActiveGrains: Int = 8,
        envelopePeriodSeconds: Double = 0.0,
        envelopeDepth: Float = 0.0,
        envelopeInitialPhase: Double = 0.0
    ) {
        self.sourceFormat = format
        self.sampleRate = format.sampleRate
        self.defaultAmplitude = defaultAmplitude
        self.renderState = GrainRenderState(
            sampleRate: format.sampleRate,
            defaultAmplitude: defaultAmplitude,
            grainDurationSeconds: grainDurationSeconds,
            expectedTriggersPerSecond: expectedTriggersPerSecond,
            pitchFrequencies: pitchFrequencies,
            maxActiveGrains: maxActiveGrains,
            envelopePeriodSeconds: envelopePeriodSeconds,
            envelopeDepth: envelopeDepth,
            envelopeInitialPhase: envelopeInitialPhase
        )

        // closure 内で参照するために local capture（self を捕捉しない）。
        let state = renderState

        // UInt32 → [0, 1) Float 変換係数（上位 24bit を Float に乗せる）。
        // NoiseGenerator と同じ精度配慮。
        let invFloat24: Float = 1.0 / Float(1 << 24)

        self.sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            isSilence.pointee = false

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            // ---- ブロック先頭で pending fade command を odd/even seqlock で consume ----
            // プロトコル詳細は ToneRenderState / DroneGenerator のコメントを参照。
            let g1 = state.pendingGeneration.load(ordering: .acquiring)
            if g1 & 1 == 0 && g1 != state.lastConsumedGeneration {
                let newTargetBits = state.pendingTargetAmplitudeBits.load(ordering: .relaxed)
                let newFrames = state.pendingFadeFrames.load(ordering: .relaxed)
                let g2 = state.pendingGeneration.load(ordering: .acquiring)
                if g1 == g2 {
                    state.activeTargetAmplitude = Float(bitPattern: newTargetBits)
                    state.activeFadeFramesRemaining = newFrames
                    state.lastConsumedGeneration = g1
                }
            }

            // ---- ブロック先頭で Envelope LFO multiplier を計算（呼吸感） ----
            // Drone / Noise と同じ周期/位相を渡せば自然に同期する。
            var envelopePhase = state.envelopePhase
            let envelopeMultiplier: Float
            if state.envelopeDepth != 0.0 && state.envelopePhaseIncrement != 0.0 {
                envelopeMultiplier = 1.0 + state.envelopeDepth * Float(sin(envelopePhase))
            } else {
                envelopeMultiplier = 1.0
            }

            // ---- 補間ループ ----
            var amplitude = state.currentAmplitude
            let target = state.activeTargetAmplitude
            var framesRemaining = state.activeFadeFramesRemaining

            var prngL = state.prngStateLeft
            var prngR = state.prngStateRight
            var nextTriggerL = state.framesUntilNextTriggerLeft
            var nextTriggerR = state.framesUntilNextTriggerRight

            let twoPi = state.twoPi
            let grainTotalFrames = state.grainDurationFrames
            let meanInter = state.meanInterTriggerFrames
            let pitchCount = state.pitchPhaseIncrements.count
            let poolCount = state.activeGrains.count

            let isStereo = ablPointer.count >= 2
            let bufferL = UnsafeMutableBufferPointer<Float>(ablPointer[0])
            let bufferR = isStereo ? UnsafeMutableBufferPointer<Float>(ablPointer[1]) : bufferL

            for frame in 0..<Int(frameCount) {
                // ---- fade 外側 envelope の補間 ----
                if framesRemaining > 0 {
                    let step = (target - amplitude) / Float(framesRemaining)
                    amplitude += step
                    framesRemaining -= 1
                } else {
                    amplitude = target
                }

                // ---- L channel trigger 判定 ----
                if nextTriggerL > 0 {
                    nextTriggerL -= 1
                } else {
                    // PRNG を 1 回引いて pitch / 次間隔 を決める。
                    prngL ^= prngL &<< 13
                    prngL ^= prngL &>> 17
                    prngL ^= prngL &<< 5
                    let r1 = Float(prngL &>> 8) * invFloat24  // [0, 1)
                    prngL ^= prngL &<< 13
                    prngL ^= prngL &>> 17
                    prngL ^= prngL &<< 5
                    let r2 = Float(prngL &>> 8) * invFloat24  // [0, 1)
                    // 次の trigger までを mean × (0.5 + r1) で 0.5〜1.5 倍範囲に揺らす。
                    // Poisson 過程 (指数分布 -log(r)/λ) は実装可能だが、`-log` は trigger 時のみ
                    // 1 回呼ぶだけなので realtime 負荷は問題にならない。あえて uniform 揺らぎを
                    // 採用するのは実装簡素化と「cluster (短時間に複数 trigger) を抑制して Sleep 用途で
                    // 聴感を安定させる」狙い。本物の exponential は短間隔に偏るので Sleep には不向き。
                    nextTriggerL = max(1, Int(meanInter * Double(0.5 + r1)))
                    // pitch index を選ぶ。
                    let pitchIdx = Int(r2 * Float(pitchCount)) % pitchCount
                    let phaseIncrement = state.pitchPhaseIncrements[pitchIdx]
                    // プール内の空きスロットを探して新 grain を配置（線形走査）。
                    // 満杯なら今回の trigger は捨てる（聴感的には自然な「同時発音 cap」）。
                    for slot in 0..<poolCount {
                        if state.activeGrains[slot].framesRemaining == 0 {
                            state.activeGrains[slot] = Grain(
                                phase: 0.0,
                                phaseIncrement: phaseIncrement,
                                framesRemaining: grainTotalFrames,
                                totalFrames: grainTotalFrames,
                                channel: 0
                            )
                            break
                        }
                    }
                }

                // ---- R channel trigger 判定（L と独立） ----
                if nextTriggerR > 0 {
                    nextTriggerR -= 1
                } else {
                    prngR ^= prngR &<< 13
                    prngR ^= prngR &>> 17
                    prngR ^= prngR &<< 5
                    let r1 = Float(prngR &>> 8) * invFloat24
                    prngR ^= prngR &<< 13
                    prngR ^= prngR &>> 17
                    prngR ^= prngR &<< 5
                    let r2 = Float(prngR &>> 8) * invFloat24
                    // L 側と同じ uniform 揺らぎ（cluster 抑制で Sleep 用途向け）。
                    nextTriggerR = max(1, Int(meanInter * Double(0.5 + r1)))
                    let pitchIdx = Int(r2 * Float(pitchCount)) % pitchCount
                    let phaseIncrement = state.pitchPhaseIncrements[pitchIdx]
                    for slot in 0..<poolCount {
                        if state.activeGrains[slot].framesRemaining == 0 {
                            state.activeGrains[slot] = Grain(
                                phase: 0.0,
                                phaseIncrement: phaseIncrement,
                                framesRemaining: grainTotalFrames,
                                totalFrames: grainTotalFrames,
                                channel: 1
                            )
                            break
                        }
                    }
                }

                // ---- active grain ごとに sample を合成 ----
                var sumL: Float = 0.0
                var sumR: Float = 0.0
                for slot in 0..<poolCount {
                    var g = state.activeGrains[slot]
                    if g.framesRemaining == 0 { continue }

                    // cosine bell window: t = totalFrames - framesRemaining で進行度を測る。
                    let t = Double(g.totalFrames - g.framesRemaining)
                    let windowPhase = twoPi * t / Double(g.totalFrames)
                    let window = Float(0.5 * (1.0 - cos(windowPhase)))
                    let sample = Float(sin(g.phase)) * window

                    if g.channel == 0 {
                        sumL += sample
                    } else {
                        sumR += sample
                    }

                    g.phase += g.phaseIncrement
                    if g.phase >= twoPi { g.phase -= twoPi }
                    g.framesRemaining -= 1
                    state.activeGrains[slot] = g
                }

                // 外側 envelope と LFO envelope を乗算。grain 1 個の peak が defaultAmplitude
                // になるように amplitude を掛ける。
                let outL = sumL * amplitude * envelopeMultiplier
                let outR = sumR * amplitude * envelopeMultiplier

                if isStereo {
                    bufferL[frame] = outL
                    bufferR[frame] = outR
                } else {
                    bufferL[frame] = (outL + outR) * 0.5
                }
            }

            // Envelope phase を進めて 2π 折り返し。
            envelopePhase += state.envelopePhaseIncrement * Double(frameCount)
            if envelopePhase >= twoPi {
                envelopePhase = envelopePhase.truncatingRemainder(dividingBy: twoPi)
            }

            // 更新後の state を書き戻す。
            state.currentAmplitude = amplitude
            state.activeFadeFramesRemaining = framesRemaining
            state.prngStateLeft = prngL
            state.prngStateRight = prngR
            state.framesUntilNextTriggerLeft = nextTriggerL
            state.framesUntilNextTriggerRight = nextTriggerR
            state.envelopePhase = envelopePhase
            return noErr
        }
    }

    // MARK: - フェードスケジュール（odd/even seqlock writer）

    /// fade-in をスケジュールする（外側 envelope を 0 から `defaultAmplitude` まで線形上昇）。
    /// プロトコルは `DroneGenerator.scheduleFadeIn(duration:)` と同じ。
    func scheduleFadeIn(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        renderState.pendingGeneration.wrappingIncrement(by: 1, ordering: .acquiringAndReleasing)
        renderState.pendingTargetAmplitudeBits.store(defaultAmplitude.bitPattern, ordering: .relaxed)
        renderState.pendingFadeFrames.store(frames, ordering: .relaxed)
        let newGen = renderState.pendingGeneration.wrappingIncrementThenLoad(by: 1, ordering: .releasing)
        logger.info("Grain fade-in scheduled: target=\(self.defaultAmplitude, privacy: .public) frames=\(frames) gen=\(newGen)")
    }

    /// fade-out をスケジュールする（外側 envelope を 0 まで線形下降）。
    /// 既に発音中の grain は cosine window で自然に減衰する。
    func scheduleFadeOut(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        renderState.pendingGeneration.wrappingIncrement(by: 1, ordering: .acquiringAndReleasing)
        renderState.pendingTargetAmplitudeBits.store(Float(0).bitPattern, ordering: .relaxed)
        renderState.pendingFadeFrames.store(frames, ordering: .relaxed)
        let newGen = renderState.pendingGeneration.wrappingIncrementThenLoad(by: 1, ordering: .releasing)
        logger.info("Grain fade-out scheduled: target=0 frames=\(frames) gen=\(newGen)")
    }

    // MARK: - 状態参照

    /// 「鳴らす意図があるか」。fade target が 0 より大きいなら audible。
    var hasAudibleTarget: Bool {
        let bits = renderState.pendingTargetAmplitudeBits.load(ordering: .relaxed)
        return Float(bitPattern: bits) > 0.0
    }
}
