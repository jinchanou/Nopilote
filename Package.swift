// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nopilote",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Nopilote", targets: ["Nopilote"])
    ],
    targets: [
        .executableTarget(
            name: "Nopilote",
            path: "Sources/Nopilote"
        ),
        .testTarget(
            name: "NopiloteTests",
            dependencies: ["Nopilote"],
            path: "Tests/NopiloteTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
