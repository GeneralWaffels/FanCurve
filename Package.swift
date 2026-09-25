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
        .executableTarget(name: "FanCurve", dependencies: ["SMCKit"]),
    ]
)
