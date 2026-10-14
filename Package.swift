// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// 可选资源：只有文件真实存在时才声明为 SPM resource。
/// @ai: `glove50d.bin`（~6MB GloVe 词向量）是**本地生成产物**，按 .gitignore 不入库。
///      直接写死 `.process(...)` 会让全新克隆（以及 CI/他人机器）在构建期报
///      "Invalid Resource ... File not found" 并**直接编译失败**。
///      运行时 `GloVeEmbeddingProvider(bundledIn:)` 缺失资源时返回 nil 并优雅降级，
///      所以这里按存在性条件声明，保证「克隆即可编译」。
func optionalResource(_ path: String) -> Resource? {
    FileManager.default.fileExists(atPath: "Sources/WordRecitingApp/\(path)")
        ? .process(path)
        : nil
}

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
                optionalResource("Resources/glove50d.bin"),
                .process("Resources/word_families.json")
            ].compactMap { $0 }
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
