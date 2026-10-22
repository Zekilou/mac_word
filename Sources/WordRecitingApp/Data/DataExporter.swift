import Foundation
import GRDB

/// 数据导出：数据库备份 + 词汇 CSV 导出。
/// @ai: 用户数据只有这一个 sqlite 文件，且**没有任何导出入口**——一旦误删/换机就全没了。
///      备份用 `VACUUM INTO`（SQLite 3.27+）：生成一份**一致的**完整快照，
///      不像直接 copy 那样可能拷到 WAL 未合并的中间状态。
///      `VACUUM INTO` 不能在事务内执行，所以走 `writeWithoutTransaction`。
enum DataExporter {

    // MARK: - 数据库备份

    /// 把当前数据库完整备份到 destination（若目标存在则覆盖）。
    /// - Returns: 备份文件大小（字节）。
    @discardableResult
    static func backupDatabase(world: World, to destination: URL) throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // VACUUM INTO 要求目标文件不存在（否则报错）。
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try world.database.dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [destination.path])
        }
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    /// 默认备份文件名：`wordincontxt-backup-YYYYMMDD-HHmmss.sqlite`。
    static func defaultBackupFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "wordincontxt-backup-\(f.string(from: now)).sqlite"
    }

    // MARK: - 词汇 CSV

    /// 导出已记录词汇为 CSV（词形 / 释义 / 掌握度 / 出现次数 / 复习词频带）。
    /// @ai: 列顺序与其他导入器识别的表头兼容（lemma / definition），
    ///      导出的文件可以再被 CSVImporter 读回来，算是一种可迁移的开放格式。
    static func exportVocabularyCSV(world: World) throws -> String {
        let lemmas = try world.graph.recordedLemmas()
        var lines = ["lemma,definition,mastery,seen_count,event_count"]
        for lemma in lemmas {
            let fields = [
                lemma.text,
                lemma.definition ?? "",
                String(lemma.mastery),
                String(lemma.seenCount),
                String(lemma.eventCount),
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 默认词汇 CSV 文件名：`wordincontxt-vocabulary-YYYYMMDD.csv`。
    static func defaultVocabularyFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return "wordincontxt-vocabulary-\(f.string(from: now)).csv"
    }

    /// CSV 字段转义：含逗号/引号/换行时用双引号包裹，内部引号翻倍。
    static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
