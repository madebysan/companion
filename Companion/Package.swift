// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.1")
    ],
    targets: [
        .executableTarget(
            name: "Companion",
            dependencies: ["HotKey"],
            path: "Sources/Companion",
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns"]
        )
    ]
)
