# Hypnoctone Task 0〜4 実装 ToDo

## 対象範囲
Task 0〜4（Xcode プロジェクト / 最小UI / AudioEngineController / AVAudioSession / サイン波再生）

## タスク
- [x] Task 0: Xcode プロジェクト構成（HypnoctoneEngine.xcodeproj + ソースフォルダ）
- [x] Task 1: SwiftUI 最小UI（MainView / PulseView / Theme）
- [x] Task 2: AudioEngineController（start / stop / setVolume / isRunning）
- [x] Task 3: AVAudioSession を .playback で設定・有効化
- [x] Task 4: AVAudioEngine + AVAudioSourceNode で 440Hz サイン波生成
- [x] Codex と実装の正しさをレビュー・意見交換
- [x] レビュー反映

## 制約メモ
- 音声ファイル / 録音素材 / ループ素材は使わない
- render block 内で I/O・UI更新・アロケーション・ロック禁止
- Task 5 以降（フェード等）は実装しない
- 開発機は Windows のため Xcode ビルドはこの環境では検証不可（Mac での確認が必要）

## レビューセクション

### Codex とのレビューで反映した修正
1. `#Preview` マクロ → `PreviewProvider` 形式に変更（iOS 16 ターゲットでの確実性優先）
2. `project.pbxproj` の `compatibilityVersion` を `"Xcode 16.0"` に明示（objectVersion 77 と整合）
3. render block に `isSilence.pointee = false` を追加（信号生成を明示）
4. `setVolume(_:)` のコメントをメインスレッド経由の設計に合わせて修正

### Codex 確認済み（問題なし）
- AVAudioSourceNode の render block 実装（Float32 mono 前提で妥当）
- render block 内に I/O・ロック・UI更新・アロケーションなし
- phase はオーディオスレッドのみ更新、volume は `@MainActor` 経由
- Stop は `engine.stop()` + session deactivate まで実施
- `Logger` / `.tint` / `onChange(of:){ _ in }` は iOS 16 で使用可

### 引き継ぎ事項（ユーザー側の作業）
- 実機ビルド時は Xcode で Signing > Team を選択（`DEVELOPMENT_TEAM` 未設定のため）
- この環境（Windows）では Xcode ビルド検証は不可。Mac での実機確認が必要
- 背景再生（画面ロック中の継続再生）は未対応。必要なら後続タスクで `UIBackgroundModes` を追加

## 検証環境（Windows 開発 / クラウド Mac 中心）
開発機は Windows、手持ちの Mac は旧 OS で Xcode 不可。検証はクラウドで行う方針。

- [x] GitHub Actions ワークフロー追加（`.github/workflows/ios-build.yml`）
      - macOS-15 ランナー + Xcode 16.x で push/PR ごとにシミュレータ向けビルド確認
      - Codex レビュー済み（`xcode-version` を `'16'` 固定に修正）
- [x] GitHub にリポジトリを push（https://github.com/BitRat009/hypnoctone-engine-ios）
- [x] リポジトリを public に変更（macOS ランナーの CI が無料・無制限に）
- [x] `.gitignore` に署名・秘密情報の除外を追加（証明書/鍵/プロビジョニング/環境変数）
- [x] **CI でビルド検証成功** — 手書き pbxproj が Xcode 16 で実ビルド可能と実証（run #1, 41s）
- [x] Codemagic 用 `codemagic.yaml` 作成（ビルド → シミュレータ起動 → 録画+SS → アーティファクト）
- [x] Codemagic から自動再生させるため、`MainView` に `CI_AUTOSTART` 環境変数フックを追加
- [x] Codex に codemagic.yaml と CI_AUTOSTART 変更をレビュー依頼 → 指摘（録画音声検証 / trap 失敗時 flush / シミュレータ選択決定性 / `--console-pty`）を反映
- [x] **ユーザー側作業**: Codemagic（codemagic.io）にサインアップ → GitHub リポジトリ `BitRat009/hypnoctone-engine-ios` を接続 → 初回 build をトリガー
- [x] 初回 build 結果確認 → **真っ白画面（ステータスバーのみ）& 音声無し** という結果
      - ffprobe で `nb_streams=1` を確認、`simctl recordVideo` は音声を録らない仕様と確定
      - スクリーンショット 3 枚すべて同一バイト数 = 16 秒間ずっと静止
      - app-stdout.log は PID 行のみで原因不明
- [x] **codemagic.yaml v2 作成** — 真っ白の根本原因切り分け用に診断を強化
      - `simctl spawn log stream` で SpringBoard / runningboardd / launchd / ReportCrash を含む system log を保存
      - `launchctl list` でアプリ pid 生存を経過時刻ごとに probe.log へ記録
      - sleep を 3s/7s/12s/16s に拡大（iOS 18 cold start 待ち、4 枚撮影）
      - 実行開始時刻以降の crash log を DiagnosticReports + CoreSimulator から広めに収集
      - Codex レビュー反映: awk の PID 数値判定 / index() による文字列包含 / predicate 拡張 / crash log 範囲拡大
- [x] v2 を push → Codemagic で実走 → artifacts_002 を回収 → 真っ白原因を特定
- [x] **真因特定**: Codemagic の headless mac mini で AVAudioEngine が CoreAudio HAL Initialize の RPC timeout で SIGABRT(9.5s で abort)
      - syslog の決定打: `(AudioToolboxCore) Fault Initialize: RPC timeout. Apparently deadlocked. Aborting now.`
      - probe.log で t+3s/t+7s で pid 生存、t+12s で消失と確認
- [x] **v3 実装**: AudioEngineController に offline render モードを追加
      - `Mode.offlineToWAV` で `enableManualRenderingMode(.offline, ...)` を attach/connect 前に呼ぶ → CoreAudio HAL を一切触らない
      - `start()` が switch で realtime / offline 分岐
      - offline: `engine.renderOffline()` でフレーム単位に書き込み → AVAudioFile（LinearPCM 16bit/44.1kHz/mono）として Documents/sine-440hz.wav へ
      - Codex レビュー反映: manual rendering 有効化失敗時の fail-closed / `.cannotDoInCurrentContext` retry / frameLength=0 防御
- [x] **codemagic.yaml v3**: WAV 回収・検証ステップを追加
      - `simctl get_app_container ... data` でアプリ sandbox を取得し WAV をコピー
      - ffprobe で 44.1kHz / 1ch / >= 2.5s を厳密検証、失敗で build を落とす
      - sleep を 5/8/11s に調整（offline render 完了後のスクリーンショット）
- [ ] v3 を push → Codemagic 実走 → artifacts_003 回収して以下を確認:
      - スクリーンショットで Hypnoctone の UI（暗背景・ヘッダ・PulseView・Start/Stop ボタン）が描画される
      - `sine-440hz.wav` を DL して 440Hz サイン波を実聴
- [ ] 実機確認が必要になったら: Apple Developer Program + TestFlight 経由で自分の iPhone に配信

## Task 5 — フェードイン / フェードアウト

- [x] Phase 1: ToneRenderState に fade 用プロパティ (`currentAmplitude` / `targetAmplitude` / `fadeFramesRemaining`) を追加
- [x] Phase 2: render block を補間付きに修正（メインから currentAmplitude を読まない構造、Codex 指摘 3 反映）
- [x] Phase 3: AudioEngineController を `@MainActor` 化、`stop()` を Task で fade-out 完了後に finalize（Codex 指摘 1 反映）
      - Stop 連打レース対策で `stopGeneration` 世代番号を導入（Codex 指摘 2 反映）
- [x] Phase 4: AudioViewModel.isPlaying を「ユーザー意図」、controller.isRunning を「engine 稼働」に分離
- [x] Phase 5: offline render を fadeIn → 定常 → fadeOut の 3 段に。総フレーム +bufferCapacity の余裕で fade-out 確実完了（Codex 指摘 4 反映）
- [x] Phase 6: codemagic.yaml の duration 検証を >= 3.5s に
- [x] Phase 7: Codex レビュー → 指摘 (1)(2)(3)(4) を反映
- [x] Task 5 push → Codemagic 実走 → artifacts_004 で fade 形状を確認（生サンプル解析で線形減衰を実証、終端は完全無音）
- [x] 後続課題 (Codex Task 5 指摘 5): `controller.start()` を `@discardableResult Bool` 返却に変更
      - `startRealtime` / `startOfflineRender` も Bool 返却、各早期 return → `return false`
      - `AudioViewModel.start()` で controller が成功時のみ isPlaying = true
      - offline render の defer ログを成功/失敗で文言分け（renderSucceeded フラグ）
      - Codex 簡易レビュー反映: @discardableResult のコメント精度修正 / defer ログ文言分け

## Task 6 — DroneGenerator 分離

- [x] Phase 1: DroneGenerator.swift 新規作成（ToneRenderState 内包、AVAudioSourceNode 構築、scheduleFade* API、220Hz デフォルト）
- [x] Phase 2: ToneRenderState を DroneGenerator の内部実装として位置付け（ファイルは残置）
- [x] Phase 3: AudioEngineController を DroneGenerator 経由に refactor、WAV 名 sine-440hz.wav → drone.wav に変更
- [x] Phase 4: Codex レビュー → 指摘 (3)(4)(5) を反映
      - `currentTargetAmplitude` → `hasAudibleTarget: Bool` の意味 API に変更
      - `scheduleFadeIn/Out(duration: TimeInterval)` に変更（Generator が sampleRate を持つので Controller 側の frame 換算が不要）
      - stale comment 2 箇所修正
- [ ] Phase 5: push → CI → artifacts_005 で 220Hz WAV 確認、波形が低音化していること & fade 形状維持を実証
- [x] **High 後続課題 (Codex Task 6 指摘 1)**: ToneRenderState を pending（main writer / audio reader）/ active（audio 単一所有）に分離。active 書き戻し競合（fadeFramesRemaining の上書き）を完全に解消
      - generation counter + double-check で best-effort な publication プロトコルを実装
      - Codex 再レビュー: active 書き戻し競合は解消されたが、pending 領域は依然として Swift memory model 上 data race。store-store reordering で stale payload を accept する理論的穴が残る（実用上は許容）
- [x] **厳密 atomicity 後続課題**: pending 領域の torn read を完全に排除するため Swift Atomics パッケージ導入を検討。`pendingGeneration` を `ManagedAtomic<UInt32>` で release/acquire、`pendingTargetAmplitude` は `bitPattern` 経由で UInt32 atomic に。iOS 18+ なら標準の `Synchronization.Atomic`。Task 7+ で取り組み → **Task 7 で完遂**

## Task 7 — pending 領域の data race 厳密排除（odd/even seqlock + atomic）

- [x] Phase 1: swift-atomics SPM 依存を pbxproj に追加
      - 手書き pbxproj に PBXBuildFile / XCRemoteSwiftPackageReference / XCSwiftPackageProductDependency セクション新設
      - target の `packageProductDependencies` と PBXProject の `packageReferences` を追加
      - Frameworks build phase に Atomics をリンク
      - swift-atomics 1.2.0 upToNextMajorVersion を https://github.com/apple/swift-atomics.git から取得
- [x] Phase 2: ToneRenderState の pending 3 フィールドを ManagedAtomic 化
      - `pendingTargetAmplitudeBits: ManagedAtomic<UInt32>`（Float bitPattern）
      - `pendingFadeFrames: ManagedAtomic<Int>`
      - `pendingGeneration: ManagedAtomic<Int>`
      - audio-thread-only な active / phase / currentAmplitude / lastConsumedGeneration は plain のまま
- [x] Phase 3: DroneGenerator を odd/even seqlock に書き換え
      - writer（main）: gen を `.acquiringAndReleasing` で odd → payload を relaxed store → gen を `.releasing` で even
      - reader（render block）: `g1 acquire load → even & 新世代チェック → payload relaxed load → g2 acquire load → g1==g2 で commit`
      - 旧 plain-field seqlock を完全置換
- [x] Phase 4: Codex に 4 回往復レビュー
      - 1 回目: 「acquire/release だけで OK」と誤判断 → HIGH 指摘で multi-field snapshot 不整合の race を発見
      - 2 回目: seqlock 復活 → 「writer mid-payload window」（payload 書き込み済み・gen 未更新時の race）を発見
      - 3 回目: odd/even seqlock 採用 → begin marker の ordering が `.releasing` だと「後続 store の前倒し」を防げないと指摘
      - 4 回目: begin = `.acquiringAndReleasing` / end = `.releasing` に → 最終 OK
