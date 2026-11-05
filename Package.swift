// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tblink",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "tblink", path: "Sources/tblink")
    ]
)
