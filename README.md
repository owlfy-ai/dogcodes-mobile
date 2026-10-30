<!-- Keep README languages aligned with the desktop phone-remote section. -->
<div align="center">

<img src="assets/branding/app-icon.png" alt="dog.codes" width="96" height="96" />

# dog.codes.mobile

**Command your agents from your phone**

<strong>English</strong> · <a href="docs/i18n/README.zh-CN.md">简体中文</a> · <a href="docs/i18n/README.zh-TW.md">繁體中文</a> · <a href="docs/i18n/README.ja.md">日本語</a> · <a href="docs/i18n/README.ko.md">한국어</a> · <a href="docs/i18n/README.es.md">Español</a> · <a href="docs/i18n/README.fr.md">Français</a> · <a href="docs/i18n/README.de.md">Deutsch</a> · <a href="docs/i18n/README.pt-BR.md">Português (Brasil)</a>

</div>

This project is the iOS and Android companion app for the [dog.codes PC app](https://github.com/owlfy-ai/dogcodes) and must be used together with the PC app.

Connect to your own computers to continue conversations, approve requests, review changes, run projects, and use remote desktop. Your agents run on your computer using the accounts and subscriptions you already have.

[dog.codes](https://dog.codes) · [Desktop app](https://github.com/owlfy-ai/dogcodes) · [Features](#phone) · [Development](docs/development.md)

## Supported agents on your computer

Connect the agents you already use. The 12 integrations below are implemented; available models, approvals, usage data, and recovery behavior vary by agent and installed version. Install and sign in to your chosen agent through its own tools first.

<p align="center">
  <a href="https://developers.openai.com/codex/"><img src="docs/images/readme/agents/codex.png" alt="Codex" height="36" /></a>
  <a href="https://code.claude.com/docs/en/overview"><img src="docs/images/readme/agents/claude-code.png" alt="Claude Code" height="36" /></a>
  <a href="https://cursor.com/"><img src="docs/images/readme/agents/cursor.png" alt="Cursor" height="36" /></a>
  <a href="https://www.kimi.com/"><img src="docs/images/readme/agents/kimi.png" alt="Kimi Code" height="36" /></a>
  <a href="https://grok.com/"><img src="docs/images/readme/agents/grok.png" alt="Grok Build" height="36" /></a>
  <a href="https://z.ai/"><img src="docs/images/readme/agents/zcode.png" alt="ZCode" height="36" /></a>
  <br />
  <a href="https://antigravity.google/"><img src="docs/images/readme/agents/antigravity.png" alt="Antigravity" height="36" /></a>
  <a href="https://www.codebuddy.ai/"><img src="docs/images/readme/agents/codebuddy.png" alt="CodeBuddy" height="36" /></a>
  <a href="https://pi.dev/"><img src="docs/images/readme/agents/pi.png" alt="Pi" height="36" /></a>
  <a href="https://opencode.ai/"><img src="docs/images/readme/agents/opencode.png" alt="OpenCode" height="36" /></a>
  <a href="https://github.com/deepseek-ai/deepseek-harness"><img src="docs/images/readme/agents/deepseek-harness.png" alt="DeepSeek Harness" height="36" /></a>
  <a href="https://kiro.dev/"><img src="docs/images/readme/agents/kiro.png" alt="Kiro" height="36" /></a>
</p>

<a id="phone"></a>

## Command your agents from your phone

**Leave the laptop at home. Your agents keep working on your computer while your phone keeps command.**

Pair a phone once and run everything below from anywhere. Your code and your agents stay on your computer.

![Command your agents from your phone — desktop first, phone where available](docs/images/readme/en/phone-remote.png)

- **Continue or start conversations.** Pick up any conversation from your computer, or start a new one — choose the agent, model and thinking effort, watch the output stream in live, and search, pin, archive or fork sessions.

  ![Hand off work between agents seamlessly — desktop first, phone where available](docs/images/readme/en/switch-agent.png)

- **Approve and answer.** Permission requests and agent questions reach your phone with push notifications; one tap and the agent carries on. Every approval is checked against the original run on your computer.

  ![Approve permissions and answer questions — desktop first, phone where available](docs/images/readme/en/permissions.png)

- **Review and commit.** See the changes in every project folder, stage files, have an agent write the commit message, then commit, push, pull or sync. Browse commit history and compare branches read-only.

  ![Git management that feels familiar — desktop first, phone where available](docs/images/readme/en/git-changes.png)

- **Add projects from your PC.** Browse the folders on your computer and add one as a project without sitting back down at your desk.

  ![Add projects from your computer — desktop first, phone where available](docs/images/readme/en/add-project.png)

- **Run commands in your PC’s terminal.** Open terminals in any project folder and work in the real shell of your computer.

  ![Run commands in your PC terminal — desktop first, phone where available](docs/images/readme/en/terminal.png)

- **Run the project, see it on your phone.** Start the launch entries on your computer and open the running web app right on the phone.

  ![Discover how to run a project — desktop first, phone where available](docs/images/readme/en/run-project.png)

- **Browse files and send attachments.** Read project files, and attach files and images to your messages.

  ![Browse files and send attachments — desktop first, phone where available](docs/images/readme/en/files-attachments.png)

- **Remote desktop when you need it.** View your computer’s screen and tap, drag, scroll, pinch, type, or paste text and images — with quality that adapts to the network.

![Remote desktop when you need it — desktop first, phone where available](docs/images/readme/en/remote-desktop.png)

### How it connects

- Scan a QR code once; no account is needed. The link is end-to-end encrypted. Pair several computers, see which are online, and revoke a phone at any time from the desktop app.
- The phone connects directly when it can and falls back to the dog.codes relay service, which only forwards encrypted traffic.
- Your computer stays on with dog.codes open or minimized. While work or a remote session is active, dog.codes can keep the computer from sleeping automatically; you can turn this off.
- Remote desktop works with macOS, Windows and Linux (X11 and Wayland) computers; your operating system asks for the screen and input permissions it requires.

<a id="getting-started"></a>

## Get started

1. Set up the [dog.codes desktop app](https://github.com/owlfy-ai/dogcodes) on your computer, install and sign in to at least one supported agent, and add your project folders.
2. Keep dog.codes open or minimized, open **Connect phone**, and scan the QR code with **Connect computer** in the phone app.
3. Choose a computer and project, then continue a conversation or start a new one.

The phone app supports Simplified Chinese and English. For source builds, local pairing, testing, and implementation notes, see the [development guide](docs/development.md).

Agent icons are shared with the desktop app; see [asset sources and notices](docs/images/readme/agents/README.md). Product names and marks belong to their respective owners.
