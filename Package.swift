// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BarCut",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "BarCut",
            path: "Sources/BarCut"
        ),
        .testTarget(
            name: "BarCutTests",
            dependencies: ["BarCut"]
        )
    ]
)
