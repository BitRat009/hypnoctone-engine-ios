# TestFlight 配信パイプライン セットアップ手順 (Task 32)

Apple Developer Program (ADP) 加入後に、Mac 不要で Hypnoctone を TestFlight 経由で
自分の iPhone に配信するための設定手順。Codemagic がクラウド macOS で
archive / upload を実行するので、開発機が Windows でも完結する。

## 前提

- [ ] Apple Developer Program 加入完了 ($99/年、個人)
- [ ] Apple ID で 2 段階認証 (2FA) 有効化済み
- [ ] Codemagic アカウント開設済み + GitHub リポジトリ連携済み (既存 CI フローで稼働中)
- [ ] iPhone に TestFlight アプリ (App Store から無料) インストール済み

## ステップ 1: App Store Connect で App 作成

1. https://appstoreconnect.apple.com にログイン
2. **My Apps** → 左上の `+` → **New App**
3. 入力項目:
   - Platforms: **iOS**
   - Name: `Hypnoctone`
   - Primary Language: **English (U.S.)** (or **Japanese**)
   - Bundle ID: 既存の `com.hypnoctone.HypnoctoneEngine` を選択
     - 未登録の場合は Apple Developer Portal の **Identifiers** で先に登録
   - SKU: `HYPNOCTONE_001` (内部管理用、任意の文字列)
   - User Access: **Full Access**
4. **Create** を押下
5. 作成された App のページ URL から **App Apple ID** (numeric ID) を控える
   - URL 末尾の数字 (例: `1234567890`)
   - これを後で `codemagic.yaml` の `APP_APPLE_ID` に設定

## ステップ 2: App Store Connect API キー発行

Codemagic が App Store Connect に upload するための API キーを発行する。

1. https://appstoreconnect.apple.com → **Users and Access** → **Integrations** タブ
2. **App Store Connect API** セクション → 右上の `+`
3. 入力:
   - Name: `Codemagic Hypnoctone`
   - Access: **App Manager** (Developer 以上の権限)
4. **Generate** を押下
5. 発行された情報を控える:
   - **Issuer ID** (UUID 形式、例: `12345678-1234-1234-1234-123456789012`)
   - **Key ID** (10 文字、例: `ABCDEFGHIJ`)
   - **Private Key** (`.p8` ファイル) — **一度しかダウンロードできない、必ず保存**

## ステップ 3: Codemagic で Integration 設定

1. Codemagic > 右上の自分のアバター > **Teams** > 自分の Team を選択
2. **Integrations** タブ > **App Store Connect** の **+** を押下
3. 入力:
   - **Display name**: `HypnoctoneAppStoreConnect`
     (この名前は `codemagic.yaml` の `integrations.app_store_connect` で参照する。
     大文字小文字含めて完全一致が必要)
   - **Issuer ID**: ステップ 2 で控えた値
   - **Key ID**: ステップ 2 で控えた値
   - **API key**: ステップ 2 でダウンロードした `.p8` ファイル
4. **Save** を押下

## ステップ 3.5: Code signing identities セットアップ

Codemagic が CI 時に Apple Distribution certificate と App Store provisioning profile を
fetch できるようにする。これがないと `xcode-project use-profiles` が signing 資材を
取得できず build が失敗する。

### certificate / profile を Codemagic に自動生成させる (推奨)

ステップ 3 で登録した App Store Connect API キーに **Admin** role があれば、Codemagic
は CI 実行時に証明書と profile を自動生成できる。事前準備は基本不要だが、念のため
Codemagic UI で確認:

1. Codemagic > **Teams** > 自分の Team > **Code signing identities**
2. **iOS certificates** タブで、App Store Connect integration 経由で証明書が
   見えていれば OK
3. 見えていない場合: **Fetch from Apple Developer Portal** ボタン (もしくは API キー
   integration が自動 fetch する) を押下

### certificate / profile を手動でアップロードする (代替)

すでに Mac 環境で証明書を持っている場合や、自動生成が失敗する場合の代替:

1. Apple Developer Portal で **Certificates** > **iOS Distribution** を作成し
   `.p12` ファイルでダウンロード (要 Mac の Keychain Access、もしくは
   ブラウザ + OpenSSL で CSR/p12 生成)
2. Apple Developer Portal > **Profiles** で App Store Distribution profile を作成
   (Bundle ID: `com.hypnoctone.HypnoctoneEngine`、Certificate: 上記 .p12)
3. Codemagic UI > **Code signing identities** > **iOS certificates** に .p12 アップロード
4. **iOS provisioning profiles** に .mobileprovision アップロード

個人開発の場合は **自動生成 (推奨)** で問題ない。

## ステップ 4: Team ID を pbxproj に反映

ADP 加入後、Apple Developer Portal でユニークな **Team ID** (10 文字) が割り当てられる。

1. https://developer.apple.com/account → **Membership Details** → **Team ID** を控える
2. `HypnoctoneEngine.xcodeproj/project.pbxproj` を編集:
   - Debug / Release 両 buildSettings に `DEVELOPMENT_TEAM = ABCDEFGHIJ;` を追加
     (ABCDEFGHIJ は実際の Team ID で置換)
