# Store review notes

Paste the matching block into **App Store Connect → App Review Information → Notes** and **Google Play Console → App content → App access** (choose "All or some functionality is restricted", then add the instructions). Each block is under App Store's 4,000-character limit.

Leave **Sign-in required** off in App Store Connect: there is no account.

Before submitting, check the items under "Still to decide" at the end.

---

## English

DogCodes is the phone companion to the free DogCodes desktop app (https://dog.codes). It connects to the user's own computer, where coding agents such as Claude Code or Codex run. The phone views those conversations, sends new instructions, answers permission requests and reviews code changes. There is no account, sign-up or purchase.

HOW TO REVIEW WITHOUT A COMPUTER
1. Open the app. On the first screen, tap "Explore an example first" at the bottom.
2. The app opens a made-up "Example computer". An orange bar at the top of every screen says "Example mode" and has an Exit button.
3. Things to try:
   - Chats: open any chat. Type a message and send it; a simulated agent reply appears after a few seconds.
   - Inbox: answer the question in "Test the shopping cart", or allow or deny the command in "Improve product search". The agent continues in the chat.
   - Projects: browse files and code changes, open the terminal, and preview the running web page.
   - Computers: open Remote desktop to see a sample screen.
4. Tap Exit to return to the first screen.

Example mode never connects to anything. All data is fictional and held in memory, and is discarded on exit. Actions that would change a real computer, such as committing code, show a note that they need a connected computer.

HOW REAL USE WORKS
The user installs the DogCodes desktop app, clicks "Connect phone" there, and scans the QR code with this app. The connection is end-to-end encrypted. Traffic goes directly between phone and computer, or through our relay, which only forwards encrypted data it cannot read.

PERMISSIONS
- Camera: scan the pairing QR code, or take a photo to attach to a message.
- Photos: choose images to attach to a message.
- Local network (iOS): connect directly to the user's computer on the same network.
- Notifications: alert the user when an agent needs approval or has finished.

A demo video of pairing with a real computer is attached.

---

## 中文

DogCodes 是免费桌面应用 DogCodes（https://dog.codes）的手机端。它连接用户自己的电脑；Claude Code、Codex 等编程 Agent 在电脑上运行。手机用来查看这些对话、发送新指令、处理权限请求、审查代码改动。App 没有账号，无需注册，也没有任何付费。

无需电脑即可审核
1. 打开 App，在首屏底部点「先看看示例」。
2. App 会打开一台虚构的"示例电脑"。每个页面顶部都有橙色的「示例模式」横条和「退出示例」按钮。
3. 可以体验：
   - 会话：打开任意会话，输入并发送消息，几秒后会出现模拟的 Agent 回复。
   - 待处理：回答"为购物车添加单元测试"中的问题，或在"完善商品搜索体验"中允许或拒绝命令，Agent 会在会话中继续。
   - 项目：浏览文件和代码改动，打开终端，预览运行中的网页。
   - 电脑：打开远程桌面，查看示例画面。
4. 点「退出示例」回到首屏。

示例模式不会连接任何设备。所有数据都是虚构的，只保存在内存中，退出即丢弃。会改动真实电脑的操作（如提交代码）会提示需要先连接电脑。

实际使用方式
用户在电脑上安装 DogCodes 桌面应用，点「连接手机」，再用本 App 扫描二维码。连接端到端加密。数据在手机和电脑之间直连传输，或经我们的中继服务器转发；中继只转发它无法解读的加密数据。

权限说明
- 相机：扫描配对二维码，或拍照作为消息附件。
- 照片：选择图片作为消息附件。
- 本地网络（iOS）：在同一网络下直接连接用户自己的电脑。
- 通知：Agent 需要审批或完成任务时提醒用户。

附件中有连接真实电脑的演示视频。

---

## Still to decide

- **Export compliance.** `ios/Runner/Info.plist` does not set `ITSAppUsesNonExemptEncryption`, so App Store Connect asks about encryption on every upload. The app uses encryption for its end-to-end connection. Decide the answer, ideally with someone who knows your export situation, then set the key so the question stops repeating.
- **Demo video.** Record pairing and one round trip (send a message, approve a request) on a real phone and computer. Attach it under App Review Information, and add the link for Google Play.
- **Privacy labels.** Declare "Device ID, used for app functionality, not linked to identity, not used for tracking" in App Store Connect and in Google Play's Data safety form, matching `ios/Runner/PrivacyInfo.xcprivacy`.
- **Wording check.** The button and banner names above match the app's English and Simplified Chinese text. If the reviewer's device uses another language, the labels will be translated.
