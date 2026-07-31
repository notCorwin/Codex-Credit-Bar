// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexCredit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexCredit", targets: ["CodexCredit"])
    ],
    targets: [
        .executableTarget(
            name: "CodexCredit",
            path: "Sources/CodexCredit"
        ),
        .testTarget(
            name: "CodexCreditTests",
            dependencies: ["CodexCredit"],
            path: "Tests/CodexCreditTests"
        )
    ]
)
