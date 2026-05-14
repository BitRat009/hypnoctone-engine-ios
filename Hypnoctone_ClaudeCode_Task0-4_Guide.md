# Hypnoctone / Claude Code 実装開始ガイド

## 1. プロジェクト概要

Hypnoctone は、録音素材やループ音源を使わず、リアルタイム音響合成によって Sleep 向けのアンビエント音を生成する iOS アプリのプロトタイプです。

初期段階では、完成アプリを作るのではなく、以下を確認することを目的とします。

- SwiftUI で最小UIを表示する
- AVAudioEngine / AVAudioSourceNode でリアルタイム生成音を鳴らす
- 音声ファイルを一切使わない構成を確認する
- UI と音響処理を分離する
- 今後の Sleep モード音質実装の土台を作る

---

## 2. プロジェクト情報

| 項目 | 内容 |
|---|---|
| 仮アプリ名 | Hypnoctone |
| 読み | ヒプノクトーン |
| Xcodeプロジェクト名 | HypnoctoneEngine |
| GitHubリポジトリ名 | hypnoctone-engine-ios |
| 対象OS | iOS 16以上 |
| UI | SwiftUI |
| 音響処理 | AVFoundation / AVAudioEngine / AVAudioSourceNode |

---

## 3. アプリ名の由来

Hypnoctone は以下の言葉を掛け合わせた造語です。

```text
Hypnos（眠りの神）
Nocturne（夜想曲）
Tone（音・音色）
```

睡眠、夜、音響生成を象徴する名称として使用します。

---

## 4. 初期プロトタイプの実装範囲

今回は **Task 0〜Task 4** までを実装します。

### Task 0: Xcodeプロジェクト作成

- SwiftUIベースのiOSアプリを作成
- iOS 16以上を対象
- Xcodeプロジェクト名は `HypnoctoneEngine`

### Task 1: 最小UI作成

- アプリ名表示
- Sleep Mode表示
- 再生状態表示
- Start / Stopボタン
- Volumeスライダー
- 中央の静かな円形パルス表示
- Timerは仮表示でよい

### Task 2: AudioEngineController作成

- UIと音響処理を分離する
- `AudioEngineController.swift` を作成
- `start()`
- `stop()`
- `setVolume(_ value: Float)`
- `isRunning` 管理

### Task 3: AVAudioSession設定

- `AVAudioSession` を `.playback` カテゴリで設定
- start時に有効化する
- エラー時はログを出す

### Task 4: AVAudioEngine + AVAudioSourceNodeでサイン波再生

- `AVAudioEngine` を使用
- `AVAudioSourceNode` を使用
- 440Hzのサイン波を小音量でリアルタイム生成
- 音声ファイル・録音素材・ループ素材は使わない

---

## 5. 今回実装しないもの

以下は今回の範囲外です。勝手に実装しないでください。

- DroneGenerator
- NoiseGenerator
- SlowModulator
- Reverb
- SleepPreset
- Sleep Timer
- Debug Panelの本実装
- WeatherKit
- 課金
- Android対応
- 完成版UI
- 複雑な音質調整

---

## 6. UIデザイン方針

HypnoctoneのUIは、音より前に出ないことを重視します。

### コンセプト

```text
夜の部屋で、静かに音が呼吸しているようなUI。
派手な演出や情報量を避け、眠りに入る直前でも眩しくなく、操作に迷わない。
```

### 方針

- ダークモード前提
- 背景は深い紺〜黒系
- 文字は低刺激な白〜青みのグレー
- アクセントは控えめな青紫
- 派手なアニメーションやネオン表現は避ける
- 睡眠前に見ても眩しくないUIにする
- 中央の円形パルスは6〜10秒周期でゆっくり動く程度
- 音に細かく反応するビジュアライザーにはしない

### 初期画面要素

```text
Hypnoctone
Sleep Mode

静かな円形パルス

Start / Stop

Volume

Timer: Off
```

---

## 7. 音響実装の重要ルール

AVAudioSourceNode の render block 内では、以下を行わないでください。

- ファイルアクセス
- ネットワークアクセス
- UI更新
- 重いオブジェクト生成
- ブロッキング処理
- メモリアロケーションの多発

今回の段階では、440Hzの小音量サイン波が実機で鳴れば成功です。

音質の完成度はまだ求めません。

---

## 8. 推奨ファイル構成

```text
HypnoctoneEngine/
  HypnoctoneEngineApp.swift
  MainView.swift
  AudioViewModel.swift
  AudioEngineController.swift
```

必要に応じて補助ファイルを追加しても構いませんが、今回の範囲を超えた設計にしすぎないでください。

---

## 9. Claude Code / Codex に渡す実装プロンプト

以下をそのまま Claude Code または Codex に渡してください。

