# DogCodes endpoint security (0.1, integration stage)

端點共用 Rust 模組，`rlib` 供 PC 網關使用，`cdylib/staticlib` 供 Flutter FFI。這裡包含端點私鑰和會話狀態，**不能部署到官方中繼程序中**。規範源位於 PC 工程 `crates/remote-endpoint`；此目錄為同版本獨立可構建快照，來源/逐文件 SHA-256 記於 `source.json`，無跨倉庫絕對路徑構建依賴。同步使用 `python3 tool/sync_endpoint.py`，兩倉並存時以 `--check` 驗證。PC 使用 `default-features=false` 不編入 C ABI。

## 已實作

- Snow 0.10：首次配對 `Noise_XXpsk3_25519_ChaChaPoly_SHA256`，重連 `Noise_XX_25519_ChaChaPoly_SHA256`。
- 手機在傳出第三段握手前驗證 QR 內 PC X25519 公鑰；首次 PC 依短期 QR 的 32-byte PSK 驗證手機，完成後記錄其靜態公鑰。重連雙方必須提供已保存對端公鑰。
- 握手 payload 固定為空；業務/配對回執在握手完成後加密傳輸。不同用途的 prologue 隔離配對與重連；配對 prologue 見 Dart `pairingContext`。
- 任一加密/協議狀態錯誤終止 Session；使用 Snow 的順序 nonce 拒絕重放/亂序；每個密文最多 65535 bytes，明文最多 65519 bytes。上層業務訊息採 4-byte 長度前綴與 32768 bytes 明文分塊，最大 8 MiB。
- Host `PairingBook`：過期、取消、QR 再生成（含同 ID 新 epoch）、競爭消費、同設備回執核實；公開身份/授權 revision 持久化。撤銷後每次 `check(lease)` 拒絕舊連線；重新授權也不復活舊 lease/舊邀請回執。
- 寫入使用同目錄暫存 + flush + rename，Unix 另同步父目錄；寫入失敗後當前實例停止授權。遇到未完成 `.pending` 或損壞檔案時拒絕載入，不自動清空或忽略。PC daemon 將是唯一寫入者；本模組沒有多程序鎖或自動修復策略。
- C ABI 只有 JSON 呼叫/釋放兩個入口；最多 64 個活躍 Session，輸入有界；不輸出私鑰或握手內容到日誌。FFI allocator 的輸入/輸出私有緩衝會清零；不宣稱 Dart GC 字串或第三方密碼庫所有記憶體可保證立即清零。

手機 `DeviceIdentityStore` 使用系統安全存儲介面（iOS this-device keychain；Android 插件安全存儲），同時初始化只建立一個身份，讀取失敗/損壞時不悄悄輪換。`TrustedHostStore` 在已認證通道解密的配對回執匹配 host/phone key、invitation、binding、revision 後才保存 PC pin；同 hostId 換 key/service 被拒絕。

## 驗證

```sh
cargo test --manifest-path native/endpoint/Cargo.toml --locked
cargo clippy --manifest-path native/endpoint/Cargo.toml --locked --all-targets -- -D warnings
cargo build --manifest-path native/endpoint/Cargo.toml --locked
```

Dart 測試在 App 根目錄執行（Linux 使用 `.so`，macOS 使用 `.dylib`）：

```sh
DOGCODES_ENDPOINT_LIBRARY="$PWD/native/endpoint/target/debug/libdogcodes_endpoint.dylib" \
NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 flutter test
```

原生測試 9 項（8 項狀態/持久化/錯誤測試 + 1 項含兩套協議的 known-answer fixtures）；Dart 新增 3 項原生 FFI/identity/配對確認測試。CI Linux 設置原生庫路徑，不跳過這三項。未設路徑的普通 Flutter 測試會明確 skip 原生組。

`tests/fixtures/noise-vectors.json` 為 Snow 0.10 隨附的 Cacophony **公開合成測試向量**子集；來源 commit/路徑在檔案內。固定 ephemeral 僅在向量測試使用，不暴露給生產建構介面。

## 平台整合與邊界

已接入 PC daemon 與手機 UI；Gradle/Xcode 執行 `tool/build_endpoint.py` 自動打包。Android ARM64、iOS simulator 原生編譯通過，兩模擬器的 Noise/真實系統安全存儲整合測試通過；Windows/Linux PC keyring/journal、iOS/Android 真機尚待實測。iOS device target 已納入腳本，簽名真機構建未驗收。

已接入 PC 網關的規則：在發出 paired ACK 前落盤；每條業務/事件交付檢查 lease、撤銷時關閉通道；使用可信 PairedDevice RequestContext；拒絕任意遠端指定身份；只從系統安全存儲取 PC 私鑰。手機必須保存回執後才呈現已配對，ACK 丟失核實原邀請的底層 journal 已實作，但在線回執查詢尚未接入，目前需重新生成 QR；不能自動發出業務命令。兩端封裝加密通道之前，`RelayProbe` 仍不能充當 `AuthenticatedHostChannel`。

參考：[Noise 規格](https://noiseprotocol.org/noise.html)、[Snow API](https://docs.rs/snow/0.10.0/snow/)、[Flutter Secure Storage](https://pub.dev/packages/flutter_secure_storage)。本項目只封裝現成實作，不自行實作密碼算法；本輪測試不等同獨立安全審計。
