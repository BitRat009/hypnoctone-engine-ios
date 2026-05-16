import AVFoundation
import Atomics
import os

/// Sleep モード基底音となる Drone（持続音）を生成する。
///
/// L/R で `detuneCents` だけ周波数をずらした stereo サイン波（+ 任意の倍音）を出力する。
/// detune によるゆるいビート（基音 220Hz / detune 2cent で約 4 秒周期）が
/// 「広がり感」を、`lfoDepthCents` > 0 のときは LFO（pitch vibrato）が
/// 周期数十秒の超低周波で「揺らぎ感」を、`harmonics` が空でない場合は倍音が
/// 「楽器的な温かみ」を、`envelopeDepth` > 0 のときは超低周波（30〜60s）の
/// envelope LFO が全体音量を呼吸させて「呼吸感」を与え、Sleep 用途で疲れない音場を作る。
/// `AudioEngineController` がこの Generator を保持し、`AVAudioEngine` に attach する。
///
/// ## スレッドモデル
/// - 構築・fade スケジュールはメインスレッド（`@MainActor` の `AudioEngineController` から呼ばれる）
/// - render block は audio thread（realtime）または main thread（offline）で AVAudioEngine から呼ばれる
/// - render block は `ToneRenderState` の値を直接 read/write するだけで、Generator 本体のメソッドは呼ばない
///
/// ## fade ロジック（odd/even seqlock）
/// `scheduleFadeIn(duration:)` / `scheduleFadeOut(duration:)` でメインスレッドが
/// **pending 領域** に新しい fade コマンドを書く。
///   1. gen を **.acquiringAndReleasing** increment（odd: 書き込み中マーカー、後続 store の前倒しを防ぐ）
///   2. target / frames を relaxed store
///   3. gen を **.releasing** increment（even: 公開済みマーカー、payload の publish）
/// render block はブロック先頭で `pendingGeneration` を 2 回 acquiring load し、
/// g1 が even かつ g1 == g2 かつ `lastConsumedGeneration` と異なるときだけ
/// target/frames を relaxed load して **active 領域** に転記する。
/// 実際の補間は active 領域に対して行う。詳細は `ToneRenderState` のコメント参照。
@MainActor
final class DroneGenerator {

    // MARK: - 公開状態

    /// AVAudioEngine に attach する source node。
    let sourceNode: AVAudioSourceNode

    /// この Generator の出力フォーマット（stereo / Float32）。
    /// mono を渡された場合は L/R を平均化して 1ch にダウンミックスして出力する（後方互換）。
    let sourceFormat: AVAudioFormat

    /// 定常時の振幅（フェード完了後の目標値）。
    let defaultAmplitude: Float

    /// レンダリングのサンプルレート（Hz）。fade 持続時間からフレーム数を計算する側で参照する。
    let sampleRate: Double

    // MARK: - 内部

    private let renderState: ToneRenderState

    private let logger = Logger(
        subsystem: "com.hypnoctone.HypnoctoneEngine",
        category: "DroneGenerator"
    )

    // MARK: - 初期化

