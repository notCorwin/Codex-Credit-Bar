// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexMenuBarCredit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexMenuBarCredit", targets: ["CodexMenuBarCredit"])
    ],
    targets: [
        .executableTarget(
            name: "CodexMenuBarCredit",
            path: "Sources/CodexMenuBarCredit"
        ),
        .testTarget(
            name: "CodexMenuBarCreditTests",
            dependencies: ["CodexMenuBarCredit"],
            path: "Tests/CodexMenuBarCreditTests"
        )
    ]
)
