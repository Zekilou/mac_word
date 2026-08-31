import Foundation

// MARK: - 本机硬件快照

/// 本机硬件信息（内存 / 芯片 / 是否 Apple Silicon）。
struct MacHardware: Sendable, Equatable {
    /// 总物理内存（GB，整数向下取整）。
    let totalRAMGB: Int
    /// 芯片名称（如 "Apple M5"），空表示未知。
    let chipName: String
    /// 是否 Apple Silicon（arm64）。
    let isAppleSilicon: Bool

    static let current = MacHardware(
        totalRAMGB: Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024 / 1024),
        chipName: Self.chipModel,
        isAppleSilicon: Self.isAppleSiliconFlag)

    private static var isAppleSiliconFlag: Bool {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0) == "arm64"
            }
        }
    }

    private static var chipModel: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - 模型目录数据

/// 一个模型的量化档。
struct QuantOption: Sendable, Equatable, Identifiable {
    var id: String { quant }
    /// 量化名（Q3_K_M / Q4_K_M / Q6_K / Q8_0）。
    let quant: String
    /// 仓库内的 GGUF 文件名（一键下载用）。
    let fileName: String
    /// GGUF 文件大小（GB，近似）。
    let fileSizeGB: Double
    /// 官方推荐度排序（越小越好）：Q8_0=0, Q6_K=1, Q5_K_M=2, Q4_K_M=3, Q3_K_M=4。
    let qualityRank: Int
    /// 官方标注是否为推荐甜点位（如 gemma-4-12B 的 Q4_K_M）。
    let recommended: Bool
}

/// 一个模型家族（如 gemma-4-12B / qwen2.5-7b）。
struct ModelEntry: Sendable, Equatable, Identifiable {
    var id: String { modelID }
    /// Hugging Face 模型 ID。
    let modelID: String
    /// 展示名（"Gemma 4 12B" / "Qwen 2.5 7B"）。
    let displayName: String
    /// 参数规模（如 "12B"）。
    let parameterScale: String
    /// 适用场景说明。
    let note: String
    /// 该模型的 GGUF 量化档（按 qualityRank 升序）。
    let quants: [QuantOption]

    /// 最低可用量化（文件最小的一档）。
    var smallestQuant: QuantOption { quants.min { $0.fileSizeGB < $1.fileSizeGB }! }
    /// 推荐量化（recommended 优先，否则质量最高档）。
    var recommendedQuant: QuantOption {
        quants.first { $0.recommended } ?? quants.min { $0.qualityRank < $1.qualityRank }!
    }
}

/// 模型目录（内置两个模型家族的不同量化精度）。
enum ModelCatalog {
    static let all: [ModelEntry] = [gemma412B, qwen257B]

    /// 用户提供的 Gemma 4 12B（agentic 微调）GGUF：Q3_K_M 5.7GB / Q4_K_M 6.87GB / Q6_K 9.11GB / Q8_0 11.8GB。
    /// 官方：Q4_K_M 是推荐甜点位，Q3_K_M 是最小可靠档（无 Q2_K）。
    static let gemma412B = ModelEntry(
        modelID: "yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF",
        displayName: "Gemma 4 12B",
        parameterScale: "12B",
        note: "本地 coding/agentic 微调；12B 需较大内存。官方推荐 Q4_K_M。",
        quants: [
            QuantOption(quant: "Q8_0", fileName: "gemma4-v2-Q8_0.gguf", fileSizeGB: 11.8, qualityRank: 0, recommended: false),
            QuantOption(quant: "Q6_K", fileName: "gemma4-v2-Q6_K.gguf", fileSizeGB: 9.11, qualityRank: 1, recommended: false),
            QuantOption(quant: "Q4_K_M", fileName: "gemma4-v2-Q4_K_M.gguf", fileSizeGB: 6.87, qualityRank: 2, recommended: true),
            QuantOption(quant: "Q3_K_M", fileName: "gemma4-v2-Q3_K_M.gguf", fileSizeGB: 5.7, qualityRank: 3, recommended: false),
        ])

    /// Qwen 2.5 7B Instruct GGUF（bartowski imatrix）：Q4_K_M 4.68GB / Q5_K_M 5.44GB / Q6_K 6.25GB / Q8_0 8.1GB。
    static let qwen257B = ModelEntry(
        modelID: "bartowski/Qwen2.5-7B-Instruct-GGUF",
        displayName: "Qwen 2.5 7B",
        parameterScale: "7B",
        note: "通用中英文能力均衡，7B 门槛低于 12B。官方推荐 Q4_K_M。",
        quants: [
            QuantOption(quant: "Q8_0", fileName: "Qwen2.5-7B-Instruct-Q8_0.gguf", fileSizeGB: 8.10, qualityRank: 0, recommended: false),
            QuantOption(quant: "Q6_K", fileName: "Qwen2.5-7B-Instruct-Q6_K.gguf", fileSizeGB: 6.25, qualityRank: 1, recommended: false),
            QuantOption(quant: "Q5_K_M", fileName: "Qwen2.5-7B-Instruct-Q5_K_M.gguf", fileSizeGB: 5.44, qualityRank: 2, recommended: false),
            QuantOption(quant: "Q4_K_M", fileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf", fileSizeGB: 4.68, qualityRank: 3, recommended: true),
        ])

    /// 按 HF 模型 ID 精确查找。
    static func lookup(modelID: String) -> ModelEntry? {
        all.first { $0.modelID.lowercased() == modelID.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
