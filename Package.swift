// swift-tools-version:5.9
import Foundation
import PackageDescription

// SwiftPM stamps the deployment target (14.0) as the SDK version, which makes AppKit run the app in its
// legacy look. build.sh passes the real SDK version (xcrun --show-sdk-version) so macOS 26+ applies the
// current design (glass toolbar, floating sidebar). Plain `swift build` falls back to 26.0.
let sdkVersion = ProcessInfo.processInfo.environment["FANCURVE_SDK_VERSION"] ?? "26.0"

let package = Package(
    name: "FanCurve",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fancurved", targets: ["fancurved"]),
        .executable(name: "FanCurve", targets: ["FanCurve"]),
    ],
    targets: [
        .target(name: "SMCKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "fancurved", dependencies: ["SMCKit"]),
        .executableTarget(
            name: "FanCurve", dependencies: ["SMCKit"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", sdkVersion])]
        ),
        .testTarget(name: "FanCurveTests", dependencies: ["FanCurve", "SMCKit"]),
    ]
)
