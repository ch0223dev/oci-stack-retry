# OCI スタック適用リトライ (GitHub Actions 版)

OCI Resource Manager スタックの「適用」を、GitHub Actions から 15 分おきに
自動で試し続ける仕掛けです。失敗理由が `Out of host capacity` の間は
静かにリトライし、**成功したら通知して自動で止まります**。

## 通知について

| 結果 | 通知 |
|---|---|
| 成功 (SUCCEEDED) | GitHub Issue を作成 → GitHub アプリのプッシュ通知 / メールで届く。任意で Discord 等の Webhook にも送信。ワークフローは自動で無効化される |
| 容量不足で失敗 | 通知しない (1 日に 100 件近く届いてしまうため) |
| 容量不足以外で失敗 (設定ミス等) | GitHub Issue を 1 回だけ作成して通知し、自動リトライを停止。修正後に手動実行 (force 有効) で再開 |

Discord 通知が欲しい場合は、サーバーの「連携サービス → ウェブフック」で
URL を発行し、Secrets に `NOTIFY_WEBHOOK_URL` として登録してください
(Slack の Incoming Webhook でも本文フォーマット以外はほぼそのまま使えます)。

## セットアップ手順

### 1. リポジトリを作成する

- GitHub で新規リポジトリを作成し、このフォルダの中身
  (`.github/workflows/oci-stack-retry.yml` と `scripts/check-and-apply.sh`) を
  そのままの階層でアップロード / push する。
- **公開・非公開の選択が重要** (下の「実行分数の注意」参照)。
  Secrets の中身は公開リポジトリでも外部からは見えません。

### 2. Secrets を登録する

リポジトリ → Settings → Secrets and variables → Actions → New repository secret

| 名前 | 値 |
|---|---|
| `OCI_CLI_USER` | OCI ユーザーの OCID (`ocid1.user.oc1..` で始まる) |
| `OCI_CLI_TENANCY` | テナンシの OCID (`ocid1.tenancy.oc1..`) |
| `OCI_CLI_FINGERPRINT` | API キーのフィンガープリント (`xx:xx:...` 形式) |
| `OCI_CLI_REGION` | `ap-osaka-1` (大阪の場合) |
| `OCI_CLI_KEY_CONTENT` | API 秘密鍵 (.pem ファイル) の中身を丸ごと貼り付け |
| `OCI_STACK_ID` | 対象スタックの OCID (`ocid1.ormstack...` / コンソールのスタック情報に表示) |
| `NOTIFY_WEBHOOK_URL` | (任意) Discord 等の Webhook URL |

値の入手方法:

- ローカル PC で `oci setup config` を済ませていれば、`~/.oci/config` に
  user / tenancy / fingerprint / region が、`~/.oci/oci_api_key.pem` に
  秘密鍵が入っているので、それをコピーすれば OK です。
- まだの場合は OCI コンソール → 右上のプロファイル → ユーザー設定 →
  APIキー → 「APIキーの追加」で秘密キーをダウンロードし、
  表示されるフィンガープリントと設定プレビューの値をコピーしてください。
- **推奨**: この自動化専用の OCI ユーザーを作って API キーを発行すると、
  何かあったときにそのキーだけを削除して止められます。

### 3. 動作テスト

- Actions タブ → `oci-stack-retry` → Run workflow で手動実行し、
  緑色に完了することと、OCI コンソールのジョブ一覧に新しい適用ジョブが
  増えていることを確認してください。
- 以後は 15 分おきに自動実行されます (GitHub の混雑状況で数分〜
  ときに数十分遅れることがあります)。

## 実行分数 (コスト) の注意

- 各回の実行は「前回ジョブの確認 + 必要なら開始だけ」なので約 1〜1.5 分です。
  15 分間隔 × 30 日で約 3,000〜4,000 分/月になります。
- **プライベートリポジトリ**の無料枠は 2,000 分/月のため、15 分間隔だと
  枠を超えます。プライベートにする場合は cron を `*/30` (30 分間隔) に
  変えてください (約 1,500〜2,000 分/月に収まります)。
- **公開リポジトリ**では標準ランナーの Actions が無料・無制限のため、
  15 分間隔でも課金されません。ワークフローの中身は公開されますが、
  Secrets は暗号化され、ログにも自動でマスクされます。
  (ただし公開リポジトリでは、60 日間リポジトリに活動がないと
  スケジュール実行が自動で無効化される仕様があります)

## 止め方・再開

- 成功時: ワークフローが自分でスケジュールを無効化します。
- 手動で止める: Actions タブ → ワークフロー右の「…」→ Disable workflow。
- 容量以外の失敗で止まった後: スタックを修正 → Issue を閉じる →
  Run workflow で force を有効にして手動実行。

## 補足

- 大阪リージョン (ap-osaka-1) は可用性ドメインが 1 つしかないため、
  AD を切り替えて当てる手は使えません。間隔を空けた継続リトライと、
  シェイプを小さくする (A1 は 2 OCPU / 12 GB が現在の無料上限) 工夫が効きます。
- 適用ジョブの一覧取得には `oci resource-manager job list --stack-id` を
  使っています (OCI CLI 公式リファレンス準拠)。
