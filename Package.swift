// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sshFinder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "sshFinder", path: "Sources/sshFinder"),
    ],
    swiftLanguageModes: [.v5]
)
