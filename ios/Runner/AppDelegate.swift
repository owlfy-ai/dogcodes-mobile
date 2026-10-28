import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var apnsToken: String?
  private var apnsResult: FlutterResult?
  private var apnsTimeout: DispatchWorkItem?
  private var initialPush: [AnyHashable: Any]?
  private var pushPermissions: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeWorkspaceFromBackup()
    if application.applicationState != .background,
       let notice = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
       let aps = notice["aps"] as? [String: Any], aps["alert"] != nil {
      initialPush = notice
    }
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    UNUserNotificationCenter.current().delegate = self
    return launched
  }

  /// Cached conversations, drafts and draft attachments (LocalWorkspace's
  /// `workspace-v1`) stay on this phone; iCloud and computer backups skip them.
  private func excludeWorkspaceFromBackup() {
    let fileManager = FileManager.default
    guard
      var url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("workspace-v1", isDirectory: true)
    else { return }
    do {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
    } catch {
      NSLog("DogCodes: workspace backup exclusion failed: \(error)")
    }
  }

  private func registerApns(_ result: @escaping FlutterResult) {
    guard apnsResult == nil else {
      result(FlutterError(code: "push_busy", message: "通知注册正在进行。", details: nil)); return
    }
    apnsResult = result
    let timeout = DispatchWorkItem { [weak self] in
      self?.finishApns(error: FlutterError(code: "push_timeout", message: "APNs 暂不可用。", details: nil))
    }
    apnsTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    // Ask APNs on each registration; never treat an old token as proof that
    // registration still works after restoring or reinstalling the app.
    UIApplication.shared.registerForRemoteNotifications()
  }

  private func finishApns(error: FlutterError? = nil) {
    apnsTimeout?.cancel(); apnsTimeout = nil
    let result = apnsResult; apnsResult = nil
    if let error = error { result?(error) } else { result?(apnsToken) }
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    let changed = apnsToken != token
    apnsToken = token
    finishApns()
    if changed { pushPermissions?.invokeMethod("registrationChanged", arguments: nil) }
    // This token is owned by our APNs provider; do not forward it to EMAS.
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    finishApns(error: FlutterError(code: "push_unavailable", message: "APNs 注册失败。", details: nil))
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound, .badge])
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    if response.actionIdentifier != UNNotificationDismissActionIdentifier {
      let payload = response.notification.request.content.userInfo
      initialPush = payload
      pushPermissions?.invokeMethod("opened", arguments: payload) { [weak self] reply in
        if !(reply is FlutterError), (reply as? NSObject) !== FlutterMethodNotImplemented,
           NSDictionary(dictionary: self?.initialPush ?? [:]).isEqual(to: payload) {
          self?.initialPush = nil
        }
      }
    }
    completionHandler()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DogCodesPushPermissions") else { return }
    pushPermissions = FlutterMethodChannel(name: "dogcodes_push_permissions", binaryMessenger: registrar.messenger())
    pushPermissions?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "capabilities": result(["apns": true])
      case "authorize":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { allowed, _ in
          DispatchQueue.main.async { result(allowed) }
        }
      case "register_apns": self?.registerApns(result)
      case "initialNotification":
        result(self?.initialPush)
        self?.initialPush = nil
      case "allowed":
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          DispatchQueue.main.async {
            result(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral)
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}
