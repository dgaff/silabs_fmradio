// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FMRadio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FMRadio", targets: ["FMRadio"]),
        .executable(name: "si470x-cli", targets: ["si470x-cli"]),
        .library(name: "Si470xKit", targets: ["Si470xKit"]),
    ],
    targets: [
        .target(
            name: "Si470xKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "FMRadio",
            dependencies: ["Si470xKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "si470x-cli",
            dependencies: ["Si470xKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "Si470xKitTests",
            dependencies: ["Si470xKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
