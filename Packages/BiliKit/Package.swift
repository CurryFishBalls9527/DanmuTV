// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BiliKit",
    platforms: [.tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BiliKit", targets: ["BiliKit"]),
    ],
    targets: [
        .target(name: "BiliKit"),
        // Assertion runner usable without Xcode/XCTest: `swift run BiliKitChecks [--network]`
        .executableTarget(name: "BiliKitChecks", dependencies: ["BiliKit"]),
        .testTarget(name: "BiliKitTests", dependencies: ["BiliKit"], resources: [.copy("Fixtures")]),
    ]
)
