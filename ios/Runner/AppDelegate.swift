import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeWorkspaceFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
