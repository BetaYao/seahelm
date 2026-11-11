// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SeahelmGPUIUpdater",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SeahelmGPUIUpdater", type: .dynamic, targets: ["SeahelmGPUIUpdater"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "SeahelmGPUIUpdater",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")]
        ),
    ]
)