    /// - Parameters:
    ///   - format: source node の出力フォーマット。`AudioEngineController` 側で一度
    ///             生成済みのものを共有する（manual rendering でも同じ format を使う）。
    ///             stereo (2ch) を想定するが mono (1ch) でも動く（mono の場合 L/R を平均化）。
    ///   - frequency: 生成するサイン波の中心周波数（Hz）。既定は 220Hz (A3)。
    ///                Sleep モード方針として 440Hz より低めの落ち着いた音域を採用。
    ///   - detuneCents: L/R 間の周波数差（cent）。既定 2.0。0 で真 mono 互換。
    ///   - lfoPeriodSeconds: LFO（pitch vibrato）の周期（秒）。0 で無効。Sleep 用途では 10〜30 秒。
    ///   - lfoDepthCents: LFO 深さ（cent）。0 で無効。detune と同等の ±数 cent が自然。
    ///   - lfoInitialPhase: LFO 初期位相（ラジアン）。複数声で位相をずらすと揺れが揃わない。
    ///   - harmonics: 基音に加算する倍音群。例えば `[(2.0, 0.2), (3.0, 0.1)]` で
    ///     第 2 倍音 (基音の 20%) と第 3 倍音 (10%) を混ぜる。空配列で純サイン波。
    ///   - envelopePeriodSeconds: Envelope LFO 周期（秒）。0 で無効。Sleep 用途では 30〜60 秒。
    ///   - envelopeDepth: Envelope LFO 深さ。0.075 で出力 0.925〜1.075 範囲。0 で無効。
    ///   - envelopeInitialPhase: Envelope LFO 初期位相。複数 generator で揃えると同期呼吸。
    ///   - defaultAmplitude: 定常時の振幅（0.0〜1.0）。既定は小音量の 0.2。
    init(
        format: AVAudioFormat,
        frequency: Double = 220.0,
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
        self.sourceFormat = format
        self.sampleRate = format.sampleRate
        self.defaultAmplitude = defaultAmplitude
        self.renderState = ToneRenderState(
            frequency: frequency,
            sampleRate: format.sampleRate,
            detuneCents: detuneCents,
            lfoPeriodSeconds: lfoPeriodSeconds,
            lfoDepthCents: lfoDepthCents,
            lfoInitialPhase: lfoInitialPhase,
            harmonics: harmonics,
            envelopePeriodSeconds: envelopePeriodSeconds,
            envelopeDepth: envelopeDepth,
            envelopeInitialPhase: envelopeInitialPhase,
            defaultAmplitude: defaultAmplitude
        )

        // closure 内で参照するために local capture（self を捕捉しない）。
        let state = renderState

        self.sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            isSilence.pointee = false

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            // ---- ブロック先頭で pending command を odd/even seqlock で consume ----
            //
            // writer は payload 書き込み前に gen を odd（書き込み中）、書き込み完了後に
            // even（公開済み）にする。reader は g1 が odd なら skip、even なら payload を
            // 読んで g2 と比較し、g1 == g2 で commit する。
            //
            // 単純な pre/post acquire-load だけだと「writer が target/frames を書き終え、
            // まだ gen を increment していない窓」で reader が新 payload を旧 gen 名義で
            // commit する穴が残る（Codex Task 7 レビュー 2 回目 High 指摘）。
            // odd/even seqlock は「writer が書き込み中である」状態を gen 自体に乗せることで
            // この穴を塞ぐ。
            //
            // 手順:
            //   1. g1 = gen.load(.acquiring)
            //   2. g1 が odd → writer 書き込み中 → skip
            //   3. g1 == lastConsumed → 新コマンド無し → skip
            //   4. target / frames を relaxed load
            //   5. g2 = gen.load(.acquiring)
            //   6. g1 == g2（かつ g1 even）→ 「読み中に writer が割り込まなかった」と確定 → commit
            //   7. g1 != g2 → writer が mid-read で割り込んだ → skip（次ブロックで retry）
            //
            // release/acquire により g1 / g2 の publish 順序が保証され、relaxed load の
            // target/frames は g1/g2 の acquire fence 内側で読まれるので happens-before で
            // 整合する payload を観測できる。target/frames 自体も atomic なので torn read は無い。
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
                // g1 != g2 の場合: writer が mid-read で割り込んだ。
                // active 据え置きで次ブロックの retry に任せる。
            }
            // g1 が odd の場合: writer が今まさに書き込み中。
            // active 据え置きで次ブロックの retry に任せる。

            // ---- pending pitch command を odd/even seqlock で consume (Task 16) ----
            //
            // fade と同じ atomic seqlock パターンで、setFrequency() が main thread から
            // publish した「新しい target phaseIncrement (L/R) + glide frames」を取り込む。
            // fade 用 seqlock とは独立した pendingPitchGeneration を使うので相互干渉なし。
            let p1 = state.pendingPitchGeneration.load(ordering: .acquiring)
            if p1 & 1 == 0 && p1 != state.lastConsumedPitchGeneration {
                let newTargetIncLBits = state.pendingTargetPhaseIncrementLeftBits.load(ordering: .relaxed)
                let newTargetIncRBits = state.pendingTargetPhaseIncrementRightBits.load(ordering: .relaxed)
                let newGlideFrames = state.pendingGlideFrames.load(ordering: .relaxed)
                let p2 = state.pendingPitchGeneration.load(ordering: .acquiring)
                if p1 == p2 {
                    state.targetPhaseIncrementLeft = Double(bitPattern: newTargetIncLBits)
                    state.targetPhaseIncrementRight = Double(bitPattern: newTargetIncRBits)
                    state.glideFramesRemaining = newGlideFrames
                    state.lastConsumedPitchGeneration = p1
                    // glide=0 (即時切替) のときは current を即 target に揃える。
                    if newGlideFrames == 0 {
                        state.phaseIncrementLeft = state.targetPhaseIncrementLeft
                        state.phaseIncrementRight = state.targetPhaseIncrementRight
                    }
                }
            }

