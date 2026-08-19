// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "densha",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DenshaCore", targets: ["DenshaCore"]),
        .executable(name: "denshad", targets: ["denshad"]),
        .executable(name: "densha", targets: ["denshacli"]),
        // Named DenshaApp, not Densha: SwiftPM writes every product into the same
        // .build/<config>/ directory, and `Densha` would collide with `densha` on a
        // case-insensitive APFS volume. build-app.sh renames it inside the bundle.
        .executable(name: "DenshaApp", targets: ["DenshaApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", .upToNextMinor(from: "0.4.5")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "DenshaCore",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]
        ),
        .executableTarget(name: "denshad", dependencies: ["DenshaCore"]),
        .executableTarget(
            name: "denshacli",
            dependencies: [
                "DenshaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/densha"
        ),
        .executableTarget(name: "DenshaApp", dependencies: ["DenshaCore"]),
        .testTarget(name: "DenshaCoreTests", dependencies: ["DenshaCore"]),
    ]
)