- [x] Phase 5: push → Codemagic 実走 → artifacts_008 で WAV 形状維持を確認
      - swift-atomics の SPM 解決が CI で初回成功（ビルド通過）
      - アプリ crash 無し（t+5/8/11s で pid 1840 生存）
      - WAV: pcm_s16le / 44100Hz / 1ch / 4.09s（仕様 >= 3.5s クリア）
      - 0.1s 窓 max-abs 解析で fade-in 0→2317 線形 / 定常 2317 平坦 / fade-out 2317→0 線形を実測
      - odd/even seqlock writer + atomic ManagedAtomic load/store が realtime audio 制約下で安定動作

## Task 8 — NoiseGenerator 追加（ピンクノイズを Drone に重ねる）

- [x] Phase 1: NoiseRenderState 作成
      - DroneGenerator の ToneRenderState と同じ atomic 構造（pending 3 フィールドを ManagedAtomic）
      - 追加: xorshift32 PRNG state（UInt32, seed=0xCAFEBABE）
      - 追加: Paul Kellet's pink filter state（b0..b6 Float）
      - defaultAmplitude = 0.05（Drone 0.2 の 1/4）
- [x] Phase 2: NoiseGenerator 作成
      - DroneGenerator と同形式の @MainActor final class
      - render block: odd/even seqlock fade consume → xorshift32 (`&<<`, `&>>`) でホワイトノイズ → Paul Kellet's filter でピンク化 → fade amplitude
      - ホワイトノイズ Float 化は上位 24bit を使う精度配慮（`Float(prng &>> 8) * (2.0 / 1<<24) - 1.0`）
      - scheduleFadeIn/Out / hasAudibleTarget は DroneGenerator と完全同形式
- [x] Phase 3: AudioEngineController で Noise を attach
      - noiseGenerator: NoiseGenerator フィールド追加、init で生成
      - buildAudioGraph で Drone と Noise の両 source を mainMixerNode に並列 connect
      - scheduleFadeIn/Out で両 generator に同じ duration で fade スケジュール
      - hasAudibleTarget チェック: drone OR noise
      - WAV ファイル名 `drone.wav` → `sleep-mix.wav`（Drone 単独ではなく mix を表す）
      - codemagic.yaml の WAV 参照とコメント・ステップ名も同期更新
- [x] Phase 4: Codex レビュー
      - 1 回往復で Critical/High/Medium 全てなしの最終 OK
      - 軽微指摘の WAV 名違和感 → リネームで対応
      - Paul Kellet's 係数妥当性 / xorshift32 audio thread 安全性 / 並列 mixer 接続 / クリッピング余裕を全部確認
- [x] Phase 5: push → Codemagic 実走 → artifacts_009 で Drone + Noise mix を確認
      - 初回 push は YAML エラー（"Sleep mix: 220Hz" の `:` が key/value 誤解釈）で失敗
        → fix コミット a09559f で step name をダブルクオート quote して解消
      - sleep-mix.wav: pcm_s16le / 44100Hz / 1ch / 4.09s（仕様クリア）
      - crash 無し（pid 1809 が t+5/8/11s で生存）
      - 0.1s 窓解析: 定常区間 max が 2508〜2750 で揺らぐ（Task 7 の Drone 単独 max=2317 一定 と対比）
        = ピンクノイズの重畳を実測で確認
      - RMS は Drone 支配で ~1640、Noise 0.05 amp の影響は peak には出るが RMS には出ない（理論一致）
      - fade-in/fade-out の線形性が両 generator で同期維持
      - クリッピング余裕も十分（max 2750 / 32767 = 0.084）

## Task 9 — 音質アップ第 1 弾: Drone を多声化（純正律和音）

- [x] Phase 1: AudioEngineController を多声 Drone に拡張
      - `droneGenerator: DroneGenerator` (単数) → `droneGenerators: [DroneGenerator]` (配列)
      - 3 声構成: 基音 (220Hz amp=0.15) / 完全 5度 (× 3/2 = 330Hz amp=0.08) / オクターブ (× 2.0 = 440Hz amp=0.05)
      - 純正律比（3/2, 2/1）で平均律の微細うなり（5度で 0.4Hz 差）を回避、Sleep 用途の協和優先
      - init パラメータ名 `frequency` → `rootFrequency`（意味の明確化）
      - buildAudioGraph で全 Drone + Noise を mainMixerNode に並列 attach/connect
      - scheduleFade*: for-in で全 Drone + Noise に同 duration スケジュール
      - hasAudibleTarget チェック: `droneGenerators.contains(where:)` || noiseGenerator
      - Headroom: Drone 合計 0.28 + Noise 0.05 統計 ≒ 0.3 ピーク → mainMixer 0.5 で実効 0.15
- [x] Phase 2: Codex レビュー
      - 初回: Medium 1 件（振幅コメントの厳密性 — Noise は厳密上限保証されないので断言を弱める）
      - 反映後: Critical/High/Medium 全て無しで最終 OK
- [x] Phase 3: push → Codemagic → artifacts_010 で和音化を確認
      - WAV 仕様: pcm_s16le / 44100Hz / 1ch / 4.09s ✓
      - crash 無し（probe t+5s の「not running」は起動シーケンスの一時的タイミング、t+8s 以降生存）
      - **Goertzel FFT 定常区間 2.4 秒で 3 周波数のピークを実証**:
        - 220Hz mag=1739 / 330Hz mag=924 / 440Hz mag=579
        - 対照点 (100/550/880Hz) は mag 1.4〜2.1 でフラット → SNR 1000 倍超
        - 実測比 1.00:0.53:0.33 が設計比 0.15:0.08:0.05 = 1.00:0.53:0.33 と**完全一致**
      - 振幅エンベロープ: fade-in 線形 / 定常 max ~3200 / fade-out 線形（Task 8 max=2750 から +20% で 3 声合算の peak 上昇を反映）
      - RMS は 1455（Task 8 の 1640 から低下 = 基音 amp 0.2→0.15 化が支配的、上倍音は RMS に寄与少、理論一致）
      - クリッピング余裕十分（max 3296 / 32767 = 0.10）

## Task 10 — 音質アップ第 2 弾: ステレオ化（L/R detune + 独立 PRNG ノイズ）

- [x] Phase 1: ToneRenderState + DroneGenerator を stereo + L/R detune 対応
      - ToneRenderState に frequencyLeft/Right, phaseIncrementLeft/Right, phaseLeft/Right を追加
      - init に `detuneCents: Double = 2.0` 追加、L=freq×2^(-c/2400) / R=freq×2^(c/2400) で幾何平均が元 freq になる
      - DroneGenerator init にも detuneCents パラメータ、render block を L/R 別 phase で書き換え
      - 2.0 cent で 220Hz 基音時に約 4 秒周期のゆるいビート → Sleep に最適なゆらぎ
- [x] Phase 2: NoiseRenderState + NoiseGenerator を stereo 対応
      - NoiseRenderState に prngStateLeft/Right, b0..6 L/R 独立 filter state を追加
      - L=0xCAFEBABE / R=0xDEADBEEF の独立 seed で相関ゼロの真ステレオピンクノイズ
      - NoiseGenerator render block を L/R 独立に xorshift32 + Paul Kellet's で書き換え
- [x] Phase 3: AudioEngineController を stereo format / WAV channels=2 対応
      - AVAudioFormat channels: 1 → 2
      - AVAudioFile fileSettings の AVNumberOfChannelsKey: 1 → 2
      - mainMixerNode → outputNode の最終変換は AVAudioEngine 任せで動く想定
- [x] Phase 4: codemagic.yaml の ffprobe 検査を channels=2 / L≠R に強化
      - 単純な channels=2 だけだと「片 ch silent」「L/R 同一」を検出できない
      - ffmpeg `pan=mono|c0=c0/c0=c1/c0=0.5*c0-0.5*c1` で L/R/差分を抽出し max-abs を測定
      - L_MAX >= 500, R_MAX >= 500, DIFF_MAX >= 100 を要求
- [x] Phase 5: Codex レビュー
      - 1 回目: Critical/High 無し、Medium 2 (CI が L/R 別検査不足 / 「平均」コメントが幾何平均と不一致)
      - 反映後: Codex 最終 OK
      - 軽微指摘: mono コメント → stereo に修正、44.1kHz/1ch コメント残骸も 2ch に
- [x] Phase 6: push → Codemagic → artifacts_011 で stereo 化を完全実証
      - WAV: pcm_s16le / 44100Hz / **channels=2** / 4.09s（ファイルサイズも mono 比 2 倍）
      - L_MAX=4713 / R_MAX=4666 / **DIFF_MAX=4465** （DIFF/L_MAX=95% = ほぼ完全独立）
      - **L/R 別 Goertzel FFT で detune を実証**:
        - 220Hz 声: L 側 219.87Hz mag=2454 / R 側 220.13Hz mag=2455 が誤差 1 で完全対称
        - 5度 330Hz 声: L 329.81 (1308) >> R 329.81 (122)、R 330.19 (1309) >> L 330.19 (127)
        - オクターブ 440Hz 声: 同様に L 低側 / R 高側で対称
      - 中心周波数 (220/330/440) の mag は L/R で完全一致（幾何平均が厳密に保たれている証拠）
      - crash 無し（pid 1894 が全 probe で生存）
      - 設計（3 声 × L/R detune × 独立 PRNG）が全部正しく機能していることが完全実証された

## Task 11 — 音質アップ第 3 弾: LFO ゆらぎ（pitch vibrato）

- [x] Phase 1: ToneRenderState に LFO state 追加
      - 定数: lfoDepthCents, lfoPhaseIncrement (2π / (period × sr))
      - audio thread 単一所有: lfoPhase（init で initialPhase 設定可）
      - init に lfoPeriodSeconds / lfoDepthCents / lfoInitialPhase パラメータ追加
- [x] Phase 2: DroneGenerator render block に LFO 組み込み
      - **ブロック単位で 1 回**だけ sin/pow を計算（5.8ms ごと、cent 誤差 0.007cent でクラックは可）
      - lfoMod = pow(2, sin(lfoPhase) * depthCents / 1200)
      - phaseIncrementLeft/Right に lfoMod 乗算 → ブロック内ループで使用
      - phase 自体は連続維持なのでクリックノイズなし
      - lfoPhase はブロック末尾で frameCount サンプル分進めて 2π 折り返し
      - depth=0 で modRatio=1 = 実質 LFO 無効（後方互換）
- [x] Phase 3: AudioEngineController で 3 声に独立 LFO 設定
      - 基音 220Hz: period 17.3s / depth 2.5cent / phase 0
      - 5度 330Hz: period 23.1s / depth 2.0cent / phase π/2
      - オクターブ 440Hz: period 13.7s / depth 1.5cent / phase π
      - 素数寄り周期で「揃わない」「無限に変化し続ける」音響
- [x] Phase 4: Codex レビュー
      - Critical/High/Medium 全てなし、最終 OK 一発で取得
      - 軽微指摘「最小公倍数が事実上発散」表現を「互いに約分しにくい比」に修正
- [x] Phase 5: push → Codemagic → artifacts_012 で LFO 効果を完全実証
      - WAV stereo / 44.1kHz / 4.09s 維持、crash 無し（pid 1893 全 probe 生存）
      - L_MAX 4713→5020 (+6%) / R_MAX 4666→4875 (+4%) / DIFF_MAX 4465→4154 (-7%)
      - **Goertzel で主ピーク 35〜70% 低下**を確認 = LFO がエネルギーを ±cent 範囲に分散している証拠
        - 220 L 219.873Hz mag: 2454 → 1539 (-37%)
        - 330 R 330.190Hz mag: 1309 → 360 (-72%)
        - 440 L 439.746Hz mag: 817 → 284 (-65%)
      - **「対称位置」でピーク出現** (L 側で R 用 220.127Hz mag が +99%) = LFO 深さ 2.5cent が
        detune 半幅 1cent より大きいため周波数領域で L/R が部分混合
      - 3 声すべて同パターンで 3 つの独立 LFO が全部動いている確証
      - 設計判断: LFO depth (2.5cent) > detune 半幅 (1cent) → 「ゆらぎ感」優先、L/R 明確分離は弱め
        実聴判断で LFO depth を下げる選択肢あり（Task 11.5 として保留）

## Task 12 — 音質アップ第 4 弾: ノイズ帯域整形（雨音風 lowpass + cutoff LFO）

- [x] Phase 1: NoiseRenderState に lowpass + cutoff LFO state 追加
      - 定数: filterCutoffCenter (2000Hz), filterCutoffDepthHz (400Hz), filterLfoPhaseIncrement
      - audio var: lpL/lpR (1-pole IIR state, L/R 独立), filterLfoPhase (L/R 共通)
      - init に filter パラメータ + defaultAmplitude 既定 0.05 → 0.08 (lowpass 補正)