            // ---- LFO （pitch vibrato）modRatio をブロック先頭で 1 回計算 ----
            //
            // 1 サンプル単位で sin/pow を呼ぶと audio thread 負荷が上がるので、
            // 「LFO は超低周波 (周期 10〜30s) で 5ms ブロック内では変化が無視できる」前提で
            // ブロック先頭で 1 回だけ modRatio を算出し、ブロック内は固定値として使う。
            // 周期 10s / 44.1kHz / frameCount=256 だと 1 ブロックあたり LFO 位相は約 2π/1722
            //  ≈ 0.0036 rad しか進まないので、ブロック内の cent 誤差は深さ 2.5cent でも
            //  最大 0.009cent (約 0.00002Hz @220Hz) で実用上完全に無視できる。
            //
            // depth=0 のときは modRatio=1.0 で実質 LFO 無効。
            var lfoPhase = state.lfoPhase
            let lfoMod: Double
            if state.lfoDepthCents != 0.0 {
                let lfoSample = sin(lfoPhase)
                let modCents = lfoSample * state.lfoDepthCents
                lfoMod = pow(2.0, modCents / 1200.0)
            } else {
                lfoMod = 1.0
            }

            // ---- ブロック先頭で Envelope LFO multiplier を計算（呼吸感） ----
            //
            // 出力全体を multiplier 1 ± depth の範囲でゆっくり呼吸させる。
            // pitch LFO とは独立、超低周波（30〜60s 周期）。
            // depth=0 または phaseIncrement=0（period<=0）のときは multiplier=1.0 で実質無効。
            // 両方チェックすることで「period=0 + depth>0 + initialPhase≠0」のような中途半端な
            // 設定が「固定ゲイン」として残らないようにする。
            var envelopePhase = state.envelopePhase
            let envelopeMultiplier: Float
            if state.envelopeDepth != 0.0 && state.envelopePhaseIncrement != 0.0 {
                envelopeMultiplier = 1.0 + state.envelopeDepth * Float(sin(envelopePhase))
            } else {
                envelopeMultiplier = 1.0
            }

            // ---- 補間ループ（active 状態を audio thread が単一所有） ----
            //
            // 基準 phaseIncrement (L/R) を glide で target に向けて per-sample 線形補間する。
            // LFO modRatio は補間後の値に乗算してブロック内で使う。
            // 倍音 phaseIncrement は「基音 (glide 後) × ratio × lfoMod」で都度計算 (Task 16)。
            // phase（位相）自体は連続なので、phaseIncrement が変わってもクリックノイズは出ない。
            let twoPi = state.twoPi
            var phaseIncBaseL = state.phaseIncrementLeft
            var phaseIncBaseR = state.phaseIncrementRight
            let targetIncL = state.targetPhaseIncrementLeft
            let targetIncR = state.targetPhaseIncrementRight
            var glideFrames = state.glideFramesRemaining
            var phaseLeft = state.phaseLeft
            var phaseRight = state.phaseRight
            var amplitude = state.currentAmplitude
            let target = state.activeTargetAmplitude
            var framesRemaining = state.activeFadeFramesRemaining

            // stereo: 2 buffer (L=0, R=1) / mono fallback: 1 buffer に (L+R)/2 を書く。
            let isStereo = ablPointer.count >= 2
            let bufferL = UnsafeMutableBufferPointer<Float>(ablPointer[0])
            let bufferR = isStereo ? UnsafeMutableBufferPointer<Float>(ablPointer[1]) : bufferL

            // 倍音数（ブロック内で配列の count が変わらないことを利用）。
            let harmonicsCount = state.harmonics.count

