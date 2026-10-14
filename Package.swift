// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIUsageBar",
    platforms: [
        .macOS(.v13) // SMAppService (launch at login) requires macOS 13+
    ],
    targets: [
        .executableTarget(
            name: "AIUsageBar",
            path: "Sources/AIUsageBar"
        )
    ]
)
