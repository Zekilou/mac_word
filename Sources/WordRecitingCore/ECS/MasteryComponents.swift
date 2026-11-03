import Foundation
import GRDB

/// BKT 后验掌握度概率（挂 Lemma）。
/// @ai: 与 comp_user_known.mastery（用户显式 0/1/2 标量）并存，互不覆盖。
struct MasteryBeliefComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_mastery_belief"
    var entityId: String
    /// P(用户会这个词) ∈ (0,1)。
    var belief: Double
    /// 参与重放的事件数（学习机会数）。
    var opportunities: Int
    var lastEventAt: Date?
    var updatedAt: Date
    /// 生成该后验的参数版本（BKTParameters.version）。
    var paramsVersion: String

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case belief
        case opportunities
        case lastEventAt = "last_event_at"
        case updatedAt = "updated_at"
        case paramsVersion = "params_version"
    }
}
