// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WordRecitingApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WordRecitingApp", targets: ["WordRecitingApp"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "WordRecitingApp",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "WordRecitingAppTests",
            dependencies: [
                .target(name: "WordRecitingApp"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
