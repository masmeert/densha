// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "densha",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DenshaCore", targets: ["DenshaCore"]),
        .library(name: "DenshaDaemon", targets: ["DenshaDaemon"]),
        .library(name: "DenshaUI", targets: ["DenshaUI"]),
        .executable(name: "denshad", targets: ["denshad"]),
        .executable(name: "densha", targets: ["denshacli"]),
        .executable(name: "DenshaApp", targets: ["DenshaApp"]),
        .executable(name: "densha-powerd", targets: ["densha-powerd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", .upToNextMinor(from: "0.4.5")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
    ],
    targets: [
        .target(
            name: "DenshaCore",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]
        ),
        .target(
            name: "DenshaDaemon",
            dependencies: ["DenshaCore"],
            path: "Sources/denshad"
        ),
        .executableTarget(
            name: "denshad",
            dependencies: ["DenshaDaemon"],
            path: "Sources/denshad-main"
        ),
        .executableTarget(
            name: "denshacli",
            dependencies: [
                "DenshaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/densha"
        ),
        .target(
            name: "DenshaUI",
            dependencies: ["DenshaCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(name: "DenshaApp", dependencies: ["DenshaUI"]),
        .executableTarget(
            name: "densha-powerd",
            dependencies: ["DenshaCore"],
            path: "Sources/densha-powerd"
        ),
        .testTarget(name: "DenshaCoreTests", dependencies: ["DenshaCore"]),
        .testTarget(name: "DenshaDaemonTests", dependencies: ["DenshaDaemon", "DenshaCore"]),
        .testTarget(name: "DenshaUITests", dependencies: ["DenshaUI", "DenshaCore"]),
    ]
)
