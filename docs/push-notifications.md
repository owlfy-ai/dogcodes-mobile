# 后台提醒

当前策略：**iOS 直连 APNs；具备可用 Google Play 服务且 FCM 注册成功的 Android 优先直连 FCM；华为 Android／仍能运行 APK 的华为系统优先直连 HMS；无法注册直连通道的 Android 使用 EMAS。** 本策略取代此前统一使用 EMAS 的方案。iOS 不初始化 EMAS，Android 直连成功也不初始化 EMAS，服务端分别直接调用 Apple、Google、华为接口，避免这些通知经过 EMAS。

四类提醒为待审批、待回答、任务完成、执行失败，保留每部手机的电脑／会话静音偏好。通知只带 notificationId、hostId、taskId、kind；点击后核实原绑定并读取电脑当前状态，不自动审批或执行任务，普通到达不会跳页。

## 手机端配置

### iOS：APNs

无需 EMAS AppKey 或 Firebase SDK。已有 Runner.entitlements 的 aps-environment：Debug 为 development，Profile/Release 为 production。Apple 开发者后台需为 `codes.dog.mobile` 启用 Push Notifications，并使用匹配的签名与 provisioning profile；服务端 topic 必须相同，sandbox 须匹配构建环境。首次用户启用提醒才申请系统通知权限，恢复已启用状态不再次请求授权。每次登记都向 APNs 请求当前 device token，APNs 回调由本项目原生桥接处理，不转给 EMAS。

### Android：直连 FCM／HMS，EMAS 备用

将 `config/android-push.properties.example` 复制到被忽略的 `private/android-push.properties`。只填实际申请过的通道，任一组部分填写会导致构建失败。

- FCM 的四个 `dogcodes.push.fcm.*` 字段来自 Firebase Android App 的配置：sender_id 为 project_info.project_number，project_id 为 project_info.project_id，app_id 为匹配包名客户端的 mobilesdk_app_id，api_key 为该客户端的 current_key。数值 sender_id 使用示例的 `id=` 前缀，避免 Manifest 将其解释为数值。包名为 `codes.dog.mobile`。
- HMS 的 `com.huawei.hms.client.appid` 使用 `appid=...`。华为开发者后台需要为同一 Android 包名启用 Push Kit，并登记实际签名指纹；仅写入 App ID 不代表账号／签名校验已经通过。荣耀使用独立荣耀通道，不仅凭旧品牌关系归为 HMS。
- 其它厂商参数用于 EMAS 的小米、荣耀、OPPO、vivo、魅族通道。FCM／HMS 的消息服务由本项目直接接管，不再向 EMAS 注册这两个辅助通道。

Gradle 从上述私有配置生成 Manifest 和 Firebase 的四项 Android 字符串资源。冷启动 FirebaseInitProvider 可以读取同一配置；FCM 和 HMS 的 token 自动初始化在 Manifest 中关闭。用户启用后台提醒后才显式注册，FCM 成功后启用其 token 更新。原生服务在 Flutter 引擎未启动时也能接收 token 更新和通知；前台通知使用固定 `dogcodes_tasks` 通道，点击参数交给统一的会话定位流程。

只有需要 EMAS 备用时，才把 `config/push-defines.example.json` 复制到 `private/push-defines.json`，填写 Android AppKey/AppSecret，并给 Flutter 构建命令加 `--dart-define-from-file=private/push-defines.json`。不使用 EMAS 的构建可省略这些参数。RAM AccessKey、APNs p8、Firebase 服务账号和 HMS 服务端密钥均不得打包进 App。

CI／隔离构建可用 Gradle 项目属性 `dogcodesPushProperties` 指定另一份配置文件，默认仍读取上述私有路径。本地测试仅使用无效示例参数进行编译，不发起真实注册。

## 选择、更新与失败边界

选择依据为原生 GMS／HMS 可用性、已配置参数和实际 token 注册结果，语言、IP 或品牌不会单独决定 FCM 可用性；华为优先 HMS 是明确的产品规则。登记、恢复及 token 变化时重新核对能力。直连注册有期限，失败尝试下一个可用通道，Android 最后尝试已配置的 EMAS；拒绝通知权限不会触发其它 SDK 兜底，iOS 的 APNs 失败不改走 EMAS。

每部手机在每台绑定电脑上仍只有一个当前 provider/token，切换复用原版本化更新和回执，保留静音及四类开关。provider 与 token 作为同一结果保存，SDK token 更新会触发重新登记；应用暂停期间的更新在恢复后重新读取。点击按 notificationId 去重并核实绑定，解除绑定后的通知不能执行操作。

**token 注册成功不是网络送达证明。** Google Play 服务存在、获取到缓存 token，都不保证当前网络能收到 FCM。当前失败兜底针对注册失败，不用“用户没有点击”判断投递失败，也不同时通过两家发送同一通知。中国大陆／海外真实网络、厂商限制与后台送达仍需实机验收。

## 服务端

`dogcodes-server/config/push.example.json` 包含四个 provider：

- `apns`：Apple keyId、teamId、topic、p8 文件路径、sandbox。
- `fcm`：Firebase 服务账号文件路径，使用 HTTP v1。
- `hms`：华为 appId、服务端密钥文件路径及 Android packageName；通知通过显式 Activity Intent 携带转义后的会话提示。
- `emas_android`：Android EMAS AppKey、RAM 凭据路径及固定通知通道／辅助弹窗参数。

手机上报的是所选 provider 对应的原生 token；只有 `emas_android` 上报 EMAS deviceId。服务器凭据只留在服务端，手机登记仍使用原配对 routeToken、expectedRevision 和 operationId。共享 OAuth／APNs 签名缓存继续使用 Redis，业务登记与通知 outbox 继续使用 PostgreSQL。

## 鸿蒙范围

本次支持 iOS 和 Android，包括仍支持 APK 的华为设备。纯原生鸿蒙另列阶段：可以评估 OpenHarmony-SIG 的 Flutter 移植版来复用 Dart 界面，但需单独构建鸿蒙包，并适配 WebRTC、视频／Rust FFI、安全存储、扫码等原生依赖以及 HarmonyOS Push Kit。现有 Android HMS SDK 及发送参数不能据此当作纯原生鸿蒙支持。

## 本地验证与未完成项

当前直连路由、注册失败兜底、权限拒绝、通道替换保留静音和 APNs 点击载荷已有手机回归；Android 带无效测试配置／空配置及 iOS 模拟器目标均进行原生编译，未运行设备或发起真实推送。Android 带配置产物另核对本项目 FCM／HMS 服务、EMAS 对应服务移除以及四项 Firebase 冷启动资源。服务端有 HMS Intent 编码和配置专项。

完整测试数及日志见 docs/next-steps.md 最新记录。原开发 PostgreSQL 仍为不支持的旧格式，未升级、清空或迁移；数据库测试使用独立空库，结束后删除本次数据库和专属 Redis key。真实 APNs／FCM／HMS／EMAS 凭据、签名、真机收件、后台／强退点击、国内外网络及厂商送达范围未验收。

官方资料：[Firebase Android 接入与 Google Play 服务要求](https://firebase.google.com/docs/cloud-messaging/android/get-started)、[华为 Flutter Push 插件（Android）](https://pub.dev/packages/huawei_push)、[鸿蒙 Flutter 移植项目](https://gitee.com/openharmony-sig/flutter_flutter)、[HarmonyOS Push Kit](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-kit-introduction)。
