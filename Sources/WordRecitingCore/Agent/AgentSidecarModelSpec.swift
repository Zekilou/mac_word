import Foundation

/// 模型 spec（发送给 sidecar 的 params.model）：模型细节隔离，sidecar 据此构造 client。
/// @ai: 思考型/温度/上下文窗口等模型细节集中于此，sidecar 不感知业务；
///      Python 侧 _make_model 读取本结构（model/base_url/api_key/fake/fakeOutput）。
public struct AgentSidecarModelSpec: Sendable, Equatable {
    public var model: String
    public var baseURL: String
    public var apiKey: String
    /// 思考型模型（DeepSeek 类）：sidecar 据此决定是否传温度等请求参数。
    public var isThinking: Bool = false
    /// 模型上下文窗口（tokens）。
    public var contextWindow: Int = 2048
    /// 正文采样温度。
    public var temperature: Double = 0.7
    /// 测试钩子：走 ScriptedModel 不连真实模型（sidecar 单测/集成测试用）。
    public var fake: Bool = false
    /// fake 模式的模型输出（单次；多轮用 fakeOutputs，见 jsonObject 注释）。
    public var fakeOutput: String?

    /// @ai: public init——UI 层按「档位/设置」构造 spec 后交给 AgentSidecarGenerator。
    ///      参数默认值与存储属性默认值保持一致（isThinking=false, contextWindow=2048,
    ///      temperature=0.7, fake=false, fakeOutput=nil），memberwise init 无法跨模块访问。
    public init(
        model: String,
        baseURL: String,
        apiKey: String,
        isThinking: Bool = false,
        contextWindow: Int = 2048,
        temperature: Double = 0.7,
        fake: Bool = false,
        fakeOutput: String? = nil
    ) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.isThinking = isThinking
        self.contextWindow = contextWindow
        self.temperature = temperature
        self.fake = fake
        self.fakeOutput = fakeOutput
    }

    /// 序列化为 params.model 的 JSON dict（与 sidecar.py / generator.py 契约一致）。
    public func jsonObject() -> [String: Any] {
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
