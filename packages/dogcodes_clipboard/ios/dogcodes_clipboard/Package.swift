// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "dogcodes_clipboard",
    platforms: [.iOS("13.0")],
    products: [.library(name: "dogcodes-clipboard", targets: ["dogcodes_clipboard"])],
    dependencies: [],
    targets: [.target(name: "dogcodes_clipboard", dependencies: [])]
)