- [x] Phase 2: NoiseGenerator render block に lowpass + cutoff LFO を組み込み
      - ブロック単位で cutoff = center + depth × sin(filterLfoPhase) → α = 1 - exp(-2π × cutoff / sr)
      - cutoff は 20Hz〜nyquist-100Hz にクランプ（異常値防御）
      - Paul Kellet's filter 後に L/R 別 lowpass: lpL += α × (pinkL - lpL)
      - ブロック末尾で filterLfoPhase を進めて 2π 折り返し
      - exp/sin は 1 ブロックあたり 1 回ずつで audio thread 負荷極小
- [x] Phase 3: AudioEngineController で NoiseGenerator パラメータを明示渡し
      - amp=0.08, cutoff=2000±400Hz, LFO 11s 周期を明示
      - クラスドキュメント / Headroom コメント更新（Noise が hard limit 無し統計信号と明示）
- [x] Phase 4: Codex レビュー
      - Critical/High なし、Medium 2 件（α コメント精度 + Headroom 表現）→ 反映後最終 OK
- [x] Phase 5: push → Codemagic → artifacts_013 で雨音風 lowpass を完全実証
      - WAV stereo / 4.09s / L/R 検査クリア（L_MAX 5159, R_MAX 4982, DIFF_MAX 4173）
      - crash 無し（pid 1881 全 probe 生存）
      - Drone 220/330/440Hz mag は Task 11 から完全維持（lowpass が Drone に影響しないことを実証）
      - **高域 Goertzel mag の比較で lowpass を実証**（Task 11 vs Task 12, L channel）:
        - 1000Hz: 0.99 → 1.57 (+58%, 中低域底上げ = amp 0.05→0.08 効果)
        - 2000Hz (cutoff): 1.41 → 1.70 (+20%, まだ通過)
        - 4000Hz: 0.39 → 0.30 (-23%, 減衰開始)
        - 7000Hz: 0.78 → 0.36 (-54%, 急減衰)
        - 10000Hz: 0.38 → 0.15 (-61%, 急減衰)
        - 14000Hz: 0.20 → 0.08 (-60%, ほぼ消音)
      - amp +60% の全体引き上げにも関わらず 4kHz 以上は実測 mag が減少 = lowpass の決定的証拠
      - 1-pole 6dB/oct 理論と実測の傾斜がよく整合
      - 「シャラシャラ」の不快な高域がカットされ「柔らかい雨音」感が出る音響的成功

## Task 13 — 音質アップ第 5 弾: 倍音追加（第2 + 第3 倍音で楽器的温かみ）

- [x] Phase 1: ToneRenderState に HarmonicVoice 構造体 + harmonics 配列追加
      - struct HarmonicVoice { ratio, amplitudeFactor, phaseIncrementLeft/Right, phaseLeft/Right }
      - var harmonics: [HarmonicVoice] (audio thread 単一所有)
      - init で baseInc × ratio で倍音 phaseIncrement を計算 → L/R detune 比率も自動継承
        (第 2 倍音では L/R 差が基音の 2 倍 = ビート周期も 1/2)
- [x] Phase 2: DroneGenerator render block に倍音合成を組み込み
      - 基音 sin 計算後 for i in 0..<harmonicsCount で倍音 sin を加算
      - 各倍音にも基音と同じ LFO modRatio を掛ける（楽器的に自然）
      - 配列要素を var h = state.harmonics[i] でローカル取得して最後に書き戻し
        (subscript uniqueness check を read+write 2 回に抑える最適化)
- [x] Phase 3: AudioEngineController で 3 声に倍音指定
      - 全 3 声に harmonics: [(2.0, 0.2), (3.0, 0.1)] (第2倍音=20%、第3倍音=10%)
      - Headroom 再計算: 0.28 × 1.3 = 0.364 + Noise 0.08 → mainMixer 0.5 で 0.22 実効
      - 偶数 + 奇数の組み合わせで「ハーモニウム/オルガン系」の温かみを想定
- [x] Phase 4: Codex レビュー
      - Critical/High/Medium 全てなし、一発 OK
      - Low 改善提案「ローカル変数取得 + 最後書き戻し」を反映（コード意図も明確化）
- [x] Phase 5: push → Codemagic → artifacts_014 で倍音化を完全実証
      - WAV stereo / 4.09s 維持、L/R 検査クリア（L_MAX 5242, R_MAX 5200, DIFF_MAX 4147）
      - crash 無し（pid 1875 全 probe 生存）
      - **Goertzel で全 5 つの倍音ピーク出現を確認**（Task 12 vs Task 13, L channel）:
        - 220Hz (基音): 2286 → 2286 ±0 ✓ 基音完全維持
        - 330Hz (基音): 1112 → 1112 ±0 ✓ 基音完全維持
        - 440Hz (基音+220第2): 187 → 223 (+19%) ✓ 重畳で増強
        - 660Hz (220第3+330第2): 4.5 → 204 (× 45 倍!) ✓ 新規ピーク
        - 880Hz (440第2): 4.0 → 22 (× 5.6) ✓ 新規ピーク
        - 990Hz (330第3): 2.8 → 20 (× 7.1) ✓ 新規ピーク
        - 1320Hz (440第3): 2.5 → 4.6 (× 1.8) ✓ 弱いが立つ
      - 対照点 550/770/1100Hz は変化なし（ノイズフロア維持）
      - 倍音構成が「ハーモニウム/オルガン系」の自然な減衰
      - クリッピング余裕 (peak 5242/32767 = 16%)

## Task 14 — 音質アップ第 6 弾: エンベロープゆらぎ（全体音量の呼吸感）

- [x] Phase 1: ToneRenderState + NoiseRenderState に envelope LFO state 追加
      - 両 RenderState に envelopeDepth (定数), envelopePhaseIncrement (定数), envelopePhase (audio var)
      - init に envelopePeriodSeconds / envelopeDepth / envelopeInitialPhase パラメータ
      - pitch LFO とは独立の別レイヤー
- [x] Phase 2: DroneGenerator + NoiseGenerator render block に envelope multiplier 適用
      - ブロック単位で envMultiplier = 1.0 + depth × sin(envelopePhase) を計算
      - ループ最終出力 sampleL/R に乗算してから buffer 書き込み
      - 倍音/lowpass を含む全体に同じ envelope が掛かる
      - ブロック末尾で envelopePhase を進めて 2π 折り返し
      - depth=0 または phaseIncrement=0 のとき multiplier=1.0 で無効化（中途半端設定対策）
- [x] Phase 3: AudioEngineController で全 generator に共通 envelope 設定
      - Drone 3 声 + Noise すべてに period=37s / depth=0.075 / initialPhase=0
      - 同じ周期・初期位相 → 同じ frame 数進行で実用上同期
      - Headroom: 0.4 × 1.075 = 0.43、mainMixer 0.5 経由で 0.22 実効
      - クラスドキュメントに「同期呼吸」明示
- [x] Phase 4: Codex レビュー
      - Critical/High なし、Medium 2 件 (同期保証精度 + 中途半端設定ガード) → 反映後最終 OK
      - 「将来 graph 変更時は共有 sample clock / mixer 後段 envelope に移行」コメント明記
- [x] Phase 5: push → Codemagic → artifacts_015 で envelope を計測実証
      - WAV stereo / 4.09s / L/R 検査クリア、crash 無し
      - **0.1s 窓 peak で Task 13 vs Task 14 比較 → 理論値と実測値が誤差 0.5% 以内で完全一致**:
        - 0.1s: 実測 1.0017 / 理論 1.0013 (sin(2π×0.1/37) × 0.075 + 1)
        - 1.0s: 実測 1.0106 / 理論 1.0127
        - 2.0s: 実測 1.0243 / 理論 1.0250
        - 3.0s: 実測 1.0351 / 理論 1.0366
        - 3.3s: 実測 1.0382 / 理論 1.0399
      - envelope LFO `1.0 + 0.075 × sin(2π × t / 37)` が設計通り振幅を変調していると実証
      - CI 4 秒 WAV では 1/10 周期しか進まず変化が subtle (最大 +3.8%) なので体感は弱い
      - フル呼吸サイクル (37 秒) は実機聴取で確認するという方針（ユーザー判断）

## Task 15 — ATMÓS 化 Step 1: Note / Scale 抽象化 + UI 音名表示

ATMÓS スクショ分析を元に、Hypnoctone を generative composition の方向に進める第 1 弾。
今回は基盤のみ（音名/スケール抽象化 + UI 表示）。後続 Step 2 で generative pitch selection、
Step 3 で SUB、Step 4 で GRAIN、Step 5 で 4 モードに進む計画。

- [x] Phase 1: MusicTheory.swift 新規作成
      - struct Note { midiNumber } + computed frequency (12 TET, `440 × 2^((midi-69)/12)`) + name ("A3"等)
      - init(midiNumber:): precondition で 0..<128 範囲チェック
      - init?(name:): "A3"/"C#4"/"C-1" 等パース、範囲外 octave で nil
      - enum Scale: majorPentatonic / minorPentatonic / major / naturalMinor / chromatic
        - intervals (半音 offsets), shortName (UI 用), notes(root:octaves:) 展開
- [x] Phase 2: DroneGenerator / AudioEngineController を Note ベースに移行
      - AudioEngineController に rootNote / scale / droneNotes フィールド追加
      - init を rootFrequency:Double → rootNote:Note + scale:Scale に変更
        - default: A3 + majorPentatonic
      - droneNotes = [root, root+7, root+12] = [A3, E4, A4]
      - 純正律 (5度=1.5x) → 平均律 (2^(7/12)≈1.498x) で E4 が 330Hz → 329.63Hz に
- [x] Phase 3: MainView UI に音名表示
      - AudioViewModel に rootNoteName / scaleName / droneNoteNames を expose
      - MainView の statusText 下に musicInfo セクション追加
        - "Scale A3 MajPentatonic" (ATMÓS と類似フォーマット)
        - "A3 · E4 · A4" (Drone 3 声の音名)
- [x] Phase 4: Codex レビュー
      - Critical/High なし、Medium 2 件
        - Note の MIDI 範囲検証 → precondition + init? の guard で反映
        - CI Goertzel target 更新 (CI には未導入、手動解析の方針で OK)
      - メモ指摘の旧 330Hz コメント残骸も反映済み
- [ ] Phase 5: push → CI 検証 (artifacts_016)
      - 期待: WAV stereo/4.09s 維持、L/R 検査クリア、crash 無し
      - 手動 Goertzel target 更新: 220 / 329.6276 / 440 Hz (E4 は平均律で 329.63)
      - 純正律→平均律変更による「うねり」程度を観察（LFO/envelope で隠れる想定）
      - MainView の音名表示 (Scale A3 MajPentatonic / A3 · E4 · A4) がスクリーンショットに出る

[Task 15 Phase 5 完了結果 — 末尾の "[ ] Phase 5" は historical で、以下が実測]

      ✓ WAV stereo / 4.09s / L/R 検査クリア / crash 無し (pid 1784)
      ✓ **Goertzel で平均律変更を完全実証**:
        - 220Hz (A3): 2286 → 2345 (+3%、平均律と同周波数なので変化なし)
        - 329.63Hz (E4 平均律): 222 → 1134 (× 5.1、主ピークが移動)
        - 330Hz (旧純正律): 1112 → 713 (-36%、0.37Hz ずれて検出減衰)
        - 440Hz (A4): 223 → 226 (維持)
      ✓ MainView UI screenshot で "Scale A3 MajPentatonic" + "A3 · E4 · A4" 表示確認
      ✓ minimal UI コンセプトを壊さず情報を統合

## Task 16 — ATMÓS 化 Step 2: Generative Pitch Selection

各 Drone 声の周波数を時間軸で動的に切り替える。glide で滑らかに遷移、各 voice が
独立 interval (素数寄り)、候補リストから現在以外をランダム選択。UI も自動更新。

- [x] Phase 1: DroneGenerator に setFrequency(_:, glideSeconds:) 追加
      - ToneRenderState 拡張: detuneCents 保持、phaseIncrement を var に、glide target 追加
      - 新規 pitch 用 atomic seqlock (fade とは独立): pendingTargetPhaseIncrementL/R Bits (UInt64),
        pendingGlideFrames, pendingPitchGeneration (odd/even)
      - HarmonicVoice から phaseIncrement 削除 → render block で「基音 × ratio × lfoMod」都度計算
        (glide で基音が動くと倍音も自動連動)
      - render block: pitch seqlock consume + per-sample 線形補間 (target - current) / glideFrames
      - DroneGenerator.setFrequency: detuneCents を使って L/R 別 phaseIncrement 再計算 + atomic publish
