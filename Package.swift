// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiteTube",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "LiteTube",
            path: "Sources/LiteTube",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