```text
あなたはiOS / Swift / SwiftUI / AVFoundationに詳しい開発者です。

録音素材やループ音源を使わず、リアルタイム音響合成によってSleep向けのアンビエント音を生成するiOSアプリ「Hypnoctone」の初期プロトタイプを作ります。

プロジェクト情報:
- Xcodeプロジェクト名: HypnoctoneEngine
- 仮アプリ名: Hypnoctone
- GitHubリポジトリ名: hypnoctone-engine-ios

開発環境:
- iOS 16以上
- Swift
- SwiftUI
- AVFoundation
- AVAudioEngine
- AVAudioSourceNode

今回の実装範囲:
Task 0〜Task 4までを実装してください。

Task 0:
- Xcodeプロジェクトの初期構成

Task 1:
- SwiftUIの最小UI

Task 2:
- AudioEngineController作成

Task 3:
- AVAudioSession設定

Task 4:
- AVAudioEngine + AVAudioSourceNodeによる小音量のサイン波再生

重要方針:
- 音声ファイル、録音素材、ループ素材は一切使わない
- 音はAVAudioSourceNodeでリアルタイム生成する
- 今回はまず440Hzの小音量サイン波が鳴れば成功
- Sleepモード用のDroneGenerator、NoiseGenerator、Reverb、Timer、Debug Panelはまだ実装しない
- UIと音響処理を分離する
- ビルド可能な最小構成を優先する
- start / stop でクラッシュしない
- 音量は安全な小音量から始める
- AVAudioSourceNodeのrender block内で、ファイルアクセス、ネットワークアクセス、UI更新、重いオブジェクト生成、ブロッキング処理を行わない

UI要件:
- 画面タイトル: Hypnoctone
- モード表示: Sleep Mode
- 再生状態テキスト
- Start / Stopボタン
- Volumeスライダー
- 中央に静かな円形パルス表示
- Timerは仮表示でよい
- Debug Panel入口はまだ不要、または仮表示のみでよい

UIデザイン方針:
- 夜、眠り、静けさを感じる暗めのUI
- ダークモード前提
- 背景は深い紺〜黒系
- 文字は低刺激な白〜青みのグレー
- アクセントは控えめな青紫
- 派手なアニメーションやネオン表現は避ける
- 睡眠前に見ても眩しくないUIにする
- 中央の円形パルスは6〜10秒周期でゆっくり動く程度
- パルスは音に細かく反応するビジュアライザーではなく、再生中であることを静かに示す表現にする

音響要件:
- 440Hzのサイン波をAVAudioSourceNodeでリアルタイム生成する
- 音声ファイルは使わない
- 小音量で安全に鳴らす
- 音量スライダーでマスター音量を変更できる
- 停止ボタンで再生を停止できる
- この段階では厳密なフェード処理は未実装でもよいが、クリックノイズ対策を後で入れやすい構成にする

コード構成:
- MainView.swift
- AudioViewModel.swift
- AudioEngineController.swift
- 必要に応じて補助ファイルを作成する

AudioEngineController要件:
- AVAudioEngineを保持する
- AVAudioSourceNodeを使用する
- start()
- stop()
- setVolume(_ value: Float)
- isRunningを管理する
- AVAudioSessionを.playbackカテゴリで設定する
- エラー時はprintまたはLoggerで分かるようにする

完了条件:
- Xcodeでビルドできる
- iOSシミュレーターでUIが表示される
- 実機で再生ボタンを押すと小音量のサイン波が鳴る
- 停止ボタンで停止できる
- 音量スライダーで音量を変更できる
- 録音素材・音声ファイルを使っていない
- render block内に危険な処理がない
- 今回のタスク範囲外の機能を勝手に実装していない

今回実装しないもの:
- DroneGenerator
- NoiseGenerator
- SlowModulator
- Reverb
- SleepPreset
- Sleep Timer
- Debug Panelの本実装
- WeatherKit
- 課金
- Android対応

実装後、変更したファイル一覧と、実機確認で見るべきポイントを短くまとめてください。
```

---

## 10. Task 0〜4 実装前チェックリスト

```text
- Xcodeが利用できる
- iOS 16以上を対象にできる
- 実機テスト用のiPhoneがある
- 実機で音を出しても問題ない環境で確認する
- Gitリポジトリを作成する
- まずはサイン波再生までで止める
```

---

## 11. Task 0〜4 実装後チェックリスト

### UI

```text
- Hypnoctoneのタイトルが表示されている
- Sleep Modeが表示されている
- Start / Stopボタンがある
- Volumeスライダーがある
- 再生状態が分かる
- 中央パルスが眩しすぎない
```

### Audio

```text
- 実機で音が鳴る
- 音量が大きすぎない
- 音量スライダーが効く
- Stopで止まる
- 再度Startしても鳴る
- 音声ファイルを使っていない
```

### Code

```text
- UIと音響処理が分離されている
- AudioEngineControllerに処理がまとまっている
- render block内に危険な処理がない
- 次のTask 5以降でフェード処理を追加しやすい
```

---

## 12. 次の工程

Task 0〜4が完了したら、次は以下に進みます。

```text
Task 5: フェードイン / フェードアウト
Task 6: DroneGenerator分離
Task 7: NoiseGenerator追加
Task 8: Layer Mixer実装
```
