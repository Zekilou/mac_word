// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WordRecitingApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WordRecitingApp", targets: ["WordRecitingApp"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        .package(url: "https://github.com/mattt/llama.swift", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "WordRecitingApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "LlamaSwift", package: "llama.swift")
            ],
            resources: [
                .process("Resources/glove50d.bin"),
                .process("Resources/word_families.json")
            ]
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
