import Foundation

/// 模型 spec（发送给 sidecar 的 params.model）：模型细节隔离，sidecar 据此构造 client。
/// @ai: 思考型/温度/上下文窗口等模型细节集中于此，sidecar 不感知业务；
///      Python 侧 _make_model 读取本结构（model/base_url/api_key/fake/fakeOutput）。
struct AgentSidecarModelSpec: Sendable, Equatable {
    var model: String
    var baseURL: String
    var apiKey: String
    /// 思考型模型（DeepSeek 类）：sidecar 据此决定是否传温度等请求参数。
    var isThinking: Bool = false
    /// 模型上下文窗口（tokens）。
    var contextWindow: Int = 2048
    /// 正文采样温度。
    var temperature: Double = 0.7
    /// 测试钩子：走 ScriptedModel 不连真实模型（sidecar 单测/集成测试用）。
    var fake: Bool = false
    /// fake 模式的模型输出（单次；多轮用 fakeOutputs，见 jsonObject 注释）。
    var fakeOutput: String?

    /// 序列化为 params.model 的 JSON dict（与 sidecar.py / generator.py 契约一致）。
    func jsonObject() -> [String: Any] {
        var o: [String: Any] = [
            "model": model,
            "base_url": baseURL,
            "api_key": apiKey,
            "is_thinking": isThinking,
            "context_window": contextWindow,
            "temperature": temperature,
        ]
        if fake {
            o["fake"] = true
            if let fakeOutput {
                o["fakeOutput"] = fakeOutput
            }
        }
        return o
    }
}
