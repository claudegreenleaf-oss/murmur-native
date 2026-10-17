// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MurmurHelper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MurmurHelper", targets: ["MurmurHelper"]),
        // Loaded by Resources/run.pl through perl (macOS 15.4+ only lets perl reach MediaRemote).
        .library(name: "MediaRemoteAdapter", type: .dynamic, targets: ["CIMediaRemote"]),
    ],
    targets: [
        .target(
            name: "CIMediaRemote",
            path: "Sources/CIMediaRemote",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "MurmurHelper",
            path: "Sources/MurmurHelper",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
