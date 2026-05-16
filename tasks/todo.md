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
- [ ] Phase 5: push → Codemagic → artifacts_013 で雨音風 lowpass を実証
      - 期待: WAV stereo 維持、L/R 検査クリア、Drone 220/330/440 のピーク維持
      - 高域 (例 5000Hz, 8000Hz) の Goertzel mag が Task 11 比で大幅低下 = lowpass の証拠
      - crash 無し、クリッピング無し
