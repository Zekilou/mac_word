import Foundation

// MARK: - Advisor 结果类型

/// advise 的返回：诚实结论 + 推荐。
struct ModelAdvice: Sendable, Equatable {
    /// 结论文案（如 "✅ 可流畅运行" / "⚠️ 内存偏紧" / "❌ 内存不足"）。
    let verdict: String
    /// 推荐模型（可能为 nil：当前硬件跑不动任何内置模型）。
    let recommendedModel: ModelEntry?
    /// 推荐的量化档（随 recommendedModel 提供）。
    let recommendedQuant: QuantOption?
    /// 本机可用内存估算（GB）。
    let availableRAMGB: Double
}

/// 国内镜像下载信息（lookup 返回）。
struct MirrorDownload: Sendable, Equatable {
    /// 国内镜像（hf-mirror.com）下载 URL。
    let url: String
    /// 文件名。
    let filename: String
}

// MARK: - ModelAdvisor

/// 硬件 → 模型/量化推荐引擎（参考 FitCheck 的 /api/advise、/api/minspecs、/api/lookup 设计）。
/// 规则（粗略，够用即可）：
///   - 可用内存 ≈ 总内存 × 0.8（留系统余量）
///   - 加载一个 GGUF 大致需要：文件大小 × 1.6（权重驻留 + KV cache + 运行时）
///   - 在"放得下"的量化档里，选质量最高（qualityRank 最小）且非严重超档的
/// @ai: 纯函数、无 IO，便于单元测试。
struct ModelAdvisor {

    /// 建议保留的系统内存比例（模型以外的 OS/App 开销）。
    static let systemReserveRatio = 0.8

    /// 文件大小 → 运行所需内存的经验系数（权重 + KV cache + 上下文）。
    static let memoryFactor = 1.6

    // MARK: - 核心：advise（等价 FitCheck /api/advise）

    /// 依据本机硬件给出诚实的模型推荐。
    /// 策略：按目录顺序（gemma 默认优先）逐模型检查——
    ///   取该模型全部"放得下"的量化档，选质量最高（qualityRank 最小）的一档；
    ///   若当前模型一档都放不下，才 fallback 到下一个模型。
    /// 这样保证"默认模型优先，其次才换更小模型"。
    func advise(hardware: MacHardware) -> ModelAdvice {
        let available = Double(hardware.totalRAMGB) * Self.systemReserveRatio

        var recommendation: (model: ModelEntry, quant: QuantOption)? = nil
        for model in ModelCatalog.all {
            let feasible = model.quants
                .filter { $0.fileSizeGB * Self.memoryFactor <= available }
                .min { $0.qualityRank < $1.qualityRank }
            if let feasible {
                recommendation = (model, feasible)
                break
            }
        }

        guard let recommendation else {
            let verdict = "❌ 当前 \(hardware.totalRAMGB) GB 内存放不下内置模型，请考虑更小模型或升级内存。"
            return ModelAdvice(verdict: verdict, recommendedModel: nil,
                               recommendedQuant: nil, availableRAMGB: available)
        }

        // 判定宽松度：是否还有余量
        let needed = recommendation.quant.fileSizeGB * Self.memoryFactor
        let headroom = (available - needed) / needed
        let chip = hardware.isAppleSilicon ? hardware.chipName : "非 Apple Silicon"
        let verdict: String
        if headroom >= 0.5 {
            verdict = "✅ \(chip) · \(Int(available)) GB 可用内存，可流畅运行"
        } else if headroom >= 0 {
            verdict = "⚠️ \(chip) · 内存刚好够用，建议关掉大程序再跑"
        } else {
            verdict = "⚠️ \(chip) · 内存偏紧，可能较慢或需要缩小上下文"
        }

        return ModelAdvice(
            verdict: verdict,
            recommendedModel: recommendation.model,
            recommendedQuant: recommendation.quant,
            availableRAMGB: available)
    }

    // MARK: - 反向查询：minspecs（等价 FitCheck /api/minspecs）

    /// 指定模型 → 返回各量化档所需最低内存（GB，取整）。
    func minspecs(model: ModelEntry) -> [(quant: QuantOption, minRAMGB: Int)] {
        model.quants.map { ($0, Int(ceil($0.fileSizeGB * Self.memoryFactor))) }
    }

    // MARK: - 在线查询：lookup（等价 FitCheck /api/lookup）

    /// 粘贴 HF 模型 ID → 匹配内置目录，返回量化要求 + 国内镜像下载地址。
    /// 返回 nil 表示不在内置目录。
    func lookup(hfModelID: String) -> (model: ModelEntry, downloads: [MirrorDownload])? {
        guard let model = ModelCatalog.lookup(modelID: hfModelID) else { return nil }
        let downloads = model.quants.map { quant in
            MirrorDownload(
                url: HFMirror.resolve(modelID: model.modelID, filename: filename(of: model, quant: quant)),
                filename: filename(of: model, quant: quant))
        }
        return (model, downloads)
    }

    // MARK: - 文件名

    /// 量化档对应的仓库 GGUF 文件名（直接取 QuantOption.fileName，准确而非猜测）。
    func filename(of model: ModelEntry, quant: QuantOption) -> String {
        quant.fileName
    }
}