3. commit + push:
   ```
   git add HypnoctoneEngine.xcodeproj/project.pbxproj
   git commit -m "chore: Task 32 — set DEVELOPMENT_TEAM for TestFlight signing"
   git push
   ```

## ステップ 5: `codemagic.yaml` の `APP_APPLE_ID` を更新

`codemagic.yaml` 内の `ios-testflight-release` workflow の `vars.APP_APPLE_ID` を
ステップ 1 で控えた numeric App Apple ID で置換。

```yaml
APP_APPLE_ID: "1234567890"  # ステップ 1 の App Apple ID で置換
```

commit + push:
```
git add codemagic.yaml
git commit -m "chore: Task 32 — set APP_APPLE_ID for TestFlight"
git push
```

## ステップ 6: Internal Testing 確認 (Group 作成は基本不要)

`codemagic.yaml` の現状の雛形では `beta_groups` を省略している。これは account holder
(= ADP 加入者本人) が **automatic に Internal Tester** になるため、明示的な Group 作成
なしで自分の iPhone から install 可能だから (Codex Task 32 Medium 反映で簡素化)。

1. https://appstoreconnect.apple.com → **My Apps** → Hypnoctone → **TestFlight** タブ
2. **Internal Testing** セクションに自分の名前 (account holder) が automatic で
   リストされていることを確認

### 別の Internal Tester を追加したい場合

家族 / 友人 / 他デバイス用 Apple ID 等を Internal Tester として追加するなら:

1. **Users and Access** → **+** → Apple ID と role (Developer 等) を指定して招待
2. 招待されたユーザーは Internal Testing で automatic に表示される

### 名前付き beta_groups を使いたい場合

`codemagic.yaml` の `publishing.app_store_connect.beta_groups: [Internal]` のコメントを
解除し、TestFlight タブで同名 "Internal" Group を事前作成 + テスター追加。

## ステップ 7: 初回 release tag を push

```
git tag release-v0.1.0
git push origin release-v0.1.0
```

これで Codemagic の `ios-testflight-release` workflow が trigger される。

## ステップ 8: TestFlight で iPhone に install

1. Codemagic build が成功 (通常 5-15 分) すると App Store Connect の TestFlight に
   ビルドが現れる
2. iPhone で **TestFlight** アプリを開く
3. Hypnoctone が表示されるので **インストール** を押下
4. 起動して動作確認

## 検証チェックリスト

実機で確認すべき項目 (後続課題として残してある Phase):
- [ ] Task 24: Background playback (画面ロック中も再生継続) / Lock Screen からの操作
- [ ] Task 25 Phase 8: AppIcon の縮小視認性 (Home / Settings / Spotlight)
- [ ] Task 26 Phase 7: 波形の動きの心地よさ + 微調整
- [ ] Task 27 Phase 6: 設定の round trip (アプリ再起動で Mode / Volume / MUTE / Timer 復元)
- [ ] Task 28 Phase 6: Onboarding 初回起動 → Get Started → 再起動で直接 MainView
- [ ] Task 29 Phase 6: VoiceOver / Reduce Motion / Dynamic Type 大の挙動
- [ ] Task 30 Phase 8: BINAURAL の L/R 5Hz beat の聴感確認 (ヘッドフォン推奨)
- [ ] Task 31 Phase 8: GROUNDING の 100Hz 帯 + 6Hz binaural 複合の聴感 + SUB UI "G2" 表示

## トラブルシューティング

### 加入後に App Store Connect で Bundle ID が選択肢に出ない
→ Apple Developer Portal の **Identifiers** で `com.hypnoctone.HypnoctoneEngine` を
Explicit App ID として登録。Capabilities は最初は空でも OK。

### Codemagic build で signing エラー
→ `xcode-project use-profiles` のログを確認。Codemagic UI の integration 設定で
   Issuer ID / Key ID / API key の入力ミスがないか再確認。

### `agvtool new-version -all` が失敗
→ pbxproj に `CURRENT_PROJECT_VERSION = 1;` があることを確認 (Task 25 以降に
   既に設定済み)。

### TestFlight に build が現れない
→ App Store Connect の **TestFlight > Builds** で "Processing" のままなら 5-30 分待つ。
   "Missing Compliance" が出ることは Task 32 以降は無いはず (Info.plist に
   `ITSAppUsesNonExemptEncryption = false` を明示済み)。それでも警告が出る場合は
   **Export Compliance** で「No」(暗号化使用なし) を選ぶ。

### agvtool が "VERSIONING_SYSTEM" 警告を出す / 失敗
→ pbxproj の Debug/Release buildSettings に `VERSIONING_SYSTEM = "apple-generic";` を追加。
   Task 25 以降の pbxproj には未設定。CI 初回で agvtool が失敗したら追加対応する。

### iPhone で TestFlight に Hypnoctone が出ない
→ Internal Testing Group に自分の Apple ID が追加されていることを確認。
   TestFlight アプリで Apple ID が一致してることも確認。
