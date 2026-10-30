<!-- Keep README languages aligned with the desktop phone-remote section. -->
<div align="center">

<img src="../../assets/branding/app-icon.png" alt="dog.codes" width="96" height="96" />

# dog.codes.mobile

**用手机指挥你的 Agent**

<a href="../../README.md">English</a> · <strong>简体中文</strong> · <a href="../../docs/i18n/README.zh-TW.md">繁體中文</a> · <a href="../../docs/i18n/README.ja.md">日本語</a> · <a href="../../docs/i18n/README.ko.md">한국어</a> · <a href="../../docs/i18n/README.es.md">Español</a> · <a href="../../docs/i18n/README.fr.md">Français</a> · <a href="../../docs/i18n/README.de.md">Deutsch</a> · <a href="../../docs/i18n/README.pt-BR.md">Português (Brasil)</a>

</div>

本项目是 [dog.codes PC 端](https://github.com/owlfy-ai/dogcodes)配套的 iOS / Android 手机 App，需配合 PC 端使用。

连接自己的电脑，随时接续对话、批准权限、审查变更、运行项目和使用远程桌面。Agent 在电脑上运行，沿用你已有的账号和订阅。

[dog.codes](https://dog.codes) · [桌面端](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.zh-CN.md) · [功能](#phone) · [开发文档](../../docs/development.md)

## 支持的 PC 端 Agent

连接你已经在用的编程助手。以下 12 家 Agent 均已有接入；可用模型、审批、用量数据及恢复能力因 Agent 和安装版本而异。请先通过各 Agent 的官方工具完成安装与登录。

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

## 用手机指挥你的 Agent

**出门不必带电脑。Agent 在电脑上照常干活，手机始终掌握指挥权。**

手机只需配对一次，下面的一切都能在任何地方完成。你的代码和 Agent 始终留在自己的电脑上。

![用手机指挥你的 Agent](../../docs/images/readme/en/phone-remote.png)

- **接续对话或发起新对话。** 接着电脑上的任意对话继续，也可以新建会话：选择 Agent、模型和思考强度，实时查看流式输出，还能搜索、置顶、归档或分叉会话。

  ![接续对话或发起新对话。](../../docs/images/readme/en/switch-agent.png)

- **批准权限，回答提问。** 权限请求和 Agent 的提问会连同推送通知送到手机，点一下 Agent 就继续工作。每次批准都会与电脑上原本的运行核对。

  ![批准权限，回答提问。](../../docs/images/readme/en/permissions.png)

- **审查并提交。** 查看每个项目目录的变更，暂存文件，让 Agent 写好提交说明，再提交、推送、拉取或同步。还能只读浏览提交历史、比较分支。

  ![审查并提交。](../../docs/images/readme/en/git-changes.png)

- **从电脑目录创建项目。** 浏览电脑上的文件夹，选一个添加为项目，不必坐回桌前。

  ![从电脑目录创建项目。](../../docs/images/readme/en/add-project.png)

- **在电脑终端里执行命令。** 在任意项目目录打开终端，使用你电脑上真实的 Shell。

  ![在电脑终端里执行命令。](../../docs/images/readme/en/terminal.png)

- **运行项目，在手机上看效果。** 在电脑上启动运行项，手机里直接打开正在运行的网页应用。

  ![运行项目，在手机上看效果。](../../docs/images/readme/en/run-project.png)

- **浏览文件，发送附件。** 查看项目文件，并在消息中附带文件和图片。

  ![浏览文件，发送附件。](../../docs/images/readme/en/files-attachments.png)

- **需要时开启远程桌面。** 查看电脑屏幕，点按、拖动、滚动、捏合缩放、输入，或粘贴文字和图片，画质会随网络状况自适应。

![需要时开启远程桌面。](../../docs/images/readme/en/remote-desktop.png)

### 连接方式

- 只需扫一次二维码，无需账号。连接全程端到端加密。可配对多台电脑、查看在线状态，并随时在桌面端撤销某部手机。
- 手机能直连时直连，否则回退到 dog.codes 中继服务，中继只转发加密数据。
- 电脑需保持开机，dog.codes 保持打开或最小化。有任务或远程会话进行时，dog.codes 可以阻止电脑自动睡眠，也可以关闭该选项。
- 远程桌面支持 macOS、Windows 和 Linux（X11 与 Wayland）电脑；系统会请求所需的屏幕与输入权限。

<a id="getting-started"></a>

## 开始使用

1. 在电脑上配置 [dog.codes 桌面端](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.zh-CN.md)，安装并登录至少一个支持的 Agent，添加项目目录。
2. 保持 dog.codes 打开或最小化，在桌面端打开「连接手机」，用手机端的「连接电脑」扫描二维码。
3. 选择电脑和项目，接续已有对话或发起新对话。

手机界面支持简体中文和英文。源码构建、本地配对、测试及实现说明见[开发文档](../../docs/development.md)。

Agent 图标与桌面端共用，来源及声明见[素材说明](../../docs/images/readme/agents/README.md)。产品名称及商标归各自所有者。
