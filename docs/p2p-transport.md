# 手機端直連與中繼

2026-10-19。入口是 `MobileRuntime`，每台電腦一條 `AdaptiveHostLink`；頁面與 `MobileOperations` 只依賴 `HostLink`，不需要自行選路。相機仍僅用於掃碼；DataChannel 不申請麥克風或視訊採集權限。

## 建立及切換

1. 掃碼完成並持久保存可信 PC 公鑰、手機身份及路由憑據，或從已有配對重新建立加密 WSS。主介面可立即工作。
2. 在已認證連線查詢 `remote_capabilities`。支援 `direct_open` 時，向同一可信官方 service 的 `/v1/hosts/{id}/ice` 取得 ICE 配置與短期 TURN 憑據；不把共享 TURN secret 編入 App。舊 PC 或未提供 ICE 的服務繼續使用中繼。
3. `flutter_webrtc` 建立可靠、有序的 `dogcodes-v1` DataChannel，完整收集 offer，透過原加密 RPC 取得 answer。核對 `noiseContext = ["dogcodes-direct",1,hostId,connectionId,"business"]`，不接受另一台 PC/用途的 context。
4. 新 DataChannel 上以原手機身份及固定 PC 公鑰進行**全新 Noise XX 握手**，核對 ACK 的 hostId、binding、connectionId、purpose，再查詢實際路徑。WSS 與 WebRTC 不共用 session、計數器或 nonce。
5. 新路徑認證完成後才切換。仍在原中繼上等待的操作回執繼續等待，最後一個請求結束後關閉舊連線。`transport_changed` 使 HostHub 清除舊項目訂閱、重取 bootstrap 並從新游標訂閱；用連線代次忽略舊連線延遲回來的快照。
6. 協商失敗保留原中繼，兩分鐘後可再嘗試。直連中斷則重新申請中繼房間、重新認證，最多三次；失敗後顯示離線和「重新連接」。App 回到前台會核實連線並在需要時重連。主動斷開或移除設備不會被遲到的候選連線復活。
7. TURN 憑據到期前嘗試重新協商；新通道未認證時保留原通道。新協商始終產生新的 Noise session。

| 電腦頁標籤 | 資料路徑 |
|---|---|
| P2P 直連 | 手機 ↔ WebRTC DataChannel ↔ PC，業務資料不經雲端中轉 |
| TURN 中繼 | 手機 ↔ TURN ↔ PC，仍是 WebRTC DataChannel，底層傳輸由 ICE 配置/網路決定 |
| 加密中繼 | 手機 ↔ WSS 業務中繼 ↔ PC |
| WebRTC · 路徑待確認 | 已完成認證，但 selected candidate pair 尚未確定；不宣稱 P2P |

**PC TURN 已補齊：**`remote-control` 已加入 TCP 與 TLS over TCP，保留 UDP；TLS 校驗憑證鏈及伺服器名稱。實作與強制中繼驗收見 [PC 傳輸說明](../../DogCodes-remote-control/docs/implementation/turn-stream-transports-2026-10-19.md)。手機三種 TURN 傳輸與 PC 的組合仍需正式節點及真機跨網驗收；WSS 保留兜底。

P2P 仍使用官方服務進行在線定位和初始協商，不表示可以不部署服務。跨網打洞需要可達的 STUN；直連受 NAT/防火牆影響，TURN/WSS 提供回退。只配置本機服務且沒有 ICE 伺服器時仍可嘗試局域網候選位址。

## 不確定結果與資源限制

- 切換後**不重播任何失敗 RPC**。任務、Git、審批等副作用仍使用原 operationId/receipt 核實；終端輸入、鍵鼠、預覽 POST/WS 不能因重連自動發送第二次。恢復連線和重做操作是兩件事。
- 所有連線沿用 4-byte big-endian JSON 長度幀及 8 MiB 單請求上限。加密前每塊 16000 bytes，密文不超過 SCTP 的 16384 bytes；併發請求按完整幀序列化，保持 Noise counter 和 JSON 分片順序。
- WebRTC 原生發送積壓以 256 KiB 作等待水位，等待有超時；未消費的接收佇列最多 1 MiB。這些是瞬時背壓與單訊息保護，沒有累計 64 MiB 斷線閾值。
- 本輪接入現有業務通道。手機的檔案/Git/終端/運行/畫面/附件頁面仍需各自接入後端 API；未因此自動完成所有桌面能力。新增桌面 lease、預覽、watch、附件專用通道時必須在物理連線切換後重新建立資源，不沿用舊 connection-owned ID。

## 可重現驗證

需要 Docker 開發 PG/Redis、已編譯 server，以及 PC `remote-control` 分支的 `remote-acceptance` fixture。執行使用隨機 namespace、臨時 PC 資料夾與合成 Agent，手機身份僅存記憶體；不讀使用者的實際項目或模型帳號。

```sh
python3 tool/p2p_acceptance.py --flutter /path/to/flutter --device IOS_SIMULATOR_UUID
python3 tool/p2p_acceptance.py --flutter /path/to/flutter --device emulator-5554
# 可用 --server /path/to/dogcodes-server --desktop /path/to/remote-acceptance
# DOGCODES_TEST_DATABASE_URL / DOGCODES_TEST_REDIS_URL 指向隔離的測試服務。
```

測試在原生 App 啟動之後才取得新 QR，驗證配對、真實原生 DataChannel、全新 Noise 認證、超過 16 KiB 的任務/串流、真實關閉 DataChannel 後回退、PC 上只建立一次任務、原待審批仍存在。

單元測試覆蓋協商失敗保留中繼、舊請求回執排空、斷線單次重連/禁止重放、遲到候選清理、舊 PC 相容、TURN/unknown 顯示、訂閱重建/延遲快照失效、真實 FFI 併發加密分片、ACK 綁定與密文篡改。Android 模擬器測試發現數秒時鐘差會誤拒新 QR，故僅對「過遠的未來有效期」加 30 秒時鐘容差；不延長服務端原到期時間，已過期 QR 仍拒絕。

本機驗證：`flutter analyze` 與格式檢查通過，35 項 Dart/Widget/傳輸測試全部通過（含實際原生 FFI，無 skip）。iOS 27 的 iPhone 18 Pro 模擬器、Android API 37 ARM64 模擬器各通過上述完整 P2P/回退驗收；同時以純 Dart gateway 驗證既有 WSS 配對/任務/審批/停止/額度/重連/撤銷鏈路。

模擬器互通不能替代真機前後台、Wi-Fi/移動網路切換、跨 NAT、TURN UDP/TCP/TLS、官方大陸/海外節點與撤銷壓測，這些仍需正式部署後驗收。
