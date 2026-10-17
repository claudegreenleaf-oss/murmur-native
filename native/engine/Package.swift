// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MurmurEngine",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "MurmurEngine",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MurmurEngine",
            // CI copies shared/prompts/* into Sources/MurmurEngine/Resources/prompts before building.
            resources: [.copy("Resources/prompts")]
        ),
    ]
)
