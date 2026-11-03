// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// 可选资源：只有文件真实存在时才声明为 SPM resource。
/// @ai: `glove50d.bin`（~6MB GloVe 词向量）是**本地生成产物**，按 .gitignore 不入库。
///      直接写死 `.process(...)` 会让全新克隆（以及 CI/他人机器）在构建期报
///      "Invalid Resource ... File not found" 并**直接编译失败**。
///      运行时 `GloVeEmbeddingProvider(bundledIn:)` 缺失资源时返回 nil 并优雅降级，
///      所以这里按存在性条件声明，保证「克隆即可编译」。
func optionalResource(_ path: String, in module: String) -> Resource? {
    FileManager.default.fileExists(atPath: "Sources/\(module)/\(path)")
        ? .process(path)
        : nil
}

/// 模块划分（2026-11-03 拆分）
///
/// ```
/// WordRecitingApp  (可执行：只有 main.swift / 菜单 / 身份常量)
///        ├── WordRecitingUI     (SwiftUI 视图 + Settings)
///        └── WordRecitingCore   (ECS / 数据 / 调度 / 生成 / LLM)
///                 ▲
///                 └── Core 不依赖任何其他本工程模块
/// ```
///
/// @ai: **拆分的目的不是好看，是并行开发不互相阻塞。**
///      拆分前是全工程单 target（177 文件 / 26k 行）：任何一处编译错误都会让
///      整个 App 编不过——实测过一次「后端改到一半，UI 无法独立验证」的阻塞。
///      拆分后：
///        - Core 编不过时，`swift build --target WordRecitingUI` 仍可独立验证
///        - 增量编译只重建变动的 target
///        - 测试可按模块跑
///
///      依赖方向**单向**：App → UI → Core。**Core 里禁止 import UI。**
///      新增文件先问：属于哪一层？视图与视图模型进 UI，其余一律 Core。
let package = Package(
    name: "WordRecitingApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WordRecitingApp", targets: ["WordRecitingApp"]),
        .library(name: "WordRecitingCore", targets: ["WordRecitingCore"]),
        .library(name: "WordRecitingUI", targets: ["WordRecitingUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        .package(url: "https://github.com/mattt/llama.swift", branch: "main")
    ],
    targets: [
        // MARK: 数据与算法层（无 UI 依赖）
        .target(
            name: "WordRecitingCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "LlamaSwift", package: "llama.swift")
            ],
            resources: [
                optionalResource("Resources/glove50d.bin", in: "WordRecitingCore"),
                optionalResource("Resources/word_families.json", in: "WordRecitingCore"),
            ].compactMap { $0 }
        ),
        // MARK: 视图层（依赖 Core，不被 Core 依赖）
        .target(
            name: "WordRecitingUI",
            dependencies: ["WordRecitingCore"]
        ),
        // MARK: 可执行入口（只放 main / 菜单 / 身份常量）
        .executableTarget(
            name: "WordRecitingApp",
            dependencies: ["WordRecitingCore", "WordRecitingUI"]
        ),
        .testTarget(
            name: "WordRecitingAppTests",
            dependencies: [
                "WordRecitingApp",
                "WordRecitingCore",
                "WordRecitingUI",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
