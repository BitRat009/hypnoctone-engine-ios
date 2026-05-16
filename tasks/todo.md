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
- [ ] v2 を push → Codemagic で実走 → artifacts_002 を回収して真っ白原因を特定
- [ ] 原因に応じて修正（cold start 遅延 → さらに sleep / クラッシュ → コード修正）
- [ ] 音声検証は別途: AudioEngineController に offline render で短い WAV を吐く開発専用フックを追加し、CI_AUTOSTART 時に artifacts へ書き出す（v3）
- [ ] 実機確認が必要になったら: Apple Developer Program + TestFlight 経由で自分の iPhone に配信
