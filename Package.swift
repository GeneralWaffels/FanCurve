// swift-tools-version:5.9
import PackageDescription

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
            // SwiftPM stamps the deployment target (14.0) as the SDK version, which makes AppKit run the
            // app in its legacy look. Record the real SDK so macOS 26+ gives it the current design
            // (floating glass sidebar, seamless toolbar). Keep in sync with `xcrun --show-sdk-version`.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "27.0"])]
        ),
    ]
)
