import Foundation

/// 思考型模型的思考 token 预算（与正文 max_tokens 独立，防思考挤占正文）。
/// @ai: DeepSeek V4 `thinking_budget`；Claude Extended Thinking `budget_tokens` 同语义。
public enum ThinkingBudget {
    public static let `default` = 2048
}
