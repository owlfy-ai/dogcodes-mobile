// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "dogcodes_video",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(name: "dogcodes-video", targets: ["dogcodes_video"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "dogcodes_video",
      dependencies: []
    )
  ]
)