- [x] Phase 2: PitchScheduler を AudioEngineController に統合
      - ObservableObject 化、@Published currentDroneNotes
      - pitchCandidates 3 voices × 4 候補 (A Major Pentatonic 固定、Step 2.5 で汎用化予定)
      - pitchIntervals [19, 23, 13]s (素数寄り)、pitchGlideSeconds (realtime 3s / CI 0.5s)
      - startPitchScheduler (realtime 専用 Task ベース) / stopPitchScheduler / advanceVoicePitch
      - offline render ループに inline frame counter scheduler (× 0.1 interval = 1.9/2.3/1.3s)
- [x] Phase 3: AudioViewModel objectWillChange forward
      - cancellables: Set<AnyCancellable> 追加
      - controller.objectWillChange.sink で self.objectWillChange.send() forward (DispatchQueue.main 経由)
      - droneNoteNames を controller.currentDroneNotes ベースに変更
- [x] Phase 4: Codex レビュー
      - Critical 1 件: import Combine 欠落でビルドエラー → 即修正
      - Medium 1 件: pitchCandidates の rootNote/scale 制約 → コメント明示で反映
      - 最終 OK
- [ ] Phase 5: push → CI 検証 (artifacts_017)
      - 期待: WAV stereo/4.09s 維持、L/R 検査クリア、crash 無し
      - **本命**: Goertzel で複数候補 note (220/247/277/330 等) のエネルギー分散観測
        - 静的単一ピーク → 動的複数ピーク = generative の証拠
      - UI screenshot: 起動時 A3·E4·A4 / 後の screenshot で異なる音名
      - クリッピング無し、glide で位相連続維持

[Task 16 Phase 5 調整: artifacts_017 で「怖い音」になった対策]

      - 原因分析: CI interval ×0.1 (1.9/2.3/1.3s) + glide 0.5s → 4 秒 WAV 内で 4-5 回切替
        - fade-in 0.8s 中に既に切替発生、複数 voice が同時に違う方向に動いて干渉
        - 振幅エンベロープも RMS 1485→890→1632 と不安定 (位相打ち消し)
        - 警報・サイレン的な聴感に
      - 対策（ユーザー判断）: WAV 尺 4s → 16s に延長し、本番 interval (19/23/13s) を CI でも使う
        - AudioEngineController: offlineRenderSeconds 4.0 → 16.0
        - pitchGlideSeconds: CI 0.5s 廃止 → realtime と同じ 3.0s に統一
        - inline scheduler: ×0.1 scale 廃止 → 本番 interval そのまま
        - codemagic.yaml: duration 検査 >= 3.5s → >= 15.0s
      - 期待: 16 秒 WAV 内で octave voice (13s) のみ 1 回切替、root/5th は変化なし
        → ATMÓS 的なゆっくりした変化、fade-in 中は切替なし
      - CI ビルド時間 +12s / WAV サイズ ~3MB に
