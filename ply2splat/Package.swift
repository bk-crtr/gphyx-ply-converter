// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ply2splat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ply2splat",
            path: "Sources/ply2splat",
            resources: [.process("background.png")],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("ModelIO"),
                .linkedLibrary("z")
            ]
        )
    ]
)
