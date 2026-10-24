# AIMeter

macOSのメニューバーとウィジェットに、AIツールの利用量を表示するSwiftUIアプリです。
Codex、Gemini / Antigravity、Claude Code、Grok Bot、GitHub Copilot、Windsurf、Cursorのローカルデータを集計します。
表示値にはログからの推定や設定した上限が含まれ、サービスの公式請求額・残量と一致するとは限りません。

## 動作・ビルド環境

- 実行対象：macOS 14以降
- ビルド：macOS 26 SDKを含むXcode（macOS 26のUI APIを使用）
- Swift Package Manager。外部Swiftパッケージへの依存なし
- 通常のアプリ動作にPythonは不要。旧収集スクリプトのテストにはPython 3.9以降を使用

Apple Silicon環境でビルドと合成データによるテストを確認しています。
一般ユーザー向けの配布先は [GitHub Releases](https://github.com/TaigaShinohara/AIMeter/releases) です。
署名・Apple公証・公証チケット添付済みの
[AIMeter 1.1.1](https://github.com/TaigaShinohara/AIMeter/releases/tag/v1.1.1) を公開しています。
Releaseに添付された `AIMeter-<version>-macos-universal.zip` を展開し、
`AIMeter.app` をアプリケーションフォルダへ移動して開きます。
Apple Silicon・Intelの両方を収録し、利用者によるXcodeやPythonのインストールは不要です。
ソースコードのZIPはアプリ本体ではありません。初回起動・Widget実表示・Intel実機などの
未確認範囲は、各Releaseの「動作確認の範囲」を確認してください。

現在の開発版では、Widgetの空状態と本体との表示整合を改善しています。
この変更は公開済み1.1.1のZIPには含まれず、再リリースはまだ行っていません。
新規macOSユーザーでのGUI確認、Intel/macOS 14実機、任意APIの実接続は未確認です。

## ビルドとテスト

```sh
git clone https://github.com/TaigaShinohara/AIMeter.git
cd AIMeter
swift build -c release
swift test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py' -v
```

テストは一時ディレクトリの合成データを使い、個人の利用ログやAPI資格情報を必要としません。

アプリバンドルを作成する場合は `./scripts/build_app.sh` を使用します。
このスクリプトはローカルの署名ID（なければad-hoc署名）を使い、
`/Applications` が書込み可能な場合は既存の `AIMeter.app` を更新してWidgetを登録します。
`./run.sh`、`make run`、`Launch AIMeter.command` も必要に応じてこのビルド処理を実行し、アプリを起動します。
手順と機能は [配布・導入ガイド](DISTRIBUTION_GUIDE.md) を参照してください。
署名・公証・GitHub Releases公開の手動手順は [リリース担当者向けガイド](docs/RELEASING.md) にあります。

## データと通信

- ローカル収集は各ツールの既定パス、または設定画面で指定したパスを読み取ります。アプリ本体はApp Sandboxによるホーム配下への制限を持ちません。
- 集計結果は `~/.ai_meter_usage.json` に保存し、所有者だけが読み書きできる権限（0600）を設定します。ログ本文をこの集計ファイルへ保存する設計ではありません。
- macOSのWidgetは、本体が `~/.ai_meter_widget.json`（0600）へ保存した表示情報を読みます。有効サービス、期間、手入力、任意APIの取得結果を本体と共有します。APIキーやログ本文は含めません。本体の終了中は最後の表示情報を使い、独自にログやAPIを集計しません。
- Widget用の表示情報が未取得・欠損・不正な場合は起動・更新を案内し、全サービスが無効の場合は設定を案内します。サンプル値はギャラリープレビューに限って使用します。OS側の都合によりWidgetへの反映には時間がかかる場合があります。
- 任意のOpenAI連携を設定すると、OpenAIの組織利用量・費用APIへ認証付きで通信します。Admin KeyはmacOS Keychainに保存します。
- 任意のGCP連携では、ローカルの `gcloud` が発行するトークンでGoogle Cloud Monitoringへ通信します。GCP Project IDはアプリ設定に保存します。
- 上記APIへの送信にローカルのプロンプト本文は使用しません。
- 大きすぎるファイル・行、過剰な探索件数、不正な数値は拒否します。入力制限に達した収集では以前の集計ファイルを保持します。時間制限は協調的な検査であり、OSのI/Oタイムアウトではありません。

個人ログ、集計ファイル、APIキーをIssueやPull Requestに添付しないでください。
セキュリティ上の問題は [SECURITY.md](SECURITY.md) の手順で報告してください。

## ライセンス

[MIT License](LICENSE)
