<!-- Keep README languages aligned with the desktop phone-remote section. -->
<div align="center">

<img src="../../assets/branding/app-icon.png" alt="dog.codes" width="96" height="96" />

# dog.codes.mobile

**スマートフォンからエージェントを指揮する**

<a href="../../README.md">English</a> · <a href="../../docs/i18n/README.zh-CN.md">简体中文</a> · <a href="../../docs/i18n/README.zh-TW.md">繁體中文</a> · <strong>日本語</strong> · <a href="../../docs/i18n/README.ko.md">한국어</a> · <a href="../../docs/i18n/README.es.md">Español</a> · <a href="../../docs/i18n/README.fr.md">Français</a> · <a href="../../docs/i18n/README.de.md">Deutsch</a> · <a href="../../docs/i18n/README.pt-BR.md">Português (Brasil)</a>

</div>

このプロジェクトは [dog.codes PC アプリ](https://github.com/owlfy-ai/dogcodes)の iOS / Android 向けコンパニオンアプリです。利用には PC アプリが必要です。

自分のコンピューターに接続し、会話の続行、権限の承認、変更のレビュー、プロジェクトの実行、リモートデスクトップを利用できます。エージェントは既存のアカウントとサブスクリプションでコンピューター上で動作します。

[dog.codes](https://dog.codes) · [デスクトップ版](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.ja.md) · [機能](#phone) · [開発ガイド](../../docs/development.md)

## PC で対応するエージェント

普段使っているエージェントを接続できます。以下の 12 種類との連携は実装済みです。モデル、承認、使用量データ、復旧機能はエージェントとバージョンによって異なります。先に公式ツールでインストールとログインを済ませてください。

<p align="center">
  <a href="https://developers.openai.com/codex/"><img src="../../docs/images/readme/agents/codex.png" alt="Codex" height="36" /></a>
  <a href="https://code.claude.com/docs/en/overview"><img src="../../docs/images/readme/agents/claude-code.png" alt="Claude Code" height="36" /></a>
  <a href="https://cursor.com/"><img src="../../docs/images/readme/agents/cursor.png" alt="Cursor" height="36" /></a>
  <a href="https://www.kimi.com/"><img src="../../docs/images/readme/agents/kimi.png" alt="Kimi Code" height="36" /></a>
  <a href="https://grok.com/"><img src="../../docs/images/readme/agents/grok.png" alt="Grok Build" height="36" /></a>
  <a href="https://z.ai/"><img src="../../docs/images/readme/agents/zcode.png" alt="ZCode" height="36" /></a>
  <br />
  <a href="https://antigravity.google/"><img src="../../docs/images/readme/agents/antigravity.png" alt="Antigravity" height="36" /></a>
  <a href="https://www.codebuddy.ai/"><img src="../../docs/images/readme/agents/codebuddy.png" alt="CodeBuddy" height="36" /></a>
  <a href="https://pi.dev/"><img src="../../docs/images/readme/agents/pi.png" alt="Pi" height="36" /></a>
  <a href="https://opencode.ai/"><img src="../../docs/images/readme/agents/opencode.png" alt="OpenCode" height="36" /></a>
  <a href="https://github.com/deepseek-ai/deepseek-harness"><img src="../../docs/images/readme/agents/deepseek-harness.png" alt="DeepSeek Harness" height="36" /></a>
  <a href="https://kiro.dev/"><img src="../../docs/images/readme/agents/kiro.png" alt="Kiro" height="36" /></a>
</p>

<a id="phone"></a>

## スマートフォンからエージェントを指揮する

**ノート PC は置いて出かけましょう。エージェントはコンピューターで働き続け、指揮権はスマートフォンの手元に。**

スマートフォンを一度ペアリングすれば、以下のすべてをどこからでも実行できます。コードとエージェントはコンピューターの中にとどまります。

![スマートフォンからエージェントを指揮する](../../docs/images/readme/en/phone-remote.png)

- **会話の続き、または新しい会話。** コンピューター上の会話を開いて続けるほか、新しいセッションも開始できます。エージェント、モデル、思考の強さを選び、出力をリアルタイムで確認し、セッションの検索・固定・アーカイブ・フォークも可能です。

  ![会話の続き、または新しい会話。](../../docs/images/readme/en/switch-agent.png)

- **承認と回答。** 権限リクエストやエージェントの質問がプッシュ通知とともにスマートフォンに届き、ワンタップでエージェントが再開します。承認はすべて、コンピューター上の元の実行と照合されます。

  ![承認と回答。](../../docs/images/readme/en/permissions.png)

- **レビューとコミット。** 各プロジェクトフォルダーの変更を確認し、ファイルをステージして、エージェントにコミットメッセージを書かせ、コミット、プッシュ、プル、同期。コミット履歴の閲覧やブランチの比較（読み取り専用）もできます。

  ![レビューとコミット。](../../docs/images/readme/en/git-changes.png)

- **PC のフォルダーからプロジェクトを追加。** コンピューターのフォルダーを閲覧して、プロジェクトとして追加。デスクに戻る必要はありません。

  ![PC のフォルダーからプロジェクトを追加。](../../docs/images/readme/en/add-project.png)

- **PC のターミナルでコマンドを実行。** 任意のプロジェクトフォルダーでターミナルを開き、コンピューターの本物のシェルで作業できます。

  ![PC のターミナルでコマンドを実行。](../../docs/images/readme/en/terminal.png)

- **プロジェクトを実行して、スマートフォンで確認。** コンピューターで起動項目を実行し、動作中の Web アプリをスマートフォンでそのまま開きます。

  ![プロジェクトを実行して、スマートフォンで確認。](../../docs/images/readme/en/run-project.png)

- **ファイルの閲覧と添付。** プロジェクトのファイルを読み、メッセージにファイルや画像を添付できます。

  ![ファイルの閲覧と添付。](../../docs/images/readme/en/files-attachments.png)

- **必要ならリモートデスクトップ。** コンピューターの画面を表示し、タップ、ドラッグ、スクロール、ピンチ、入力、テキストや画像の貼り付けが可能。画質はネットワークに合わせて自動調整されます。

![必要ならリモートデスクトップ。](../../docs/images/readme/en/remote-desktop.png)

### 接続の仕組み

- QR コードを一度スキャンするだけで、アカウントは不要です。通信はエンドツーエンドで暗号化されます。複数のコンピューターを登録でき、オンライン状況の確認や、スマートフォンの連携解除はデスクトップ側からいつでも可能です。
- スマートフォンは可能なら直接接続し、できない場合は dog.codes の中継サービスを経由します。中継は暗号化された通信を転送するだけです。
- コンピューターは電源を入れたまま、dog.codes を開いた（または最小化した）状態にしてください。作業やリモートセッション中は、dog.codes が自動スリープを防げます（オフにもできます）。
- リモートデスクトップは macOS、Windows、Linux（X11 / Wayland）のコンピューターに対応します。必要な画面・入力の権限は OS が確認します。

<a id="getting-started"></a>

## はじめる

1. コンピューターに [dog.codes デスクトップ版](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.ja.md)を設定し、対応エージェントをひとつ以上インストールしてログインし、プロジェクトフォルダーを追加します。
2. dog.codes を開いたまま、または最小化して「Connect phone」を開き、スマートフォンの「Connect computer」で QR コードを読み取ります。
3. コンピューターとプロジェクトを選び、会話を続けるか、新しい会話を始めます。

スマートフォンの UI は簡体字中国語と英語に対応します。ソースからのビルド、ローカル接続、テスト、実装の詳細は[開発ガイド](../../docs/development.md)をご覧ください。

エージェントのアイコンはデスクトップ版と共通です。[素材の出典と注意事項](../../docs/images/readme/agents/README.md)をご覧ください。製品名と商標は各権利者に帰属します。
