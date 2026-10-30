import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  @MainActor
  func testNativeLaunchContainsVisibleBrandAtTheFlutterPosition() throws {
    let controller = try XCTUnwrap(
      UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController()
    )
    let view = try XCTUnwrap(controller.view)
    view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    let mark = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
    XCTAssertEqual(mark.bounds.size, CGSize(width: 240, height: 240))
    XCTAssertEqual(mark.center, CGPoint(x: 195, y: 422))
    let image = try XCTUnwrap(mark.image)
    XCTAssertEqual(image.size, CGSize(width: 240, height: 240))
    let bitmap = try XCTUnwrap(image.cgImage)
    let data = try XCTUnwrap(bitmap.dataProvider?.data) as Data
    let pixelBytes = bitmap.bitsPerPixel / 8
    XCTAssertGreaterThanOrEqual(pixelBytes, 3)
    XCTAssertTrue(stride(from: 0, to: data.count - pixelBytes, by: pixelBytes).contains { offset in
      data[offset] > 210 && data[offset + 1] > 210 && data[offset + 2] > 210
    }, "The native artwork must contain the white mark, not an empty canvas.")
    let rendered = UIGraphicsImageRenderer(size: view.bounds.size).image { context in
      view.layer.render(in: context.cgContext)
    }
    let attachment = XCTAttachment(image: rendered)
    attachment.name = "Native launch screen"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

}
