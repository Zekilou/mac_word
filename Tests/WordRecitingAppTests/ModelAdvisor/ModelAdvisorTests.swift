import XCTest
@testable import WordRecitingApp

/// ModelAdvisor 测试：advise / minspecs / lookup / HFMirror。
final class ModelAdvisorTests: XCTestCase {

    private let advisor = ModelAdvisor()

    // MARK: - advise：不同内存给出不同推荐

    func testAdviseOnLargeMachinePrefersHighestQuality() {
        // 24GB 机器（本机 M5 同款）：可用 19.2GB
        let hw = MacHardware(totalRAMGB: 24, chipName: "Apple M5", isAppleSilicon: true)
        let advice = advisor.advise(hardware: hw)

        XCTAssertEqual(advice.availableRAMGB, 19.2, accuracy: 0.001)
        // gemma Q8_0: 11.8×1.6=18.88 ≤ 19.2 → 可行；且 Q8_0 qualityRank 0 最高
        XCTAssertEqual(advice.recommendedModel?.modelID, ModelCatalog.gemma412B.modelID)
        XCTAssertEqual(advice.recommendedQuant?.quant, "Q8_0")
        XCTAssertTrue(advice.verdict.contains("可流畅运行") || advice.verdict.contains("内存刚好"))
    }

    func testAdviseOnMidMachineFallsToLowerQuant() {
        // 16GB 机器：可用 12.8GB；gemma Q8_0 18.88 超 → 落到 Q6_K 14.58 仍超 → Q4_K_M 10.99 可行
        let hw = MacHardware(totalRAMGB: 16, chipName: "Apple M4", isAppleSilicon: true)
        let advice = advisor.advise(hardware: hw)

        XCTAssertEqual(advice.recommendedModel?.modelID, ModelCatalog.gemma412B.modelID)
        XCTAssertEqual(advice.recommendedQuant?.quant, "Q4_K_M")
    }

    func testAdviseOnTinyMachineSuggestsSmallerModel() {
        // 8GB 机器：可用 6.4GB；gemma Q3_K_M 9.12 超 → qwen Q4_K_M 7.49 超 → qwen 无更小 → 无推荐
        let hw = MacHardware(totalRAMGB: 8, chipName: "Apple M2", isAppleSilicon: true)
        let advice = advisor.advise(hardware: hw)

        XCTAssertNil(advice.recommendedModel)
        XCTAssertTrue(advice.verdict.contains("❌"))
    }

    func testAdviseOnIntelMachineStillWorks() {
        let hw = MacHardware(totalRAMGB: 32, chipName: "Intel", isAppleSilicon: false)
        let advice = advisor.advise(hardware: hw)
        XCTAssertNotNil(advice.recommendedModel)
    }

    // MARK: - minspecs：指定模型返回各量化最低内存

    func testMinspecsForGemma() {
        let specs = advisor.minspecs(model: ModelCatalog.gemma412B)
        XCTAssertEqual(specs.count, 4)
        // Q8_0: 11.8×1.6=18.88 → ceil 19
        let q8 = specs.first { $0.quant.quant == "Q8_0" }!
        XCTAssertEqual(q8.minRAMGB, 19)
        // Q4_K_M: 6.87×1.6=10.992 → ceil 11
        let q4 = specs.first { $0.quant.quant == "Q4_K_M" }!
        XCTAssertEqual(q4.minRAMGB, 11)
    }

    // MARK: - lookup：HF ID 匹配 + 镜像下载

    func testLookupKnownModel() {
        let result = advisor.lookup(hfModelID: ModelCatalog.gemma412B.modelID)
        XCTAssertNotNil(result)
        let (model, downloads) = result!
        XCTAssertEqual(model.displayName, "Gemma 4 12B")
        XCTAssertEqual(downloads.count, 4)
        // 国内镜像前缀
        XCTAssertTrue(downloads.allSatisfy { $0.url.hasPrefix("https://hf-mirror.com/") })
    }

    func testLookupUnknownModelReturnsNil() {
        XCTAssertNil(advisor.lookup(hfModelID: "nonexistent/foo"))
    }

    func testLookupCaseInsensitive() {
        let upper = advisor.lookup(hfModelID: ModelCatalog.qwen257B.modelID.uppercased())
        XCTAssertNotNil(upper)
        XCTAssertEqual(upper?.model.displayName, "Qwen 2.5 7B")
    }

    // MARK: - HFMirror

    func testHFMirrorResolve() {
        let url = HFMirror.resolve(
            modelID: ModelCatalog.gemma412B.modelID,
            filename: "gemma4-v2-Q4_K_M.gguf")
        XCTAssertEqual(
            url,
            "https://hf-mirror.com/\(ModelCatalog.gemma412B.modelID)/resolve/main/gemma4-v2-Q4_K_M.gguf")
    }

    // MARK: - 目录数据健全性

    func testCatalogHasBothModels() {
        XCTAssertEqual(ModelCatalog.all.count, 2)
        XCTAssertEqual(ModelCatalog.gemma412B.recommendedQuant.quant, "Q4_K_M",
                       "gemma 官方推荐 Q4_K_M 为甜点位")
        XCTAssertEqual(ModelCatalog.qwen257B.recommendedQuant.quant, "Q4_K_M")
    }

    func testFilenameConvention() {
        let f = advisor.filename(of: ModelCatalog.qwen257B, quant: ModelCatalog.qwen257B.recommendedQuant)
        XCTAssertTrue(f.contains("Qwen2.5-7B-Instruct"))
        XCTAssertTrue(f.hasSuffix(".gguf"))
    }

    // MARK: - 一键下载：文件名与进度

    func testCatalogQuantFileNamesMatchRealRepo() {
        // 从 HF API 实际拉取的仓库文件名（一键下载依赖，必须准确）
        XCTAssertEqual(
            ModelCatalog.qwen257B.quants.first { $0.quant == "Q4_K_M" }?.fileName,
            "Qwen2.5-7B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(
            ModelCatalog.gemma412B.quants.first { $0.quant == "Q4_K_M" }?.fileName,
            "gemma4-v2-Q4_K_M.gguf")
        // 每个量化档都有非空文件名
        for entry in ModelCatalog.all {
            for quant in entry.quants {
                XCTAssertFalse(quant.fileName.isEmpty, "\(entry.modelID) \(quant.quant) 缺文件名")
                XCTAssertTrue(quant.fileName.hasSuffix(".gguf"))
            }
        }
    }

    func testDownloadStateProgress() {
        var state = ModelDownloadState(modelID: "m", quant: "Q4_K_M", displayName: "M")
        XCTAssertEqual(state.progress, 0)
        state.totalBytes = 100
        state.receivedBytes = 25
        XCTAssertEqual(state.progress, 0.25, accuracy: 0.001)
        state.receivedBytes = 200  // 超出总字节 → 钳制 1.0
        XCTAssertEqual(state.progress, 1.0)
        XCTAssertTrue(state.isFinished)
    }
}
