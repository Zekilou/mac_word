import Foundation

/// Agent sidecar JSONL 协议（App ↔ external_src/agent_sidecar/sidecar.py）。
/// @ai: 事件 JSON 契约与 sidecar.py 一一对应；新增事件需两侧同步。
///      Task 1 覆盖 pong/error/stage/thought/token + result 正文（strategy 映射 Task 2 补齐）。
enum AgentSidecarProtocol {

    /// sidecar → App 的事件行。
    enum Event: Equatable, Sendable {
        case pong(id: Int)
        case result(id: Int, article: String, skippedWords: [SkippedWord])
        case error(id: Int?, code: String, message: String)
        case stage(id: Int, stage: GenStage)
        case thought(id: Int, thought: GenThought)
        case token(id: Int, text: String)

        /// 解析一行 JSON；非法/未知类型返回 nil（由调用方忽略或上报）。
        static func parse(_ line: String) -> Event? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { return nil }
            let id = obj["id"] as? Int
            switch type {
            case "pong":
                guard let id else { return nil }
                return .pong(id: id)
            case "result":
                guard let id, let article = obj["article"] as? String else { return nil }
                let skipped = (obj["skippedWords"] as? [[String: Any]])?.compactMap { d -> SkippedWord? in
                    guard let word = d["word"] as? String else { return nil }
                    return SkippedWord(word: word, reason: d["reason"] as? String ?? "")
                } ?? []
                return .result(id: id, article: article, skippedWords: skipped)
            case "error":
                guard let code = obj["code"] as? String else { return nil }
                return .error(id: id, code: code, message: obj["message"] as? String ?? "")
            case "stage":
                guard let id, let raw = obj["stage"] as? String, let s = GenStage.fromWire(raw) else { return nil }
                return .stage(id: id, stage: s)
            case "thought":
                guard let id, let thought = Self.parseThought(obj) else { return nil }
                return .thought(id: id, thought: thought)
            case "token":
                guard let id, let text = obj["text"] as? String else { return nil }
                return .token(id: id, text: text)
            default:
                return nil
            }
        }

        /// 构造请求行（App → sidecar）：{"id":..,"method":..,"params":..}
        static func request(id: Int, method: String, params: [String: Any] = [:]) -> String {
            var body: [String: Any] = ["id": id, "method": method]
            if !params.isEmpty { body["params"] = params }
            guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else { return #"{"id":\#(id),"method":"\#(method)"}"# }
            return line
        }

        // MARK: - 子解析

        private static func parseThought(_ obj: [String: Any]) -> GenThought? {
            guard let id = obj["thoughtID"] as? String ?? obj["id"] as? String else { return nil }
            let kind = (obj["kind"] as? String).flatMap { GenThought.Kind(rawValue: $0) } ?? .info
            let status = (obj["status"] as? String).flatMap { GenThought.Status(rawValue: $0) } ?? .running
            return GenThought(
                id: id, kind: kind,
                message: obj["message"] as? String ?? "",
                detail: obj["detail"] as? String,
                status: status)
        }
    }

    /// 顶层请求构造（App → sidecar）：委托 Event.request 语义，供客户端直接使用。
    static func request(id: Int, method: String, params: [String: Any] = [:]) -> String {
        Event.request(id: id, method: method, params: params)
    }
}

// MARK: - GenStage wire 映射（Python 端发字符串名）

extension GenStage {
    /// wire 名 → 阶段（Python sidecar 发 "strategy" 等；未知返回 nil）。
    static func fromWire(_ s: String) -> GenStage? {
        switch s {
        case "strategy": return .strategy
        case "planning": return .planning
        case "generating": return .generating
        case "embedding": return .embedding
        case "polishing": return .polishing
        case "saving": return .saving
        default: return nil
        }
    }
}
