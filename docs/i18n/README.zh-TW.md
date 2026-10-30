<!-- Keep README languages aligned with the desktop phone-remote section. -->
<div align="center">

<img src="../../assets/branding/app-icon.png" alt="dog.codes" width="96" height="96" />

# dog.codes.mobile

**用手機指揮你的 Agent**

<a href="../../README.md">English</a> · <a href="../../docs/i18n/README.zh-CN.md">简体中文</a> · <strong>繁體中文</strong> · <a href="../../docs/i18n/README.ja.md">日本語</a> · <a href="../../docs/i18n/README.ko.md">한국어</a> · <a href="../../docs/i18n/README.es.md">Español</a> · <a href="../../docs/i18n/README.fr.md">Français</a> · <a href="../../docs/i18n/README.de.md">Deutsch</a> · <a href="../../docs/i18n/README.pt-BR.md">Português (Brasil)</a>

</div>

本專案是 [dog.codes PC 端](https://github.com/owlfy-ai/dogcodes)配套的 iOS / Android 手機 App，需搭配 PC 端使用。

連接自己的電腦，隨時接續對話、批准權限、審查變更、執行專案和使用遠端桌面。Agent 在電腦上執行，沿用你既有的帳號和訂閱。

[dog.codes](https://dog.codes) · [桌面端](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.zh-TW.md) · [功能](#phone) · [開發文件](../../docs/development.md)

## 支援的 PC 端 Agent

連接你已經使用的程式開發助手。以下 12 個 Agent 均已整合；可用模型、核准流程、用量資料與恢復能力會依 Agent 及安裝版本而異。請先透過各 Agent 的官方工具完成安裝與登入。

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

## 用手機指揮你的 Agent

**出門不必帶電腦。Agent 在電腦上照常幹活，手機始終掌握指揮權。**

手機只需配對一次，下面的一切都能在任何地方完成。你的程式碼和 Agent 始終留在自己的電腦上。

![用手機指揮你的 Agent](../../docs/images/readme/en/phone-remote.png)

- **接續對話或發起新對話。** 接著電腦上的任一對話繼續，也可以新增工作階段：選擇 Agent、模型和思考強度，即時查看串流輸出，還能搜尋、置頂、封存或分岔工作階段。

  ![接續對話或發起新對話。](../../docs/images/readme/en/switch-agent.png)

- **批准權限，回答提問。** 權限請求和 Agent 的提問會連同推播通知送到手機，點一下 Agent 就繼續工作。每次批准都會與電腦上原本的執行核對。

  ![批准權限，回答提問。](../../docs/images/readme/en/permissions.png)

- **審查並提交。** 查看每個專案目錄的變更，暫存檔案，讓 Agent 寫好提交說明，再提交、推送、拉取或同步。還能唯讀瀏覽提交歷史、比較分支。

  ![審查並提交。](../../docs/images/readme/en/git-changes.png)

- **從電腦目錄建立專案。** 瀏覽電腦上的資料夾，選一個加入為專案，不必坐回桌前。

  ![從電腦目錄建立專案。](../../docs/images/readme/en/add-project.png)

- **在電腦終端機裡執行指令。** 在任一專案目錄開啟終端機，使用你電腦上真實的 Shell。

  ![在電腦終端機裡執行指令。](../../docs/images/readme/en/terminal.png)

- **執行專案，在手機上看效果。** 在電腦上啟動執行項，手機裡直接開啟正在執行的網頁應用程式。

  ![執行專案，在手機上看效果。](../../docs/images/readme/en/run-project.png)

- **瀏覽檔案，傳送附件。** 查看專案檔案，並在訊息中附上檔案和圖片。

  ![瀏覽檔案，傳送附件。](../../docs/images/readme/en/files-attachments.png)

- **需要時開啟遠端桌面。** 查看電腦螢幕，點按、拖曳、捲動、捏合縮放、輸入，或貼上文字和圖片，畫質會隨網路狀況自動調整。

![需要時開啟遠端桌面。](../../docs/images/readme/en/remote-desktop.png)

### 連線方式

- 只需掃一次 QR code，無須帳號。連線全程端對端加密。可配對多台電腦、查看上線狀態，並隨時在桌面端撤銷某支手機。
- 手機能直連時直連，否則回退到 dog.codes 中繼服務，中繼只轉送加密資料。
- 電腦需保持開機，dog.codes 保持開啟或最小化。有任務或遠端工作階段進行時，dog.codes 可以防止電腦自動睡眠，也可以關閉此選項。
- 遠端桌面支援 macOS、Windows 和 Linux（X11 與 Wayland）電腦；系統會要求所需的螢幕與輸入權限。

<a id="getting-started"></a>

## 開始使用

1. 在電腦上設定 [dog.codes 桌面端](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.zh-TW.md)，安裝並登入至少一個支援的 Agent，加入專案目錄。
2. 保持 dog.codes 開啟或最小化，在桌面端開啟「連接手機」，用手機端的「連接電腦」掃描 QR code。
3. 選擇電腦和專案，接續既有對話或發起新對話。

手機介面支援簡體中文和英文。原始碼建置、本機配對、測試及實作說明請見[開發文件](../../docs/development.md)。

Agent 圖示與桌面端共用，來源及聲明請見[素材說明](../../docs/images/readme/agents/README.md)。產品名稱及商標歸各自所有者。
