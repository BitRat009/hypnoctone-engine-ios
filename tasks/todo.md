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
- [x] GitHub にリポジトリを push（https://github.com/BitRat009/hypnoctone-engine-ios, private）
- [x] **CI でビルド検証成功** — 手書き pbxproj が Xcode 16 で実ビルド可能と実証（run #1, 41s）
- [ ] 対話的確認が必要なとき: 時間課金のクラウド Mac（MacinCloud / Scaleway 等）か
      Codemagic 無料枠でシミュレータ実行・UI/音の確認
- [ ] 実機確認が必要になったら: Apple Developer Program + TestFlight 経由で自分の iPhone に配信
