# dog.codes 手机端开发指南

[返回首页](../README.md) · [简体中文说明](i18n/README.zh-CN.md)

## 实现与开发记录

2026-10-21：會話已支援置頂、歸檔/取消歸檔、選擇歷史輪次 Fork（當前工作區或新 Worktree）、按電腦/項目範圍搜索已保存的正文並分頁、從結果打開對應輪次。置頂/歸檔使用 PC 共享設定，保留其他項目、排序及會話狀態；Fork 和設定變更寫前保存原請求，斷線後可核實或用同一身份重試。增量回答直接合併事件，補強長回答緩衝、舊連線快照拒絕及多項目訂閱。使用與限制見 [接續清單](next-steps.md#2026-10-21-會話組織fork-與歷史搜索)。

设备级剪贴板已支持手动双向文字和图片：从远程桌面工具栏操作，图片传输采用独立连接及小块校验，失败不自动重复写入；无需依赖屏幕采集成功。复制仍遵循系统前台/粘贴授权，跨设备与弱网验收待完成。详见 [后续工作](next-steps.md)。

已接入 WebRTC DataChannel：先建立加密中繼，再自動嘗試 P2P；可使用服務下發的 TURN，直連中斷時回退 WSS。電腦頁顯示實際路徑，切換不自動重發操作。詳見 [直連與回退](p2p-transport.md)。

「工作區」及「新會話」可添加 PC 上已有目錄為項目：支援電腦選擇、目錄瀏覽/分頁、直接輸入路徑及可選名稱；已有項目複用，回覆丟失後保留原請求供核實/明確重試。目錄來自 PC，不使用手機檔案選擇器。

會話統一顯示，移除「當前會話／已歸檔」篩選，保留歸檔狀態及操作。每輪結束後的底部提供複製最終回覆、本輪消耗、從本輪 Fork，以及審查底部面板；支援審查 Agent 選擇、代碼/安全/性能檢查、問題與代碼證據、取消/重新檢查、交給主 Agent 修復及修復後復審。審查和修復原請求在發送前保存，斷線後先核實原結果。

任務附件可選照片、拍照、手機文件或電腦項目文件；沿用 PC 限制（最多 16 個、合計 25 MB），分塊上傳可暫停/原身份續傳，回執與內容雜湊核實後才發送。草稿按電腦/項目/會話保存文字、Agent/模型/思考強度及附件，離線可繼續編寫，重連不自動發送；僅已確認提交的原草稿會清空。最近 30 個已打開會話自動快取文字及附件資訊（總上限 32 MB），離線標明同步時間，可在偏好設定清除，保留草稿/未發送附件/配對。

端點使用共用 Rust Noise 庫，原生打包進手機；密鑰與配對資訊進入系統安全存儲。手機固定 PC 公鑰，PC daemon 將已認證手機識別為 PairedDevice，服務僅路由密文字節。任務結果未知時保留原輸入與 operationId，由使用者核實/重試，不自動重發。

## 中英文界面与 App Store 素材

手机端支持简体中文和英文，按系统语言偏好选择；其他语言回退英文。覆盖页面、菜单、提示、权限选项、系统控件及 iOS 相机/照片/局域网权限说明。用户对话、代码、路径和 Agent 返回的业务内容保留原文。修改英文资源后运行 `python3 tool/l10n/generate.py`，占位参数校验与语言切换测试位于 `test/localization_test.dart`。

App Store 中英文各 8 张详情图，分别导出两种 iPhone 尺寸和 13 英寸 iPad 尺寸。上传包与预览见 [store/v2](../store/v2/README.md)，生成脚本位于 `tool/store/`，示例数据与个人电脑隔离。

## 線上連接

桌面端與手機端的新配對預設使用 `https://global.dog.codes`，debug 與 release 相同，WebSocket 使用對應的 `wss://global.dog.codes`。桌面側邊欄打開「连接手机」後自動生成並顯示二維碼，過期自動更新，無需點擊生成按鈕；手機在「连接电脑」掃碼即可。不需要先啟動本機 server，也無需額外傳入 `--dart-define`。

已保存的配對綁定原服務地址，不會把舊服務憑據自動發往新服務。桌面端原先使用其他服務時，新版本在 `remote/services/global.dog.codes` 使用獨立配置，舊配置與配對記錄保留；已經使用線上服務的原配置繼續沿用。切換服務需重新配對；手機保留的舊電腦記錄仍按原地址重連，可從手機移除後重新掃碼。普通桌面配對頁固定使用線上服務，不提供地址輸入框。桌面端採用單一執行個體；Core 隨桌面端啟動及退出。手機遠端連線需要桌面端保持開啟或最小化，關閉主視窗會中斷連線及正在執行的工作；有活動工作時會先要求確認。以下本機流程供隔離 PC fixture 驗收使用。

## 開發與本機配對

已驗證 Flutter **3.47.7** / Dart **3.13.5**（`.fvmrc`）；另需 Rust、對應 Rust target、Xcode/iOS runtime 或 Android SDK/NDK。Android 當前原生庫僅支援 ARM64，NDK 固定 **28.2.13676358**，可在 Android Studio SDK Manager 安裝。構建腳本不自行安裝 SDK 或接受授權。

```sh
flutter pub get --enforce-lockfile
# 按開發平台安裝需要的 target
rustup target add aarch64-linux-android
rustup target add aarch64-apple-ios-sim aarch64-apple-ios
# Intel Mac simulator 另需 x86_64-apple-ios
flutter run -d YOUR_SIMULATOR_ID
```

Gradle/Xcode 構建階段自動執行 `tool/build_endpoint.py`，將 Rust `.so` / 靜態庫打包，產物不入庫。無需把動態庫路徑傳給手機 App。桌面測試用動態庫才需要 `DOGCODES_ENDPOINT_LIBRARY`。

1. 在獨立 `dogcodes-server` 工程按其 README 啟動本機服務（預設 8787）。
2. 使用 gateway 驗收工具啟動隔離 PC fixture，傳入 `http://127.0.0.1:8787` 並取得配對連結（具體入口見 server README）；普通桌面配對頁使用線上服務。
3. App 使用 `flutter run --dart-define=DOGCODES_SERVICE_URL=http://127.0.0.1:8787`，與 PC 使用相同 service origin；iOS 使用回環，Android 模擬器傳輸自動改走 `10.0.2.2`，QR 驗證/Noise context 仍綁定 `127.0.0.1`，勿將二維碼內容改成另一地址。
4. App 選「连接电脑」掃碼；模擬器無相機時可在 PC 複製配對連結，於 App 貼上。離開 PC「连接手机」頁面會取消該頁尚未完成的邀請。
5. 配對成功後選 PC 現有項目/會話、Agent/模型/思考強度並發送；權限審批在會話內處理。離開頁面不會停止 PC 任務；回到設備列表可重新連接。PC 設備列表可撤銷已配對手機。

隔離 PC fixture 的真機局域網 debug：手機與電腦連同一 Wi-Fi，fixture 使用 `http://電腦局域網IP:8787`，App 使用完全相同的 service origin：

```sh
flutter run --debug --dart-define=DOGCODES_SERVICE_URL=http://192.168.1.100:8787
# 使用 Xcode Run 前，可先生成含同一地址的開發配置：
flutter build ios --debug --config-only --dart-define=DOGCODES_SERVICE_URL=http://192.168.1.100:8787
```

服務端 compose 的私有 `.env` 設定 `DOGCODES_SERVER_BIND=192.168.1.100`（替換為電腦 IP），再重建 server 容器；只對局域網開放公共 8787，管理端與資料庫仍綁定回環。debug HTTP 僅接受回環或 RFC1918 字面 IP；release 仍只接受 HTTPS。不要手動改二維碼的 service，它也參與 Noise 身份驗證。由回環改為 LAN 後，移除手機上尚未成功的舊本機配對記錄，重新掃描 PC 新產生的二維碼。

正式/跨網真機預設連接線上入口，也可顯式指定：

```sh
flutter run --dart-define=DOGCODES_SERVICE_URL=https://global.dog.codes
```

Release 不使用本機 HTTP，預設使用上述線上地址；Android 僅 debug manifest 開放明文開發流量。Release 簽名/Team 仍由維護者私下設定；`.env.example` 只說明欄位，不自動載入。管理令牌、私鑰、配對 secret 不得編進 App 或貼入日誌。

## 真實 UI 端到端（模擬器）

PC 網關在 DogCodes `remote-control` 分支。啟動本機 server 與隔離 PC fixture（合成 Agent，不讀使用者資料）後，把 fixture 產生的配對連結傳給 UI 測試；測試在真實 App 介面完成配對→新任務→串流→審批→追問→停止：

```sh
flutter test integration_test/pc_control_test.dart -d YOUR_SIMULATOR_ID \
  --dart-define=DOGCODES_E2E_INVITATION='dogcodes://pair#…'
```

測試使用系統安全存儲，跑完後模擬器保留該配對；可在「電腦」頁「從手機移除」。

## 驗證

```sh
flutter analyze
python3 tool/build_endpoint.py host
# macOS；Linux 使用 .so
DOGCODES_ENDPOINT_LIBRARY="$PWD/native/endpoint/target/debug/libdogcodes_endpoint.dylib" \
NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 flutter test
# 實際系統安全存儲與打包庫驗收（使用隔離測試 key）
NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 \
  flutter test integration_test/endpoint_test.dart -d YOUR_SIMULATOR_ID
```

本機證據：包含原生 FFI 的 Dart/Widget/傳輸狀態機測試通過；iOS、Android 模擬器各通過原生庫/系統安全存儲測試及真實 P2P/加密任務/串流/中繼回退驗收。未設動態庫路徑時 FFI 測試會明確 skip，不能把 skip 計為通過。重現 P2P 驗收見 [傳輸說明](p2p-transport.md)。模擬器測試不等同於相機真機、TURN 或跨網驗收。

完整 gateway 驗收見 server README：啟動隔離真實 PC Core 與合成 Agent，使用本工程生產通道/請求實作，驗證單次提交、串流、審批、重連及撤銷。無須真實模型帳號，不觸碰使用者資料。

## 結構與接續

- `lib/core/adaptive_host_link.dart` / `rtc_transport.dart`：P2P/TURN 協商、路徑切換和中繼回退。
- `lib/core/secure_host_client.dart`：Noise 端點通道、長度分塊、請求與事件、有界傳輸。
- `lib/core/mobile_operations.dart`：寫前保存原操作、結果核實、明確重試/放棄與審批版本栅欄。
- `lib/core/security/`：FFI、手機身份與配對安全存儲。
- `lib/ui/`：依 [手機 UI 設計](design/mobile-2026-10-18/README.md) 的色彩/尺寸 tokens（純白/純黑畫布、PC 綠色點綴）與共用元件。
- `lib/core/host_hub.dart`：每台已配對電腦一條連線，聚合跨電腦會話、待審批與待核實操作；離線保留最後同步內容並標明時間。
- `lib/features/`：底部四入口「會話／工作區／待處理／電腦」，及對話、新會話、配對、偏好設置。
- `lib/data/local_workspace.dart`：手機私有目錄中的草稿、受管理附件副本及有界離線快取；操作回執及配對密鑰仍走安全存儲。
- `native/endpoint/`：規範源來自 PC `crates/remote-endpoint` 的版本化快照；[構建及同步](../native/endpoint/README.md)。
- [接續清單](next-steps.md)：結構化問答、完整會話操作、Git/Diff、文件附件、終端/運行/預覽、離線/通知、媒體遠控。

首次配對 ACK 丟失的在線回執查詢尚未接入，目前須在 PC 重新生成二維碼。權限選項審批、結構化提問（JSON schema 子集：單/多選、文字、數字、是否）與停止任務已接入；超出子集的問題提示在電腦回答。文件、變更/Git、終端、運行、網頁預覽、基礎遠程桌面、保持喚醒、本輪 AI 審查、附件上傳、草稿及持久離線快取已有手機頁面；背景通知已接入 EMAS 设备登记、静音及点击定位代码，凭据/真机验收仍待；见 [通知配置](push-notifications.md)。基礎遠控不代表已交付高效媒體或三平台完整實機驗收。

RustDesk Flutter 僅參考掃碼、生命週期與遠控輸入分層，未複製其 UI、資產、FFI 或協議。
