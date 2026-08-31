import GRDB
import Foundation

/// GraphQueries 储存相关只读查询（设置-储存子区用）。
/// @ai: UI 只调用命名方法，禁止业务代码手写 SQL。
extension GraphQueries {

    /// 全部生成历史文章数（generate + rewrite 两模式合计）。
    func articleCount() throws -> Int {
        try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_generation_meta") ?? 0
        }
    }
}