            for frame in 0..<Int(frameCount) {
                // フェード残りがあれば 1 サンプル分だけ target に近づける。
                if framesRemaining > 0 {
                    let step = (target - amplitude) / Float(framesRemaining)
                    amplitude += step
                    framesRemaining -= 1
                } else {
                    amplitude = target
                }

                // Pitch glide: 基音 phaseIncrement を target に向けて 1 サンプル分近づける。
                if glideFrames > 0 {
                    let stepL = (targetIncL - phaseIncBaseL) / Double(glideFrames)
                    let stepR = (targetIncR - phaseIncBaseR) / Double(glideFrames)
                    phaseIncBaseL += stepL
                    phaseIncBaseR += stepR
                    glideFrames -= 1
                } else {
                    phaseIncBaseL = targetIncL
                    phaseIncBaseR = targetIncR
                }
                let phaseIncrementLeft = phaseIncBaseL * lfoMod
                let phaseIncrementRight = phaseIncBaseR * lfoMod

                // 基音サイン波を生成。
                var sampleL = Float(sin(phaseLeft)) * amplitude
                var sampleR = Float(sin(phaseRight)) * amplitude

                phaseLeft += phaseIncrementLeft
                if phaseLeft >= twoPi { phaseLeft -= twoPi }
                phaseRight += phaseIncrementRight
                if phaseRight >= twoPi { phaseRight -= twoPi }

                // 倍音を加算合成: phaseIncrement は基音 (glide 後) × ratio × lfoMod。
                // 基音 phaseIncrement に追従するので、glide で基音が動くと倍音も自動連動する。
                for i in 0..<harmonicsCount {
                    var h = state.harmonics[i]
                    let hIncL = phaseIncrementLeft * h.ratio
                    let hIncR = phaseIncrementRight * h.ratio
                    let hAmp = amplitude * h.amplitudeFactor

                    sampleL += Float(sin(h.phaseLeft)) * hAmp
                    sampleR += Float(sin(h.phaseRight)) * hAmp

                    h.phaseLeft += hIncL
                    if h.phaseLeft >= twoPi { h.phaseLeft -= twoPi }
                    h.phaseRight += hIncR
                    if h.phaseRight >= twoPi { h.phaseRight -= twoPi }

                    state.harmonics[i] = h
                }

                // Envelope multiplier をブロック単位で全出力に乗算（呼吸感）。
                // ブロック単位で十分（envelope は超低周波で 5.8ms 内の変化は無視できる）。
                let outL = sampleL * envelopeMultiplier
                let outR = sampleR * envelopeMultiplier

                if isStereo {
                    bufferL[frame] = outL
                    bufferR[frame] = outR
                } else {
                    bufferL[frame] = (outL + outR) * 0.5
                }
            }

            // LFO phase をブロック分（frameCount サンプル）進めて折り返す。
            // depth=0 のときも phase は進めるが、影響は無い（modRatio=1.0 で済むため）。
            lfoPhase += state.lfoPhaseIncrement * Double(frameCount)
            // 2π を大きく超える前に折り返す（数値精度の劣化防止）。
            if lfoPhase >= twoPi {
                lfoPhase = lfoPhase.truncatingRemainder(dividingBy: twoPi)
            }

            // Envelope phase も同様にブロック単位で進めて折り返す。
            envelopePhase += state.envelopePhaseIncrement * Double(frameCount)
            if envelopePhase >= twoPi {
                envelopePhase = envelopePhase.truncatingRemainder(dividingBy: twoPi)
            }

