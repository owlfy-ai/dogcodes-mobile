import Flutter
import UIKit
import ImageIO

public final class DogcodesClipboardPlugin: NSObject, FlutterPlugin {
  private var writes = Set<String>() // Main-thread owned, including cancellation.
  private let worker = DispatchQueue(label: "dogcodes.clipboard.image")
  private static let maxBytes = 16 * 1024 * 1024
  private static let maxPixels: Double = 8 * 1024 * 1024

  public static func register(with registrar: FlutterPluginRegistrar) {
    registrar.addMethodCallDelegate(DogcodesClipboardPlugin(), channel:
      FlutterMethodChannel(name: "dogcodes/clipboard", binaryMessenger: registrar.messenger()))
  }
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "cancelWrite" {
      let id = (call.arguments as? [String: Any])?["id"] as? String ?? ""
      result(writes.remove(id) != nil); return
    }
    guard UIApplication.shared.applicationState == .active else {
      result(FlutterError(code: "foreground", message: "请回到 App 后操作剪贴板", details: nil)); return
    }
    switch call.method {
    case "readPng":
      // UIKit performs the permission check on this explicit read. Never poll.
      guard let image = UIPasteboard.general.image else { result(nil); return }
      let width = image.size.width * image.scale, height = image.size.height * image.scale
      guard width.isFinite, height.isFinite, width > 0, height > 0,
        width * height <= Self.maxPixels else { invalid(result); return }
      worker.async {
        autoreleasepool {
          // Drawing normalizes orientation (including copied camera images).
          let format = UIGraphicsImageRendererFormat(); format.scale = 1
          let size = CGSize(width: width, height: height)
          let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
          }
          let data = normalized.pngData()
          DispatchQueue.main.async {
            guard let data, data.count <= Self.maxBytes else { self.invalid(result); return }
            result(FlutterStandardTypedData(bytes: data))
          }
        }
      }
    case "writePng":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let id = args["id"] as? String, !id.isEmpty, id.count <= 128,
        let data = (args["png"] as? FlutterStandardTypedData)?.data,
        !data.isEmpty, data.count <= Self.maxBytes, writes.count < 2,
        writes.insert(id).inserted else { invalid(result); return }
      worker.async {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard let source, (CGImageSourceGetType(source) as String?) == "public.png",
          width > 0, height > 0, width * height <= Self.maxPixels,
          CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
          DispatchQueue.main.async { self.writes.remove(id); self.invalid(result) }; return
        }
        DispatchQueue.main.async {
          guard self.writes.remove(id) != nil else {
            result(FlutterError(code: "cancelled", message: "图片复制已取消", details: nil)); return
          }
          guard UIApplication.shared.applicationState == .active else {
            result(FlutterError(code: "foreground", message: "App 已进入后台，未写入手机剪贴板", details: nil)); return
          }
          // Keep it on this phone; Universal Clipboard must not forward it.
          UIPasteboard.general.setItems([["public.png": data]], options: [.localOnly: true])
          result(nil)
        }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }
  private func invalid(_ result: FlutterResult) {
    result(FlutterError(code: "image", message: "剪贴板图片无效，或超过 16 MB / 800 万像素", details: nil))
  }
}
