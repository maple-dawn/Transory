// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transory",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Transory", targets: ["Transory"]),
        .library(name: "TransoryCore", targets: ["TransoryCore"]),
    ],
    targets: [
        // 与 UI 无关的核心逻辑：模型适配、提示词、并发对比、钥匙串。
        .target(name: "TransoryCore"),
        // SwiftUI App：主窗口、菜单栏、设置。
        .executableTarget(
            name: "Transory",
            dependencies: ["TransoryCore"]
        ),
        .testTarget(
            name: "TransoryCoreTests",
            dependencies: ["TransoryCore"]
        ),
    ]
)