            state.phaseLeft = phaseLeft
            state.phaseRight = phaseRight
            state.phaseIncrementLeft = phaseIncBaseL
            state.phaseIncrementRight = phaseIncBaseR
            state.glideFramesRemaining = glideFrames
            state.currentAmplitude = amplitude
            state.activeFadeFramesRemaining = framesRemaining
            state.lfoPhase = lfoPhase
            state.envelopePhase = envelopePhase
            return noErr
        }
    }

    // MARK: - フェードスケジュール（odd/even seqlock writer）

    /// fade-in をスケジュールする（現在の振幅から `defaultAmplitude` まで線形上昇）。
    ///
    /// odd/even seqlock writer プロトコル:
    ///   1. gen を **.acquiringAndReleasing** increment → odd（書き込み中マーカー）
    ///   2. target / frames を relaxed store
    ///   3. gen を **.releasing** increment → even（公開済みマーカー）
    ///
    /// reader（render block）は gen が odd の間は skip、even を見て g1 == g2 のときだけ
    /// commit する（`DroneGenerator` 初期化時の sourceNode closure 内コメント参照）。
    /// - Parameter duration: 補間に使う秒数。フレーム数は内部で `sampleRate * duration` から計算。
    func scheduleFadeIn(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        // 1) writer 開始マーク（gen を odd に）。
        //    .acquiringAndReleasing で後続 payload store が odd marker より前に出ないようにする
        //    （.releasing だけだと「以前の操作」しか release できず、後続 store の前倒しを防げない）。
        renderState.pendingGeneration.wrappingIncrement(by: 1, ordering: .acquiringAndReleasing)
        // 2) payload 書き込み。
        renderState.pendingTargetAmplitudeBits.store(defaultAmplitude.bitPattern, ordering: .relaxed)
        renderState.pendingFadeFrames.store(frames, ordering: .relaxed)
        // 3) writer 完了マーク（gen を even に）。これで reader が payload を取りに来る。
        let newGen = renderState.pendingGeneration.wrappingIncrementThenLoad(by: 1, ordering: .releasing)
        logger.info("Drone fade-in scheduled: target=\(self.defaultAmplitude, privacy: .public) frames=\(frames) gen=\(newGen)")
    }

    /// fade-out をスケジュールする（現在の振幅から 0 まで線形下降）。
    /// プロトコルは `scheduleFadeIn(duration:)` と同じ odd/even seqlock writer。
    /// - Parameter duration: 補間に使う秒数。
    func scheduleFadeOut(duration: TimeInterval) {
        let frames = max(1, Int(sampleRate * duration))
        // begin marker（odd）は .acquiringAndReleasing で後続 payload store の前倒しを防ぐ。
        renderState.pendingGeneration.wrappingIncrement(by: 1, ordering: .acquiringAndReleasing)
        renderState.pendingTargetAmplitudeBits.store(Float(0).bitPattern, ordering: .relaxed)
        renderState.pendingFadeFrames.store(frames, ordering: .relaxed)
        // end marker（even）は .releasing。これで reader が payload を取りに来る。
        let newGen = renderState.pendingGeneration.wrappingIncrementThenLoad(by: 1, ordering: .releasing)
        logger.info("Drone fade-out scheduled: target=0 frames=\(frames) gen=\(newGen)")
    }

    // MARK: - Pitch glide スケジュール（Task 16, odd/even seqlock writer）

    /// 基音周波数を変更し、`glideSeconds` 秒かけて新 frequency に線形補間する。
    /// 倍音 phaseIncrement は render block 内で「新基音 phaseIncrement × ratio」として
    /// 自動連動するため、ここで個別に更新する必要は無い。L/R は init で受けた `detuneCents`
    /// に基づいて再計算され、左右の detune 関係は維持される。
    ///
    /// プロトコル: pitch 用 odd/even seqlock（fade 用とは独立した別 generation）。
    ///   1. pendingPitchGeneration を **.acquiringAndReleasing** で odd に
    ///   2. target phaseIncrement L/R + glide frames を relaxed store
    ///   3. pendingPitchGeneration を **.releasing** で even に → audio thread が consume
    ///
    /// - Parameters:
    ///   - frequency: 新しい基音周波数 (Hz, 中心)。L/R は detune の半幅ずつ両側に振られる。
    ///   - glideSeconds: 線形補間時間 (秒)。0 で即時切替（クリック回避は phase 連続維持で OK）。
    func setFrequency(_ frequency: Double, glideSeconds: TimeInterval = 3.0) {
        // L/R 別 phaseIncrement を再計算（detune は init 時の値を保持）。
        let halfCents = renderState.detuneCents / 2.0
        let ratioLow = pow(2.0, -halfCents / 1200.0)
        let ratioHigh = pow(2.0, halfCents / 1200.0)
        let freqL = frequency * ratioLow
        let freqR = frequency * ratioHigh
        let targetIncL = renderState.twoPi * freqL / sampleRate
        let targetIncR = renderState.twoPi * freqR / sampleRate
        let glideFrames = max(0, Int(sampleRate * glideSeconds))

        // 1) writer 開始マーク (odd)
        renderState.pendingPitchGeneration.wrappingIncrement(by: 1, ordering: .acquiringAndReleasing)
        // 2) payload 書き込み (Double → UInt64 bitPattern)
        renderState.pendingTargetPhaseIncrementLeftBits.store(targetIncL.bitPattern, ordering: .relaxed)
        renderState.pendingTargetPhaseIncrementRightBits.store(targetIncR.bitPattern, ordering: .relaxed)
        renderState.pendingGlideFrames.store(glideFrames, ordering: .relaxed)
        // 3) writer 完了マーク (even)
        let newGen = renderState.pendingPitchGeneration.wrappingIncrementThenLoad(by: 1, ordering: .releasing)
        logger.info("Drone pitch set: \(frequency, privacy: .public)Hz glide=\(glideSeconds, privacy: .public)s gen=\(newGen)")
    }

    // MARK: - 状態参照

    /// 「鳴らす意図があるか」。最新の schedule が指示した target を見る
    /// （audio thread の補間進行とは独立に「ユーザー意図」を表す）。
    /// `AudioEngineController` が fade-out 中に再 start が走ったかを検知する用途で使う。
    var hasAudibleTarget: Bool {
        let bits = renderState.pendingTargetAmplitudeBits.load(ordering: .relaxed)
        return Float(bitPattern: bits) > 0.0
    }
}
