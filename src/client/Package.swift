// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Atlas",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../argmax-oss-swift")
    ],
    targets: [
        .target(
            name: "STTIPC"
        ),
        .executableTarget(
            name: "sttd",
            dependencies: [
                "STTIPC",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .executableTarget(
            name: "atlas",
            dependencies: [
                "STTIPC"
            ],
            resources: [
                .copy("resources")
            ]
        )
    ]
)