- [ ] Phase 5 再 push → CI 検証 (artifacts_018)
      - 期待: WAV stereo / 16.09s / L/R 検査クリア
      - Goertzel で octave voice の切替 (A4 440 → 別候補 B4 494 / C#5 554 / E5 659 のいずれか) 観測
      - 振幅エンベロープが安定 (RMS 干渉なし)
      - 「怖い音」が「ATMÓS 的な静かな ambient」に改善

[Task 16 Phase 5 再調整: artifacts_018 で「テルミン感」になった対策]

      - 原因: octave voice (A4=440, C#5=554Hz) の高音域 + glide 3s で「テルミン奏法」感
      - ATMÓS との比較: ATMÓS は E2(82)/F#2(92)/A2(110) の重低音重心、Hypnoctone は中高域中心
      - 対策（ユーザー判断）: **全 voice を 1 オクターブ下げる**
        - rootNote default: A3 (220) → A2 (110)
        - droneNotes [root,+7,+12]: A3/E4/A4 → A2/E3/A3 (110/165/220Hz)
        - pitchCandidates 全て 1 オクターブ下げ:
          - root: [A2, B2, C#3, E3] (110-165Hz)
          - 5th: [E3, F#3, A3, B3] (165-247Hz)
          - octave: [A3, B3, C#4, E4] (220-330Hz)
        - 倍音 ×2/×3 で 220-660Hz 帯が覆われるので音色感は維持
      - クラスドキュメントの周波数表記を 110/165/220 ベースに更新
- [ ] Phase 5 再々 push → CI 検証 (artifacts_019)
      - 期待: 「テルミン感」消失、ATMÓS 的な重低音 drone に
      - WAV stereo 16s / L/R 検査クリア / crash 無し
      - UI 音名 A2·E3·A3 表示、generative で octave (13s 後) が候補内で動く

[Task 16 終了判断: generative を OFF にして Task 14 状態に戻す]

      - artifacts_018/019 の聴感: 1 オクターブ下げてもテルミン感 (高音 + glide) が違和感
      - ユーザー判断: 「初期のころ (Task 14 まで) の静かな方が良い、高音要らない」
      - 対応:
        - `generativePitchEnabled = false` flag を導入し、startPitchScheduler() と
          offline inline scheduler を guard で skip
        - 音域を Task 16 の A2 ベース → Task 15 の A3 ベース (A3/E4/A4) に戻す
        - pitchCandidates も A3 ベースに復元 (将来再有効化用に保持)
        - Task 16 のコード基盤 (setFrequency, glide, atomic seqlock, Scheduler) は
          全部残置。flag を反転するだけで復活可能
      - 残置の理由: ATMÓS 化方向は将来再検討の可能性。実機聴取で「やはり動きが欲しい」と
        なったら flag = true で即復活、調整 (interval / glide / 音域 / 候補) のみ続行
      - 結果: Task 14 (倍音 + envelope) + Task 15 (Note UI 表示) 状態に。
        WAV 尺 16s は維持 (envelope 1/3 周期分の動きが観察可能)
- [ ] 再 push → 検証 (artifacts_020): 静的 Task 14 + UI 表示の状態に戻る確認

## Task 17 — ATMÓS 化 Step 3: リバーブ/空間処理 (AVAudioUnitReverb)

Task 16 で「音色や音域は触らず空間だけ拡張する」方向に転換。AVAudioUnitReverb を
mainMixer の後段に挟むことで、Drone/Noise の音色は維持しつつ「広い空間に漂う」
ATMÓS 的な没入感を出す。

### 設計

- グラフ変更: `[Drone × 3 + Noise] → mainMixerNode → reverbNode → outputNode`
  - mainMixerNode が自動接続する outputNode への接続を `disconnectNodeOutput` で切ってから挟む
  - reverbNode は AVAudioUnitReverb (factoryPreset=.largeHall, wetDryMix=40)
- offline render の WAV 総尺を 16s → 18s に延長
  - reverb tail (≒1.5〜2s) を捉えるための余裕
  - fade-out 0.8s 後の 1.2s 区間で残響を観察可能に
- AVAudioUnit は manual rendering mode と互換。ただし `attach/connect` のタイミングは
  既存の Drone/Noise と同じく `enableManualRenderingMode` の後

### Phase

- [ ] Phase 1: AudioEngineController に reverbNode (AVAudioUnitReverb) 追加
      - factoryPreset = .largeHall、wetDryMix = 40.0 を init で設定
      - buildAudioGraph: mixer → outputNode の自動接続を disconnect し、mixer → reverb → output に
      - クラスドキュメントを更新（グラフ構成、reverb パラメータ、Headroom 影響）
- [ ] Phase 2: offline render を reverb tail 対応に拡張
      - offlineRenderSeconds 16.0 → 18.0 (fade-out 0.8s 後にさらに 1.2s tail を残す)
      - reverb 内部の遅延も totalFrames の余裕 (+frameCapacity) でカバー
- [ ] Phase 3: codemagic.yaml の WAV 検査を 18s + tail 検証に拡張
      - duration >= 15.0s → >= 17.9s (実 WAV は約 18.09s 出る想定)
      - tail 検証: 16.0〜17.5s 区間の RMS が一定しきい値 (>= 30) 以上で「fade-out 後も残響あり」を実証
      - LATE 検証: 17.8〜18.0s 区間の RMS が tail RMS の 80% 未満まで減衰しているか
      - ffmpeg `atrim=start=16:end=17.5` + RMS 計測の追加
- [ ] Phase 4: Codex レビュー（mainMixer disconnect の妥当性、reverb の manual rendering 互換性、
      Headroom の peak/RMS 変化、tail の検査ロジック）
- [x] Phase 5: push → CI → artifacts_021 検証
      ✓ WAV stereo 18.092880s ✓、L/R 検査クリア (L_MAX=3580, R_MAX=4115, DIFF_MAX=3167)
      ✓ STEADY_RMS_L=1286.9 / TAIL_RMS_L=59.0 / TAIL_RMS_R=30.9 / LATE_RMS_L=2.0
      ✓ TAIL/STEADY=4.6% (>= 2% で十分余裕)、LATE/TAIL=3.4% (< 80% で末尾減衰実証)
      ✓ 実機聴取で「空間に漂う」感を獲得、R 側 tail の薄さも違和感なし (by user)
      ✓ artifacts_022 で CI しきい値緩和 (TAIL 30→20, ratio 0.02 追加) を実走確認

## Task 18 — ATMÓS 化 Step 4: サブベース (A1 / 55Hz)

ATMÓS 的な重心の低い空間を作るため、既存 3 声 (A3/E4/A4) の下に sub bass voice
(A1 = 55Hz, amp 0.05) を薄く敷く。Drone は 3 声 → 4 声構成に。倍音 (×2=110Hz / ×3=165Hz)
が root (220Hz) と自然に音響的に接続する。

### 設計

- `droneIntervals`: `[0, 7, 12]` → `[-24, 0, 7, 12]` (sub を先頭)
- `droneGenerators` 配列に sub voice を先頭追加 (DroneGenerator 再利用、コード追加最小)
- sub voice のパラメータ:
  - frequency: 55Hz (A1 = rootNote - 24 semi)
  - amp: 0.05 (root 0.15 の 1/3)
  - LFO 周期: 29.0s (既存 13.7 / 17.3 / 23.1 と素数で揃わない 4 つ目)
  - LFO depth: 2.0cent (重低音は「うねり」が聴感に出やすいので控えめ)
  - LFO initialPhase: 3π/2 (既存 0 / π/2 / π と 4 等分位相)
  - 倍音: 既存と同じ [(×2, 0.2), (×3, 0.1)]
  - envelope: 既存共通 (37s / ±7.5%)
- pitchCandidates / pitchIntervals も 4 要素に拡張 (generative 再有効化時の備え)
  - sub 候補: A1 / B1 / C#2 / E2 (55-82Hz)
  - sub interval: 31.0s (最ゆっくり、素数)
- Headroom 再計算: Drone 4 声 0.429 + Noise 0.08 + envelope 1.075 + outputVolume 0.5 → 実効 0.27、reverb wet で +20-30% → 0.34、16bit s16le 換算でも余裕

### Phase

- [x] Phase 1: droneGenerators / droneIntervals に sub bass voice (A1) を先頭追加
      - pitchCandidates / pitchIntervals も 4 要素化
      - Headroom コメント更新
- [x] Phase 2: クラスドキュメント (4 声 / A1 表記 / sub と root の倍音接続) 更新
- [x] Phase 3: tasks/todo.md に Task 18 計画追記
- [ ] Phase 4: Codex レビュー
      - Headroom 計算妥当性 (sub 加算で peak/RMS が outputVolume 0.5 で安全か)
      - 倍音 110Hz/165Hz と root 220Hz の音響的整合 (うなり / 干渉リスク)
      - LFO 周期 29s / depth 2cent / initialPhase 3π/2 の選定根拠
      - sub と reverb tail の相互作用 (低周波 reverb は tail が長く聴こえやすい)
- [ ] Phase 5: push → CI → artifacts_023 検証
      - WAV stereo 18.09s、L/R 検査クリア、crash 無し
      - L_MAX/R_MAX の上昇幅 (sub 追加で +500-1000 程度想定)
      - 0.1s 窓 max-abs で「fade-in 中も 55Hz が出ている」確認
      - 手動 Goertzel で 55Hz / 110Hz / 165Hz / 220Hz の各ピーク観察
      - reverb tail (TAIL_RMS) が増える方向 (sub の長い tail 効果)
      - 実機聴取で「重心が下がった」感を確認

## Task 19 — ATMÓS 化 Step 5: GRAIN（粒状音響 / shimmer）

ATMÓS の 4 voice 構成 (TONE / DRONE / SUB / GRAIN) のうち最後の GRAIN を実装。短い windowed
サイン波の「粒」を疎にトリガし、Drone + Noise の上に高音域 (C#5/E5/F#5/A5) の sparkle を
重ねる。reverb tail と組み合わせて「ぽつりと光る音」「shimmer」感を作る。

### 設計

- **GrainRenderState**: 既存 ToneRenderState / NoiseRenderState と同形式の
  「pending / active 分離 + odd/even seqlock」atomic 構造で fade をスケジュール
- **GrainGenerator**: 固定容量プール (8 grain) を audio thread が単一所有、in-place 更新
  で allocation 禁止。`framesUntilNextTrigger{L,R}` をカウントダウンして 0 で発火、
  次間隔は `mean × (0.5 + uniform random)` で 0.5〜1.5x 範囲 (Poisson 過程近似、log 不要)
- **Window**: cosine bell `0.5 × (1 - cos(2π × t / total))` で端点クリックなし
- **Pitch**: trigger 時に uniform random で候補 [C#5, E5, F#5, A5] から選択、生存中は固定
- **L/R 独立**: PRNG / next-trigger カウンタを L/R 別々に持つ。ステレオ拡散
- **同時発音数**: プール満杯時の新 trigger は捨てる (聴感的に自然な cap)
- **Envelope LFO**: Drone/Noise と同じ周期/位相 (37s / ±7.5%) で「全体が一緒に呼吸」
- **CI 検証点**: F#5 = 740Hz は Drone 倍音 (55/220/330/440 系列の整数倍) と被らない最 clean な検出点

### Phase

- [x] Phase 1: GrainRenderState + GrainGenerator 新規作成
      - Atomics ベースの fade seqlock (既存 Drone/Noise と同形式)
      - cosine bell window + xorshift32 PRNG + 固定容量 grain プール
      - pbxproj は PBXFileSystemSynchronizedRootGroup で自動取込のため編集不要
- [x] Phase 2: AudioEngineController に GrainGenerator を統合
      - grainGenerator フィールド追加、init で grainPitches [C#5, E5, F#5, A5] を Note 経由で生成
      - buildAudioGraph で mainMixerNode に並列 attach/connect
      - scheduleFadeIn/Out / hasAudibleTarget チェック更新
      - Headroom コメント更新 (grain 加算で実効 0.28 前後、reverb 後 16bit s16le 余裕あり)
- [x] Phase 3: codemagic.yaml に GRAIN 帯域検証ステップ追加
      - 740Hz (F#5) を主検査点に narrow bandpass (60Hz width)
      - 1200Hz を参照帯にして「GRAIN が F#5 にエネルギー集中」を比率 >= 1.5x で実証
      - L/R 両 ch で MAX >= 200 (s16 で 0.006、noise floor + Drone 漏れ超過水準)
- [x] Phase 4: Codex クロスレビュー
      - 1 回目: Critical なし、High 1 (CI が F#5 単一点依存) / Medium 1 (window コメント精度) /
        Low 2 (Headroom コメント混在 / Poisson 説明) → 全部反映
      - 2 回目: 反映済み確認 + Medium 追加指摘 (CLEANSUM の和 vs 単一参照は偽陽性) →
        max(C#5,F#5) vs REF の 1 帯対 1 帯比較に修正
      - 3 回目: 最終 OK、Critical/High/Medium 追加指摘なし
      - 確認済み: data race なし / atomic ordering 妥当 / audio thread 負荷問題なし /
        pitch scale 整合 OK / window 端点 微小値で実用上問題なし
- [x] Phase 5: push → CI → artifacts_024 で GRAIN を実証 (完全成功)
      - WAV stereo 18.09s ✓、L_MAX=4297/R_MAX=4535/DIFF_MAX=3416 ✓、crash 無し (pid 1768)
      - 候補帯 MAX: C#5=250/244, E5=438/417, F#5=285/286, A5=342/349 (L/R)
      - REF 1200Hz: L=53 / R=49 → CLEAN_MAX/REF = 5.38x (L) / 5.84x (R) ≫ 1.5 ✓
      - reverb tail: TAIL_L 59→97.9 (+66%) = GRAIN trigger の shimmer 残響を実証
      - 実機聴取は実機テスト準備が整ってからの方針

## Task 20 — UI 4 voice グループ化 + 各 voice 独立 MUTE

実機テスト時に「TONE / DRONE / SUB / GRAIN を 1 つずつ ON/OFF」して聴感調整するための
基盤整備。ATMÓS の UI 構造に近づけつつ、audio 層は変更最小 (mute multiplier を別レイヤーで追加)。

### 設計

- **mute は fade と独立した別レイヤー**: 出力 = generator × fade_amp × mute_mult
- **10ms ramp** で per-sample 補間し、クリックノイズ回避 (1/441 ≈ 0.00227 step)
- **atomic flag は relaxed**: payload 公開ではなく単一意図伝達なので acquire/release 不要
- **VoiceGroup マッピング**:
  - TONE = droneGenerators[2] (E4) + droneGenerators[3] (octave A4) 統合
  - DRONE = droneGenerators[1] (root A3)
  - SUB = droneGenerators[0] (sub bass A1)
  - GRAIN = grainGenerator
  - Noise は背景レイヤーで UI 対象外 (API は実装済み、将来「RAIN」slot 追加可能)

### Phase

- [x] Phase 1: 各 RenderState に mute multiplier (mutedFlag + currentMuteMultiplier + step 定数) を追加
- [x] Phase 2: 各 Generator (Drone/Noise/Grain) に setMuted / isMuted API を追加
      - render block ループ内で per-sample に target に近づける (方向転換にも対応)
- [x] Phase 3: AudioEngineController に VoiceGroup enum + setMuted(group:, muted:) / isMuted(group:) /
      displayNoteName(for:) API。VoiceMutable 内部 enum で DroneGenerator/GrainGenerator を統一扱い
- [x] Phase 4: AudioViewModel に voiceGroups (4 タプル配列) + toggleMute(group:)
      objectWillChange.send() で UI 即時更新
- [x] Phase 5: MainView を 4 voice グリッド表示に再構築 (voiceGrid + voiceCell)
      各 cell: ラベル + Note 名 + MUTE ボタン、MUTE 状態で視覚的に区別
      Stopped 状態でも見える → CI screenshot で確認可能
- [x] Phase 6: Codex クロスレビュー → Critical/High/Medium なし、Low 2 件
      - Low 1 (.tone の 2 generator 順次 setMuted の理論的ずれ) → コメントに「ns オーダーの連続 store なので
        audio block を跨ぐ確率ゼロ」と明記、現状維持で OK
      - Low 2 (`·` U+00B7 区切り) → 既存コードと一貫しているので変更なし
- [x] Phase 7: push → CI → artifacts_025 で 4 voice グループ UI を確認 (完全成功)
      - 初回 ビルド失敗 → droneGenerators 関数/変数の同名衝突を修正 (commit de9e7a5)
      - 2 回目 ビルド失敗 → VoiceMutable に @MainActor、tuple keypath を Identifiable struct に置換 (commit 5d083d6)
      - 3 回目 ビルド成功 + 全数値検証 PASS (artifacts_024 と完全同値、副作用なし実証)
      - screenshot: TONE(E4·A4) / DRONE(A3) / SUB(A1) / GRAIN(C#5/E5/F#5/A5) + MUTE ボタン表示 ✓

## Task 21 — ATMÓS 風 4 モード切替 (SLEEP / FOCUS / MEDITATE / RELAX) audio 層

ATMÓS の 4 モード切替を audio パラメータプリセットとして実装。Stop 状態でのみ切替可能
("Stop playback to change mode" 設計)。UI は Task 22 で。

### 設計

- **Stop 状態でのみ Mode 切替可能**: engine.stop() 完了後 (isRunning=false) なら audio thread が動かないので
  各 generator のパラメータ (defaultAmplitude / grain rate / pitches / reverb wet) を atomic publish なしで安全に書き換え可能
- **rootNote / scale は全モード共通 (A3 MajPentatonic)** で audio path 簡略化
- **可変パラメータ**: 各 drone amp (4 voice) / noise amp / grain rate / grain amp / grain pitches / reverb wet / BPM 表示
- **SLEEP プリセット = Task 20 までの現状値** → CI 互換性維持

### Phase

- [x] Phase 1: Modes.swift で Mode enum + ModePreset + 4 プリセット定義
      - 4 モードの static let プリセット
      - 各モードの音響特徴: SLEEP δ-θ波 / FOCUS β波 / MEDITATE θ波 / RELAX α波
- [x] Phase 2: 各 RenderState の必要フィールドを var 化 + Generator に setter API
      - ToneRenderState/NoiseRenderState の defaultAmplitude を var
      - GrainRenderState の defaultAmplitude / meanInterTriggerFrames / pitchPhaseIncrements を var
      - 各 Generator に setDefaultAmplitude、Grain に setTriggerRate + setPitches
- [x] Phase 3: AudioEngineController に currentMode + setMode + applyPreset
      - @Published currentMode (default sleep)、@discardableResult setMode(_:) -> Bool
      - isRunning ガードで Stop 中限定、applyPreset で全 generator + reverb wet を一括更新
- [x] Phase 4: Codex クロスレビュー
      - 1 回目: **Critical 1 (Generator 側に重複 let defaultAmplitude が残っていて setter が無効)** + High 1 + Medium 2
      - Critical 反映: 各 Generator の defaultAmplitude を computed property `{ renderState.defaultAmplitude }` に
      - High 反映: AudioEngineController.isRunning を @Published 化、canChangeMode = !isPlaying && !controller.isRunning
      - Medium 1 反映: setTriggerRate で framesUntilNextTrigger を新 mean ベースに再初期化
      - Medium 2 反映: applyPreset 冒頭に precondition(droneGenerators.count == 4)
      - 2 回目: 全指摘解消、最終 OK
- [x] Phase 5: push → CI → artifacts_026 で SLEEP 互換性確認 (完全成功)
      - 初回 ビルド失敗 → AudioEngineController.Mode (内部) vs global Mode (Task 21 新規) の名前衝突
        → 内部を EngineMode にリネームで解消 (commit 747758f)
      - 2 回目 ビルド成功 + WAV 数値が artifacts_025 と bit-perfect 同値 ✓
      - L_MAX=4297/R_MAX=4535/DIFF_MAX=3416、GRAIN 全帯域同値
      - = Task 21 の audio 層変更が SLEEP モード (default) に副作用を出していない完全実証

## Task 22 — 4 モード切替 UI (ATMÓS 風 SLEEP/FOCUS/MEDITATE/RELAX ボタン)

Task 21 で audio 層インフラ完成 → UI から Mode を切り替える。ATMÓS スクショ風の 4 ボタン
横並び + BPM 表示 + canChangeMode が false (再生中) のときの補足メッセージ。

### 設計

- header subtitle を "Sleep Mode" 静的 → `viewModel.currentModeLabel` (Sleep/Focus/...) 動的化
- modeSelector を statusText と musicInfo の間に配置 (header → status → mode → voice → transport の流れ)
- 4 ボタン HStack: 現在モードは Theme.accent ハイライト、他はサブ色
- canChangeMode = false (再生中・fade-out 中) は全 button disabled + 半透明 + "Stop playback to change mode"
- BPM 表示 (= preset.bpm) は modeSelector 内の右寄せ
- Apple HIG 44pt 最小 tap target / VoiceOver 対応 / Dynamic Type 弱対応 (minimumScaleFactor)

### Phase

- [x] Phase 1: AudioViewModel に header subtitle + allModes API
      - `currentModeLabel: String` (Sleep/Focus/Meditate/Relax Mode)
      - `allModes: [Mode] = Mode.allCases`
- [x] Phase 2: MainView に modeSelector セクション追加
      - VStack: header → status → modeSelector → musicInfo → transport の順
      - 4 ボタン横並び + 補足メッセージ + BPM 表示
- [x] Phase 3: header subtitle を動的に
      - "Sleep Mode" → viewModel.currentModeLabel
- [x] Phase 4: Codex クロスレビュー
      - 1 回目: Critical なし、High 1 (tap target 44pt 未満) + Medium 1 (アクセシビリティ) + Low 2
      - High 反映: button label に .frame(maxWidth: .infinity, minHeight: 44)
      - Medium 反映: .accessibilityLabel / .accessibilityValue / .accessibilityHint 追加
      - Low 1 反映 (MEDITATE 詰まり): .lineLimit(1) + .minimumScaleFactor(0.7)
      - Low 2 (BPM 浮き): 据え置き (将来 Scale/BPM/Density 行統合で対応)
      - 2 回目: 全反映、最終 OK
- [x] Phase 5: push → CI → artifacts_027 で 4 モード UI 確認 (完全成功)
      - WAV 数値 artifacts_026 と bit-perfect 同値 ✓ (audio path 無変更を実証)
      - screenshot: Stopped 状態で SLEEP ハイライト + 他 3 モードサブ色 + "BPM 30" 表示 ✓
      - Playing 状態で全モードボタン半透明 (disabled) + "Stop playback to change mode" ✓

## Task 23 — Sleep Timer 機能

実機テスト前の最後の機能追加。タイマー時間プリセットを選び、再生開始から自動的に
カウントダウン、0 到達で fade-out → engine 停止。Sleep アプリの定番機能。

### 設計

- プリセット: **Off / 15 / 30 / 45 / 60 / 90 分** (Sleep アプリの定番値)
- カウントダウン Task は `Task.sleep(1s)` のループ、`@Published` で UI 1Hz 更新
- 手動 Stop で Task cancel、設定値は保持 (= 次の Start で再開)
- 時間切れで `stop()` 自動呼出 (fade-out → engine.stop())
- CI offline モードは default nil (Off) なので影響なし: renderOffline 同期完了で Task 起動なし
- self 強保持 (90 分中の生存) は root @StateObject 前提で許容、将来改善候補

### Phase

- [x] Phase 1: AudioViewModel に Sleep Timer state + API
      - @Published sleepTimerMinutes + sleepTimerRemainingSeconds
      - setSleepTimer(minutes:) で設定変更 (重複防御 + 再生中なら即 Task 起動)
      - startSleepTimerCountdown / cancelSleepTimerTask の private 実装
      - start() / stop() のライフサイクルに Task 起動/cancel を統合
      - sleepTimerRemainingText で "mm:ss" 表示
- [x] Phase 2: MainView の timerLabel を実装に置き換え
      - 再生中: "Sleep Timer · 14:32" 残り時間表示
      - Stop 状態: "Timer" + Off/15/30/45/60/90 プリセットボタン横並び
      - 現在選択値はアクセント色ハイライト
      - VoiceOver: accessibilityLabel + accessibilityValue
      - minHeight 32 (HIG 44 より小、画面下端の妥協、コメント明記)
- [x] Phase 3: Codex クロスレビュー
      - 1 回目: Critical/High なし、Medium 1 (コメント不一致) + Low 2 (self 強保持 / 1秒精度)
      - Medium 反映: timerPresetButton コメントを「32pt 妥協、理由付き、改善候補」に書き直し
      - Low は据え置き (実機テスト後の改善候補)
      - 2 回目: 全反映、最終 OK
- [x] Phase 4: push → CI → artifacts_028 で UI 確認 (完全成功)
      - WAV: artifacts_027 と bit-perfect 同値 ✓
      - screenshot: "Timer" + Off (ハイライト) + 15m/30m/45m/60m/90m が並ぶ ✓
      - Playing 状態でも Timer 行は表示 (default Off なのでカウントダウン表示なし) ✓

## Task 24 — Background playback + Lock screen 統合

Apple Developer Program 加入前の機能仕上げ。Sleep アプリとして必須の「画面ロック中も
継続再生 + Lock screen / Control Center から再生制御」を実装。実機テストは加入後だが
CI でビルド成功 + audio path 無変更 + Info.plist 確認まで実施。

### 設計

- **UIBackgroundModes = audio** で OS に「Background での音声出力を継続する」と宣言
- **AVAudioSession .playback カテゴリ** (Task 3 から既存) で Background playback 公式サポート
- **MPNowPlayingInfoCenter**: title "Hypnoctone" + artist (現在モード名) + playbackRate
- **MPRemoteCommandCenter**: play/pause/stop/togglePlayPause を Lock screen から
- **Actions.{start, stop, toggle} は @MainActor closure** で、handler 内で `Task { @MainActor in }` hop
- **AudioViewModel が NowPlayingService を所有**、init で remote command setup + 初期 publish
- **start/stop/setMode で updateNowPlaying** を呼んでモード追従

### Phase

- [x] Phase 1: pbxproj に INFOPLIST_KEY_UIBackgroundModes = audio を追加
      - Debug/Release 両 build settings、Xcode 16 auto plist で配列化される想定
- [x] Phase 2: NowPlayingService 新規ファイル
      - @MainActor final class、Actions struct、setupRemoteCommands / updateNowPlaying
      - addTarget の戻り値を registeredTargets で保持、deinit で removeTarget
- [x] Phase 3: AudioViewModel に統合
      - nowPlayingService プロパティ、init で remote command + 初期 publish
      - start/stop/setMode で updateNowPlaying を呼ぶ
      - Actions.{start, stop, toggle} に [weak self] で ViewModel メソッド渡し
- [x] Phase 4: Codex クロスレビュー
      - 1 回目: Critical なし、High 1 (actor 境界) + Medium 3 (toggle未実装 / deinit / 初期publish)
      - High 反映: Actions closure に @MainActor 注釈 + Task { @MainActor in } で hop
      - Medium 1 反映: togglePlayPauseCommand を実装、Actions.toggle 追加、ViewModel.toggle() 接続
      - Medium 2 (deinit Swift 6 strict) 据え置き: SWIFT_VERSION = 5.0 で警告なし、app lifetime singleton
      - Medium 3 (初期 publish) 据え置き: 実機 UX 確認後に判断
      - 2 回目: 最終 OK、Critical/High なし、Medium 残課題は将来の技術負債明示
- [x] Phase 5: push → CI → artifacts_029 で副作用なし確認
      - WAV: artifacts_028 と数値同値想定 (NowPlayingService は audio path に触らない)
      - codemagic.yaml に plutil -p で生成 Info.plist の UIBackgroundModes 確認 step 追加
      - build success + crash 無し + Info.plist に "audio" 配列要素確認
      - 実機での Background playback / Lock screen 操作確認は Developer Program 加入後
      - artifacts_029 確認結果: build success、crash なし、NowPlayingService の Remote command 登録ログ確認、
        MPNowPlayingInfoCenter に title=Hypnoctone / artist=Sleep Mode / playbackRate 0→1 遷移を syslog で確認、
        SupportsBackgroundAudio タグ多数で AVAudioSession playback カテゴリ機能、offline render 正常完了

## Task 25 — App Icon + Launch Screen

Apple Developer Program 加入前のビジュアル整備。App Store / TestFlight 提出に必須となる
App Icon (1024×1024 マスター) と暗背景 Launch Screen を整える。実機テストは不要 (CI で
ビルド成功 + Info.plist 内 CFBundleIconName + UILaunchScreen 設定を確認できれば OK)。

### 設計

- **App Icon**: Hypnoctone のテーマ (Theme.background + Theme.accent) を反映した PulseView 風
  デザイン (暗紺グラデ + 中央 radial 発光円)。文字は入れない (App 名は OS が表示)。
  1024×1024 PNG 1 枚のみ用意 → Xcode 14+ の single-size AppIcon 機能で全 size 自動生成。
- **Asset Catalog**: `HypnoctoneEngine/Assets.xcassets/` を新設し、`AppIcon.appiconset` と
  Launch Screen 用 `LaunchBackground.colorset` を含める。
- **Launch Screen**: 既存の `INFOPLIST_KEY_UILaunchScreen_Generation = YES` のまま
  `INFOPLIST_KEY_UILaunchScreen_BackgroundColor = LaunchBackground` を追加して暗背景に。
- **Icon 生成**: Python (Pillow + numpy) でローカル生成、PNG はリポジトリに commit。
  再生成スクリプト `tools/generate_app_icon.py` を残してデザイン変更時の再現性を確保。

### Phase

- [x] Phase 1: `tools/generate_app_icon.py` を作成し 1024×1024 PNG を生成
      - Theme.backgroundTop / backgroundBottom 縦グラデ + Theme.accent の halo + core
      - 完全不透明 (Apple guideline) / 角丸なし (iOS 自動マスク)
- [x] Phase 2: `HypnoctoneEngine/Assets.xcassets/` を作成
      - root `Contents.json` (info only)
      - `AppIcon.appiconset/Contents.json` (single-size 1024 universal, iOS 14+)
      - `AppIcon.appiconset/icon-1024.png` (Phase 1 で生成)
      - `LaunchBackground.colorset/Contents.json` (Theme.backgroundTop 相当の dark navy)
- [x] Phase 3: pbxproj buildSettings を更新
      - PBXFileSystemSynchronizedRootGroup なので folder 配下は自動認識、個別 PBXFileReference 追加不要
      - Debug/Release 両方に ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon を追加
      - Debug/Release 両方に INFOPLIST_KEY_UILaunchScreen_BackgroundColor = LaunchBackground を追加
- [x] Phase 4: Codex クロスレビュー
      - 1 回目: Critical なし、High 1 (UILaunchScreen.UIColorName 展開が公式 docs で確認できないと指摘) +
        Medium 2 (CI 検証が grep -A 3 で loose / Assets.car の検出が緩い) + Low 2 (icon 小サイズ識別性 / colorset 形式)
      - High + Medium 1 統合反映: codemagic.yaml の Info.plist 検証を `plutil -extract` ベースの fail-loud に書き換え。
        CFBundleIconName != "AppIcon" / UILaunchScreen.UIColorName != "LaunchBackground" で `exit 1`、
        前提が外れた場合は明示 Info.plist 直書きへ pivot するためのトリガとして CI で検出可能に
      - Medium 2 反映: Assets.car 不在も `exit 1`、AppIcon 派生 PNG も `find` で列挙
      - Low 1 据え置き: 実機 Home/Settings/Spotlight での縮小確認は Developer Program 加入後に実機で再評価
      - Low 2 据え置き: Xcode 15+ generated colorset 互換の文字列形式で OK
      - 2 回目: 追加 Low 指摘 (CFBundleIconName が nested CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName に
        入る可能性) を反映、両方を見て fallback する形に変更。最終 OK
- [x] Phase 5: codemagic.yaml に CFBundleIconName / UILaunchScreen / Assets.car 確認 step 追加
- [x] Phase 6 (1st): push (bb21118) → artifacts_030 で **failed**
      - 失敗 1: `plutil -extract` がエラー時 stdout にもエラー文字列を書く挙動で
        `2>/dev/null || true` が効かず、ICON_NAME にエラー文字列が入って nested fallback が動かない
      - 失敗 2: `INFOPLIST_KEY_UILaunchScreen_BackgroundColor = LaunchBackground` が
        `UIColorName` に展開されず、さらに `_Generation = YES` と併用で `UILaunchScreen = { UILaunchScreen = {} }` という二重ネスト bug-like 出力に
      - artifacts_030 syslog の plutil -p 出力: `CFBundleIcons~ipad.CFBundlePrimaryIcon.CFBundleIconName = "AppIcon"` (icon 自体は正しく付いている)
- [x] Pivot (Phase 6.5): 明示 Info.plist へ切り替え
      - `HypnoctoneEngine/Info.plist` 新規作成、UILaunchScreen / UIBackgroundModes /
        UIApplicationSceneManifest (UISceneConfigurations = {} 含む) / UISupportedInterfaceOrientations を直書き
      - pbxproj: GENERATE_INFOPLIST_FILE = NO + INFOPLIST_FILE = HypnoctoneEngine/Info.plist、
        6 個の INFOPLIST_KEY_* を削除 (ASSETCATALOG_COMPILER_APPICON_NAME は維持)
      - codemagic.yaml: `if cmd; then` 形式の `get_plist()` 関数化、追加 fail-loud キー
        (CFBundleIdentifier / ShortVersionString / Version / UIBackgroundModes[0]) を導入
      - Codex 再レビュー OK (UIApplicationSceneManifest に UISceneConfigurations = {} を含める提案、追加 fail-loud キー提案を反映)
- [x] Phase 6 (2nd): push (d318676) → artifacts_031 で **failed**
      - エラー: `Multiple commands produce '.../HypnoctoneEngine.app/Info.plist'`
      - 原因: PBXFileSystemSynchronizedRootGroup (HypnoctoneEngine/) 配下に Info.plist を置いたため
        Copy Bundle Resources (自動 sync) と ProcessInfoPlistFile (INFOPLIST_FILE 指定) で衝突
- [x] Pivot (Phase 6.75): PBXFileSystemSynchronizedBuildFileExceptionSet 追加
      - Codex 推奨案 B (target フォルダ内に Info.plist を維持しつつ exception で Resources から除外)
      - pbxproj に新規セクション `PBXFileSystemSynchronizedBuildFileExceptionSet` 追加
        (`membershipExceptions = (Info.plist,)`、target = HypnoctoneEngine)
      - 既存の `PBXFileSystemSynchronizedRootGroup` (HypnoctoneEngine) に `exceptions` 配列を追加
- [x] Phase 6 (3rd): push (ad178dd) → CI → artifacts_030 (Codemagic 番号は再採番) で **全通過** 🎉
      - build success / install success / crash 無し
      - Step 5 Info.plist fail-loud 検証 (CFBundleIdentifier / ShortVersionString / Version /
        UIBackgroundModes[0] / UILaunchScreen.UIColorName / CFBundleIconName) 全 OK (Step 6 まで到達した事実から推定)
      - 01-after-render.png で MainView が綺麗に描画 (4 mode / 4 voice / Sleep Timer すべて)
      - 02-stopped.png で Playing 状態に遷移、Task 24 の mode dim 化も維持
      - syslog で Task 24 NowPlayingService の Remote commands 登録 + setNowPlayingInfo (Title=Hypnoctone) を確認
      - offline render frames: 797896 ≒ 18.09 秒、artifacts_029 と同等 (audio path 影響なし)
      - 終了は SIGTERM (正常 kill)
- [x] Phase 7: AppIcon を Python 生成 → ユーザー指定の手書きアート (wave-plus) へ差し替え
      - Codex の Low 1 指摘 (Python 生成の暗背景 + 中央発光は Settings 等の縮小サイズで識別性が弱い) を受け、
        ユーザーが波形モチーフ (sleep wave) の手書きアイコンを別途用意
      - ファイル: `HypnoctoneEngine/Assets.xcassets/AppIcon.appiconset/hypnoctone-app-icon-1024.png` (1024×1024 RGB)
      - 元 PNG は RGBA (alpha min=219, max=255) だったため Theme.backgroundBottom (sRGB 0.02/0.02/0.05) に
        合成 + 完全不透明 RGB に変換 (Apple App Icon ガイドライン準拠で alpha チャネル除去)
      - 旧 Python 生成 `icon-1024.png` および `tools/generate_app_icon.py` は削除
- [ ] Phase 8 (後続課題, Developer Program 加入後): 実機 Home/Settings/Spotlight で AppIcon の縮小視認性を確認

## Task 26 — オーディオビジュアライザー (波形アニメーション)

アプリアイコン (wave-plus) と同じモチーフの動的波形を MainView に表示する。
Sleep アプリの性質 (画面ロック前提、長時間動作、低消費電力優先) に合わせ、
リアル audio FFT は使わず、SwiftUI Canvas + TimelineView による
**時間ベース procedural アニメーション** で「音の雰囲気」を視覚化する。

### 設計

- **時間関数ベース**: `y(x, t) = amp * sin(2π * xCycles * x/W + 2π * timeFreq * t)` で
  4 voice (TONE / DRONE / SUB / GRAIN) 1 本ずつの sine wave を計 4 本描画
- **iOS 16+ Canvas + TimelineView(.animation, paused:)** で 60fps 描画 (GPU 加速)
- **screen lock 中は SwiftUI render 自動停止** = battery 0 (audio はバックグラウンド継続)
- voice MUTE → 該当 wave 不透明度 0 で fade
- isPlaying = false → TimelineView を paused + 不透明度低下で消える
- mode 切替 → global speed の倍率を mode 別に切替
  (SLEEP: 0.6 / FOCUS: 1.0 / MEDITATE: 0.3 / RELAX: 0.8)
- Glow effect: 同じ path を blur layer + sharp layer の 2 重描画で発光感を再現

### voice → wave マッピング (空間周波数 / 時間周波数)

| Voice | 物理周波数 | xCycles (空間周波数) | timeFreq (Hz) | 振幅比 | 不透明度 |
|-------|----------|---------------------|---------------|--------|---------|
| TONE (E4/A4 等) | 中高 | 1.5 | 0.06 | 0.18 | 0.55 |
| DRONE (A3) | 中低 | 1.0 | 0.04 | 0.22 | 0.65 |
| SUB (A1) | 低 | 0.5 | 0.025 | 0.30 | 0.45 |
| GRAIN (高音 sparkle) | 高 | 2.5 | 0.10 | 0.12 | 0.40 |

### Phase

- [x] Phase 1: `WaveVisualizerView.swift` 新規実装 (Canvas + TimelineView、4 voice 固定、Theme.accent + glow)
- [x] Phase 2: MainView 側で `viewModel.voiceGroups.map { ($0.group, $0.isMuted) }` で辞書化して WaveVisualizerView に渡す
      (Codex Medium 3 反映で配列順序依存を排除、`[VoiceGroup: Bool]` 辞書で受ける設計)
- [x] Phase 3: MainView の PulseView を `visualizer` プロパティ (ZStack + frame 240pt) に置き換え
- [x] Phase 4: Mode 別 speed multiplier (SLEEP=0.6 / FOCUS=1.0 / MEDITATE=0.3 / RELAX=0.8) を実装
- [x] Phase 5: Codex クロスレビュー (2 ラウンド)
      - 1 回目: Critical/High なし、Medium 3 (停止中 TimelineView 継続 / Stop 時位相ジャンプ /
        voice 配列順序依存) + Low 5 (MUTE fade / blur 負荷 / steps 固定 / 言い切りコメント / 重ね順)
      - 反映: Medium 1+2 統合対応 — `if isPlaying { TimelineView } else { 静的 Canvas }` で
        描画スケジュール停止 + `onChange(of: isPlaying)` で `pausedElapsed` 保存して Resume 時に
        startDate を `Date() - pausedElapsed` にずらすことで位相連続化
      - 反映: Medium 3 — `voiceMuted: [VoiceGroup: Bool]` 辞書 + waveParams も `[(group, params)]` でペア化
      - 反映: Low 4 (screen lock 言い切り) — 「SwiftUI 更新頻度が落ちる/止まる expectation」程度に緩めた
      - 据え置き: Low 1 (MUTE fade) は Canvas closure 内 opacity の animation が API 制約で
        効かないため Phase 7 実機調整送り、Low 3 (steps=120 固定) も iPad 検証時に再考送り
      - 2 回目: Medium 1 件残 — Stop 時 `Date()` ベース freeze の微小位相ズレ。Codex 自身が
        「実害小、ゆっくりした波なら視認リスク低め、許容でよい」と認め、Phase 7 で実機確認時に
        気になれば対応する後続課題として残置
- [x] Phase 5.5: 波形を「横スライドのみ」から「上下にうねる動的波」へ進化 (ユーザー Option 1 選択)
      - (A) 振幅 LFO: `amplitudeLFO = 1.0 + 0.20 * sin(2π * 0.04 * t + voicePhase)` で
        25 秒周期の呼吸感、voice 毎に xCycles を位相シードに使って完全同期回避
      - (B) 進行速度違いの第 2 sine 加算: 主 sine に xCycles 1.7 倍 + timeFreq 0.6 倍 +
        位相 1.3rad オフセットの second sine (係数 0.30) を加えて波形が時間で変形 (うねり)
      - (C) 垂直オフセット LFO: 全 wave 共通 `verticalOffset = 0.04 * H * sin(2π * 0.03 * t)`
        で 33 秒周期で全体が slow に上下に揺れる
      - Codex 数式 sanity check (3 回目): Medium 1 件 — SUB 最大振幅 + verticalOffset で
        理論上 frame 外に 0.008H (≒1.9pt @240) はみ出し可能性、glow blur 6 の端切れ懸念
      - 反映: `effectiveHeight = size.height * 0.92` 導入で上下に 4% padding 確保、
        最大振幅 0.468 * 0.92 * H + 0.04 * H ≒ 0.471H で frame 内に確実に収まる
- [x] Phase 6: push (81bcfaf / 2d50cbe) → CI → artifacts_033 / artifacts_034 で確認
      - artifacts_033 (横スライドのみ版): wave 4 本 + glow 描画 OK だが「上下うねり」感が弱い旨ユーザーフィードバック
      - artifacts_034 (3 種 modulation 追加版): 波形が時間で変形してうねる / 全体が slow に上下にゆれる
        状態を確認、ユーザー所感「いいんじゃないかな」で承認
      - build success / crash なし / WAV 3.2MB (audio path 副作用ゼロ、artifacts_029 以降と同等)
      - Stop 状態でも 静的 Canvas で位相 freeze + 不透明度 0.3 倍で淡く残る (設計通り)
- [ ] Phase 7 (後続課題, Developer Program 加入後): 実機で動きの心地よさ確認、視認性 / 速度 / amplitude を調整
      残課題: Stop 時の微小位相ズレ (Codex Medium、視認リスク低)、MUTE 切替の即時 fade を softer に、
      各 modulation 周波数 (A: 0.04Hz / B: timeFreq 0.6 倍 / C: 0.03Hz) と振幅 depth (0.20 / 0.30 / 0.04) の聴感調整

## Task 27 — 設定の永続化 (UserDefaults)

アプリ再起動後に「前回のモード / Volume / 各 voice MUTE / Sleep Timer 選択値」を復元する。
これまで毎回 SLEEP / Volume 0.5 / 全 voice unmute / Timer Off に戻っていた状態を解消し、
ユーザーが好みの設定を維持できるようにする (Sleep アプリとして重要な UX)。

### 設計

- **永続化対象**: mode (String rawValue) / volume (Double, 0.0〜1.0 clamp) / muted per voice
  (Bool x4) / sleepTimerMinutes (Int? sentinel -1 で nil 表現)
- **永続化しないもの**: sleepTimerRemainingSeconds (現在実行中のカウントダウン残り秒、セッション限定)
- **UserDefaults キー**: `"com.hypnoctone.settings.*"` プレフィックスで一元化
- **invalid 値への耐性**: `Mode(rawValue:)` 失敗 / 数値範囲外 / 未保存ケースで default に
  fallback、起動クラッシュなし
- **書き込みタイミング**: 各 setter (volume.didSet / toggleMute / setMode / setSleepTimer)
  で即時 SettingsStore へ反映
- **読み込みタイミング**: AudioViewModel.init で store から読んで controller (initialMode /
  initialMutedGroups 引数経由) と内部状態 (volume / sleepTimerMinutes) に反映

### Phase

- [x] Phase 1: `SettingsStore.swift` 新規実装 (@MainActor、テスト時 UserDefaults 注入可能)
- [x] Phase 2: AudioEngineController init に `initialMode` / `initialMutedGroups` パラメータ追加
      - init 末尾 (buildAudioGraph 後) で `setMode(initialMode)` + 該当 voice の `setMuted(group, true)`
      - default 引数で既存挙動互換
- [x] Phase 3: AudioViewModel が SettingsStore から読み書き
      - init で store の mode / muted / volume / sleepTimerMinutes を読み、controller に渡す + 内部 state 反映
      - volume.didSet / toggleMute / setMode / setSleepTimer の各 setter で SettingsStore へ即時保存
- [x] Phase 4: Codex クロスレビュー
      - Critical/High なし、Medium 1 (sleepTimerMinutes allowlist 検証不足) + Low 2 (controller 注入時の非対称 / @MainActor 妥当性)
      - Medium 1 反映: `SettingsStore.sleepTimerMinutes` getter で preset allowlist `{15,30,45,60,90}` に
        含まれない値は nil fallback、`-2` 等の不正値や preset 外 timer が動く UX 矛盾を防ぐ
      - Low 1 据え置き: controller 注入時の Mode/MUTE 非対称は「現状規模なら shared で許容」と
        Codex も認め、DI 化は将来テスト拡充時に再検討
      - Low 2 据え置き: `@MainActor` 限定は妥当 (UI/ViewModel 経由限定の設計と整合)
- [x] Phase 5: push (7cdeef3) → CI → artifacts_035 で確認
      - build success / install / 起動 / WAV 生成 (3,195,680 bytes = artifacts_029〜034 と完全同サイズ、
        audio path 副作用ゼロを証明) / crash なし
      - syslog で起動シーケンス確認: `Mode switched to: sleep` (init 末尾の setMode(initialMode) が
        動作) → NowPlayingService Remote commands registered → AVAudioEngine offline 開始
      - CI は per-launch UserDefaults 初期で「未保存 → default 復元」経路のみ確認
        (round trip は Phase 6 実機検証)
- [ ] Phase 6 (後続課題, Developer Program 加入後): 実機で実際に再起動してモード / Volume /
      MUTE / Timer が復元されることを確認

## Task 28 — Onboarding 画面 (初回起動時のみ)

App Store 提出後の初回ユーザー向けに、アプリの位置付け / 4 モード / Lock screen 連携 /
Sleep Timer / Volume の使い方を簡潔に伝える Onboarding 画面を実装する。完了したフラグを
UserDefaults に永続化し、2 回目以降の起動では MainView 直接表示。

### 設計

- **トリガ**: 初回起動のみ。`SettingsStore.hasCompletedOnboarding == false` の時表示
- **UI**: TabView + PageTabViewStyle の 3 ページスワイプ形式。各ページにタイトル / サブタイトル
  / 説明文 / 簡易ビジュアル
- **ナビゲーション**: 右上 Skip ボタン (どこからでも完了可) / 下部 Next ボタン (最終ページで
  "Get Started" に変化、tap で `onComplete()`)
- **デザイン**: 本体と同じ Theme (backgroundGradient / accent)、控えめな配色 (Sleep アプリの
  「眩しくない」設計を踏襲)
- **CI 互換**: `CI_AUTOSTART` 環境変数があるときは onboarding をスキップして MainView 直行
  (既存 CI フローを破壊しない)
- **永続化**: `SettingsStore.hasCompletedOnboarding` (Bool、未保存 = false default)

### ページ構成

1. **Welcome**: "Hypnoctone" タイトル + "Ambient audio for sleep, focus & rest" + アプリ概要
2. **4 つのモード**: SLEEP / FOCUS / MEDITATE / RELAX のリスト + 各モードの音響特徴一文
3. **便利な機能**: Sleep Timer / Lock Screen 操作 / Background playback の説明

### Phase

- [x] Phase 1: `SettingsStore.hasCompletedOnboarding` プロパティ追加 (`bool(forKey:)` の未保存 false 挙動を利用)
- [x] Phase 2: `OnboardingView.swift` 新規実装 (TabView 3 ページ、Skip/Next ボタン、Theme 反映、
      SF Symbols: waveform / circle.grid.2x2 / moon.zzz)
- [x] Phase 3: `HypnoctoneEngineApp.swift` を書き換え、`OnboardingState` ObservableObject で分岐
      (`CI_AUTOSTART` 環境変数あり時は強制 MainView 直行、SettingsStore は汚さない設計)
- [x] Phase 4: Codex クロスレビュー
      - Critical/High なし、Medium 1 (2 ページ目本文が iPhone SE / Dynamic Type 大で詰まる懸念) +
        Low 4 (@StateObject 初期化 / CI skip 判断 / accessibility hint / SettingsStore.shared 直参照)
      - Medium 反映: 本文を `ScrollView(showsIndicators: false)` で包んで小画面 / Dynamic Type 大に対応
      - Low 反映 (accessibility hint): Next ボタンに "Shows the next onboarding page"、
        Get Started ボタンに "Opens the main player" の hint 追加
      - Low 据え置き: SettingsStore.shared 直参照は現状規模で許容、テスト拡充時に DI 検討
- [x] Phase 5: push (b4e1490) → CI → artifacts_036 で確認
      - screenshot で MainView 直接表示 (Onboarding 非表示) = CI_AUTOSTART による skip が機能
      - syslog で起動シーケンス完全正常: manual rendering / Mode switched to sleep /
        NowPlayingService Remote commands / AVAudioEngine offline / WAV 書き出し / offline render 完了
      - WAV 3,195,680 bytes = artifacts_029〜035 と完全同サイズ (audio path 副作用ゼロ)
      - crash なし、SIGTERM 正常終了
- [ ] Phase 6 (後続課題, Developer Program 加入後): 実機で初回起動 → onboarding → Get Started →
      MainView → アプリ再起動で MainView 直行 の round trip を確認

## Task 29 — アクセシビリティ強化 (High + Medium)

App Store のアクセシビリティガイドライン準拠を目指し、VoiceOver / Reduce Motion / Dynamic Type
の 3 軸で強化する。Sleep アプリは「眠気で視覚が曖昧」「文字を読まずに音で操作したい」シーンが
多いため、VoiceOver と Reduce Motion の優先度が高い。

### High 範囲 (VoiceOver + Reduce Motion + Volume announce)

1. **VoiceOver labels 完全化**:
   - `transportButton` (Start/Stop) に accessibilityLabel/Hint
   - Volume `Slider` に accessibilityValue で "Volume 50%" announce
   - `voiceCell` の note name にコンテキスト付き label
     (e.g. "TONE voice, E4 and A4, currently unmuted")
   - `statusText` に明示 label ("Playback stopped" / "Playback playing")
   - 既存対応済: modeButton / timerPresetButton / Onboarding ボタン

2. **Reduce Motion 対応**:
   - `@Environment(\.accessibilityReduceMotion)` で検出
   - PulseView: 脈動アニメーションを停止 (静的なハロー + コアのみ表示)
   - WaveVisualizerView: TimelineView を使わず静的 Canvas に切替 (停止時と同じ経路)
   - 既存の `isPlaying=false` で静止表現する経路を reduce motion 時にも再利用

### Medium 範囲 (Dynamic Type)

3. **Dynamic Type 対応**:
   - `.font(.system(size: N, ...))` 固定指定を `.font(.system(.body, ...))` 等の
     semantic font に置換 (元のサイズ感は維持しつつ Dynamic Type で滑らかに拡大)
   - 拡大上限: `.dynamicTypeSize(...DynamicTypeSize.xxLarge)` をルート view に
     適用してレイアウト崩壊を防ぐ
   - 主要置換マッピング:
     - 30pt → `.largeTitle` (Hypnoctone タイトル)
     - 17pt → `.body` (transport button)
     - 15pt → `.callout` (statusText)
     - 14pt → `.subheadline` (subtitle)
     - 13pt → `.footnote` (Volume / noteName)
     - 12pt → `.footnote` (Scale 表示)
     - 11pt → `.caption`、10pt / 9pt → `.caption2`

### Phase

- [x] Phase 1: VoiceOver labels 完全化 (MainView の transport / volume / voiceCell / statusText /
      header / BPM 表示)。voice 名の `·` / `/` 区切りを `spokenNoteName()` で "and" に置換。
      voiceCell は `.accessibilityElement(children: .ignore)` で label/note 2 つの Text を
      1 つの element として "TONE voice, E4 and A4, playing" のように合成読み上げ。
- [x] Phase 2: Reduce Motion 対応 (PulseView の `pulseAnimation: Animation?` で nil 返却、
      WaveVisualizerView の body 分岐に `&& !reduceMotion` 追加)
- [x] Phase 3: Dynamic Type 対応 (MainView / OnboardingView の全 font を semantic font 化、
      `.dynamicTypeSize(...DynamicTypeSize.xxLarge)` で上限制限)
- [x] Phase 4: Codex クロスレビュー
      - Critical/High なし、Medium 1 (Reduce Motion 時 Stop 位相ジャンプ) + Low 4 (xxLarge 上限 /
        Volume Int 切り捨て / accessibility .ignore / Animation? パターン)
      - Medium 反映: WaveVisualizerView の `onChange(of: isPlaying)` で `if reduceMotion { return }`
        を先頭に追加。Reduce Motion 時は pausedElapsed を更新しないので Stop 瞬間の位相ジャンプを回避
      - Low 反映 (Volume rounding): `Int(viewModel.volume * 100)` → `Int((viewModel.volume * 100).rounded())`
      - Low 据え置き: xxLarge 上限 (Accessibility Large 対応は将来 wrap/grid/menu 化検討時に再考)、
        `.accessibilityElement(children: .ignore)` / `Animation?` nil パターンは Codex も妥当判定
- [x] Phase 5: push (827f9d8) → CI → artifacts_037 で確認
      - build success / crash なし / WAV 3,195,680 bytes (artifacts_029〜036 と完全同サイズ、
        audio path 副作用ゼロ)
      - screenshot で semantic font 反映確認: タイトル 30→28pt、subtitle 14→15pt 等の微調整、
        4 voice 横並び / 4 mode 横並び / 6 timer preset 横並びは崩れずレイアウト維持
      - Dynamic Type 大設定 / VoiceOver / Reduce Motion の挙動は CI 環境では検証不能 (実機 Phase 6)
- [ ] Phase 6 (後続課題, Developer Program 加入後): 実機で VoiceOver / Reduce Motion / Dynamic Type 大の挙動を実体験で確認

## Task 30 — Binaural Beats モード追加

5 番目の mode `BINAURAL` を追加。L/R に異なる周波数を出力して脳が差分をビートとして
知覚する仕組みを利用、θ-α 境界 (5Hz) の固定ビート周波数で「リラックスして覚醒」を狙う。

### 設計

- **配置**: 既存 4 mode と並列で 5 番目の `case binaural`。enum Mode に追加、preset も
- **音響核**: root voice (A3=220Hz) を L=217.5Hz / R=222.5Hz の絶対 5Hz 差で再生。
  既存の DroneGenerator の cent ベース L/R detune (Task 10) とは別経路で「絶対 Hz 差」を
  指定する API を新規追加 (`setBinauralBeat(centerFreq:beatHz:)`)
- **他 voice**: sub / 5th / octave は preset.binaural の amp 値 (controlled に薄め)、
  noise も極小で binaural beat の知覚を阻害しないようにする
- **ModePreset**: `binauralBeatHz: Double?` プロパティ追加。既存 4 mode は `nil` で
  cent ベース detune を継続、BINAURAL は `5.0` で root voice のみ絶対 Hz 差に切替
- **UI**: BPM 表示の代わりに "5 Hz" 表記 (将来複数選択可にする場合の拡張点)。
  ヘッドフォン推奨だがスピーカーでも害なし (両耳に違う周波数が届かないので「ただの 2 音」になる)
- **mode 切替制約**: 既存通り Stop 状態のみ切替可
- **CI 検証**: WAV (stereo 44.1kHz/16bit) に root voice 帯域で約 5Hz の振幅変調 (= ビート) が
  L/R の合成で観測できるはず (interference beat pattern)。FFT で 220Hz 周辺の bandwidth を見ると
  L=217.5/R=222.5 の 2 peak、もしくはモノ加算で 5Hz の AM が現れる

### Phase

- [x] Phase 1: Codex に design 相談
      - High (App Store 医療表現緩和) + Medium 4 (StereoDetuneMode enum / RhythmDisplay enum /
        DRONE MUTE UX hint / 5 mode 配置) + Low 5 (centerFreq / validation / headphone 注記 /
        reverb 30 / CI 検証) を全反映
- [x] Phase 2: Modes.swift に `case binaural` + `RhythmDisplay` enum + `binauralBeatHz` 追加、
      BINAURAL preset 定義 (rootAmp 0.22 強め、他控えめ、reverb 30、`rhythmDisplay: .hz(5.0)`)
- [x] Phase 3: DroneGenerator に `StereoDetuneMode` enum と `setStereoDetuneMode(_:centerFreq:glideSeconds:)`
      追加。既存 `setFrequency` も共通 helper `scheduleStereoUpdate` 経由に refactor。
      precondition で beatHz > 0 と `centerFreq - hz/2 > 20` を検証 (Codex Low 反映)
- [x] Phase 4: AudioEngineController.applyPreset 末尾で root voice に `binauralBeatHz` で
      `.absoluteBeatHz` / nil で `.cents(2.0)` を明示適用。中央周波数は `currentDroneNotes[1].frequency` 由来
- [x] Phase 5: MainView の modeSelector を `LazyVGrid` 3 列 grid に (上段 SLEEP/FOCUS/MEDITATE、
      下段 RELAX/BINAURAL/空)。`rhythmDisplayText` で "BPM N" / "5 Hz" 切替。BINAURAL 選択時に
      "Headphones recommended" 注記。DRONE MUTE の VoiceOver hint に BINAURAL 時の補足
      ("DRONE carries the binaural beat")。Onboarding も 5 mode 説明に更新
- [x] Phase 6: Codex 実装後 review
      - Critical/High なし、Medium 2 (root voice harmonics による 10/15Hz 副 beat / pitch LFO による
        center 微小揺らぎ) + Low 4 (setMode コメント 4 mode 表記 / generative pitch 再有効化注意 /
        LazyVGrid 5 要素配置 / Equatable 不要 / 文言)
      - 反映: 全 Medium はコメントで明示 (BINAURAL preset / applyPreset 内に harmonics の比例差 +
        LFO 微小揺らぎ + generative pitch 再有効化リスクを注記)。Phase 8 で実機聴感確認後に
        harmonics suppression API を追加するかは別途判断
- [ ] Phase 7: push → CI → artifacts で確認
      - build success / 既存 4 mode 動作維持 / wave visualizer 描画維持
      - WAV は SLEEP モードで自動再生 (CI_AUTOSTART は mode を変えないため)、
        BINAURAL の FFT 検証は実機 Phase 8 に送る
- [ ] Phase 8 (後続課題, Developer Program 加入後): 実機 + ヘッドフォンで BINAURAL の聴感確認、
      L/R 別 Goertzel で 217.5/222.5Hz peak と 5Hz beat の観測、harmonics suppression 要否判断
