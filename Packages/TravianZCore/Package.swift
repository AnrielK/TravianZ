// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TravianZCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TravianZCore", targets: ["TravianZCore"]),
    ],
    targets: [
        .target(name: "TravianZCore"),
        .testTarget(
            name: "TravianZCoreTests",
            dependencies: ["TravianZCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
