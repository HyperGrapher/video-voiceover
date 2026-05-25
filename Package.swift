// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "speechapp",
    platforms: [
        .macOS(.v15) // Keep macOS 15 support for Sequoia compatibility
    ],
    products: [
        .executable(name: "speechapp", targets: ["speechapp"])
    ],
    dependencies: [
        // Dependencies removed: No more MLX or kokoro-ios builds!
    ],
    targets: [
        .executableTarget(
            name: "speechapp",
            dependencies: [],
            path: "Sources/speechapp",
            exclude: [
                "Info.plist",
                "Resources/tts_backend-ex",
                "Resources/tts_backend.md"
            ],
            resources: [
                // Embed the compiled python executable safely inside the target resources
                .copy("Resources/tts_backend")
            ],
            // FIX: This injects the "Allow Arbitrary Loads" dictionary directly into the binary's info segment
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/speechapp/Info.plist"
                ])
            ]
            // Resources removed: Models are now handled purely by Python
        )
    ]
)
