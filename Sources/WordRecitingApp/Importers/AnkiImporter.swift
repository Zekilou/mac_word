import Foundation
import GRDB

enum AnkiImportError: Error, Sendable {
    case unsupportedFile(URL), unzipFailed(String), databaseNotFound(URL)
    case openDatabaseFailed(String), parseError(String)
}

struct AnkiModelDef: Codable, Sendable { let id: Int64?; let name: String?; let flds: [AnkiFieldDef]? }
struct AnkiFieldDef: Codable, Sendable { let name: String?; let ord: Int? }
struct AnkiDeckDef: Codable, Sendable { let id: Int64?; let name: String? }
struct AnkiNote: Sendable { let id: Int64; let mid: Int64; let tags: String; let flds: String }
struct AnkiCard: Sendable {
    let id: Int64; let nid: Int64; let did: Int64; let queue: Int; let due: Int
    let ivl: Int; let factor: Int; let reps: Int; let lapses: Int
}

/// Anki .apkg 导入器：解压 → 只读打开 SQLite → 解析 col/notes/cards → 输出 ImportBatch。
/// @ai: 不直接写库，只输出 ImportBatch 交给 ImportSystem。
/// TODO: 解析 [sound:xxx.mp3] / <img src="xxx"> → comp_media_refs
final class AnkiImporter: WordImporter, Sendable {
    static let identifier = "anki"
    static let supportedExtensions = ["apkg", "colpkg"]

    func canImport(url: URL) -> Bool {
        Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    func readNodes(from url: URL, progress: @escaping (Double) -> Void) async throws -> ImportBatch {
        progress(0)
        guard canImport(url: url) else { throw AnkiImportError.unsupportedFile(url) }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anki-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. 解压 .apkg（用 macOS 自带 /usr/bin/unzip）
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-oqq", url.path, "-d", tempDir.path]
        let pipe = Pipe(); task.standardError = pipe
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AnkiImportError.unzipFailed(err)
        }

        // 2. 找 collection.anki21（优先）或 collection.anki2
        let fm = FileManager.default
        let anki21 = tempDir.appendingPathComponent("collection.anki21")
        let anki2 = tempDir.appendingPathComponent("collection.anki2")
        let dbURL = fm.fileExists(atPath: anki21.path) ? anki21
            : (fm.fileExists(atPath: anki2.path) ? anki2 : nil)
        guard let dbURL else { throw AnkiImportError.databaseNotFound(tempDir) }

        // 3. 只读打开 SQLite
        var config = Configuration(); config.readonly = true
        let queue: DatabaseQueue
        do { queue = try DatabaseQueue(path: dbURL.path, configuration: config) }
        catch { throw AnkiImportError.openDatabaseFailed(error.localizedDescription) }

        // 4. 读 col 表（crt / models / decks）
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT crt, models, decks FROM col LIMIT 1")
        }
        guard let row else { throw AnkiImportError.parseError("col table empty") }
        let crt: Int64 = row["crt"]
        let models = try Self.parseModels(row["models"])
        let decks = try Self.parseDecks(row["decks"])
        let collectionCrt = Date(timeIntervalSince1970: TimeInterval(crt))

        // 5. 读 notes / cards
        let notes: [AnkiNote] = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, mid, tags, flds FROM notes").map { r in
                AnkiNote(id: r["id"], mid: r["mid"], tags: r["tags"], flds: r["flds"])
            }
        }
        let cards: [AnkiCard] = try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, nid, did, queue, due, ivl, factor, reps, lapses FROM cards
                """).map { r in
                AnkiCard(id: r["id"], nid: r["nid"], did: r["did"], queue: r["queue"],
                        due: r["due"], ivl: r["ivl"], factor: r["factor"],
                        reps: r["reps"], lapses: r["lapses"])
            }
        }

        // 6. 构建 ImportBatch
        return Self.buildBatch(
            sourceURL: url, crt: collectionCrt, models: models, decks: decks,
            notes: notes, cards: cards, progress: progress)
    }

    // MARK: - JSON parsing

    static func parseModels(_ json: String) throws -> [Int64: AnkiModelDef] {
        guard let data = json.data(using: .utf8) else {
            throw AnkiImportError.parseError("models JSON not UTF-8")
        }
        return try JSONDecoder().decode([String: AnkiModelDef].self, from: data)
            .reduce(into: [Int64: AnkiModelDef]()) { dict, kv in
                if let id = Int64(kv.key) { dict[id] = kv.value }
                else if let id = kv.value.id { dict[id] = kv.value }
            }
    }

    static func parseDecks(_ json: String) throws -> [Int64: AnkiDeckDef] {
        guard let data = json.data(using: .utf8) else {
            throw AnkiImportError.parseError("decks JSON not UTF-8")
        }
        return try JSONDecoder().decode([String: AnkiDeckDef].self, from: data)
            .reduce(into: [Int64: AnkiDeckDef]()) { dict, kv in
                if let id = Int64(kv.key) { dict[id] = kv.value }
                else if let id = kv.value.id { dict[id] = kv.value }
            }
    }

    // MARK: - Batch building

    static func buildBatch(
        sourceURL: URL, crt: Date,
        models: [Int64: AnkiModelDef], decks: [Int64: AnkiDeckDef],
        notes: [AnkiNote], cards: [AnkiCard],
        progress: (Double) -> Void
    ) -> ImportBatch {
        let now = Date()
        var nodes: [ImportBatch.NodeSpec] = [], texts: [TextComponent] = []
        var deckMetas: [DeckMetaComponent] = [], lemmaMetas: [LemmaMetaComponent] = []
        var tagSets: [TagSetComponent] = [], scheds: [ScheduleStateComponent] = []
        var edges: [ImportBatch.EdgeSpec] = []

        // 只为有 cards 的 deck 创建 DeckNode（跳过空 Default deck）
        var deckCardCounts: [Int64: Int] = [:]
        for c in cards { deckCardCounts[c.did, default: 0] += 1 }
        for (did, count) in deckCardCounts where count > 0 {
            let id = "anki:deck:\(did)"
            nodes.append(.init(id: id, kind: .deck, createdAt: now))
            deckMetas.append(DeckMetaComponent(
                entityId: id, name: decks[did]?.name ?? "deck-\(did)",
                sourceKind: DeckSourceKind.anki.rawValue,
                sourcePath: sourceURL.path, importedAt: now))
        }

        // notes → LemmaNode + TextComponent + LemmaMetaComponent + TagSetComponent
        var noteTexts: [Int64: TextComponent] = [:]
        let noteN = max(notes.count, 1)
        for (i, note) in notes.enumerated() {
            let lemmaId = "anki:note:\(note.id)"
            let fieldNames = models[note.mid]?.flds?
                .sorted(by: { ($0.ord ?? 0) < ($1.ord ?? 0) })
                .compactMap { $0.name } ?? []
            let values = note.flds.components(separatedBy: "\u{1F}")
            let m = Self.mapFields(fieldNames, values: values)
            nodes.append(.init(id: lemmaId, kind: .lemma, createdAt: now))
            let tc = TextComponent(entityId: lemmaId, textA: m.headword, textB: m.definition, language: nil)
            texts.append(tc); noteTexts[note.id] = tc
            lemmaMetas.append(LemmaMetaComponent(
                entityId: lemmaId, pos: m.pos, phoneticUs: m.phonetic,
                phoneticUk: nil, sensesJson: m.sensesJson))
            // 合并 Anki note.tags + 映射到的 tags 字段（如 GRE 的"考纲"）
            var allTags: [String] = []
            let trimmed = note.tags.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { allTags.append(contentsOf: trimmed.split(separator: " ").map(String.init)) }
            if let mtags = m.tags, !mtags.isEmpty {
                allTags.append(contentsOf: mtags.split(separator: " ").map(String.init))
            }
            if !allTags.isEmpty {
                let json = (try? JSONEncoder().encode(Array(Set(allTags))))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                tagSets.append(TagSetComponent(entityId: lemmaId, tagsJson: json))
            }
            if i % 100 == 0 || i == notes.count - 1 {
                progress(Double(i) / Double(noteN) * 0.5)
            }
        }

        // cards → CardNode + TextComponent + ScheduleStateComponent + edges
        let cardN = max(cards.count, 1)
        for (i, card) in cards.enumerated() {
            let cardId = "anki:card:\(card.id)"
            let deckId = "anki:deck:\(card.did)"
            nodes.append(.init(id: cardId, kind: .card, createdAt: now))
            if let tc = noteTexts[card.nid] {
                texts.append(TextComponent(entityId: cardId, textA: tc.textA, textB: tc.textB, language: tc.language))
            }
            scheds.append(Self.makeSchedule(card: card, crt: crt, entityId: cardId))
            edges.append(.init(id: "anki:has:\(card.id)", srcId: deckId, dstId: cardId, rel: .has, createdAt: now))
            edges.append(.init(id: "anki:inst:\(card.id)", srcId: cardId,
                               dstId: "anki:note:\(card.nid)", rel: .instantiates, createdAt: now))
            if i % 100 == 0 || i == cards.count - 1 {
                progress(0.5 + Double(i) / Double(cardN) * 0.5)
            }
        }

        progress(1.0)
        // 主 deck = 卡片数最多的 deck
        let primaryDeckId = deckCardCounts.max(by: { $0.value < $1.value })
            .map { "anki:deck:\($0.key)" } ?? "anki:deck:main"
        return ImportBatch(
            deckId: primaryDeckId, nodes: nodes, textComponents: texts,
            deckMetas: deckMetas, lemmaMetas: lemmaMetas, tagSets: tagSets,
            scheduleStates: scheds, edges: edges, failures: [])
    }

    // MARK: - Field mapping

    enum FieldRole: Sendable {
        case headword, definition, phonetic, pos, tags, example, other
    }

    static func roleForField(_ name: String) -> FieldRole {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        let sets: [(FieldRole, [String])] = [
            (.headword, ["word", "front", "headword", "lemma", "单词", "正面", "词目"]),
            (.definition, ["back", "definition", "meaning", "背面", "释义", "基本释义", "解释", "意思"]),
            (.phonetic, ["phonetic", "phonetics", "pron", "pronunciation", "音标", "发音"]),
            (.pos, ["pos", "part of speech", "partofspeech", "词性"]),
            (.tags, ["tags", "tag", "考纲", "标签"]),
            (.example, ["example", "examples", "例句"]),
        ]
        for (role, list) in sets where list.contains(key) { return role }
        if key.contains("phonetic") || key.contains("音标") { return .phonetic }
        if key.contains("definition") || key.contains("释义") { return .definition }
        if key.contains("example") || key.contains("例句") { return .example }
        return .other
    }

    struct FieldMapping: Sendable {
        var headword: String?, definition: String?, phonetic: String?
        var pos: String?, tags: String?, example: String?
        var sensesJson: String? { example }
    }

    static func mapFields(_ names: [String], values: [String]) -> FieldMapping {
        var m = FieldMapping()
        for (i, name) in names.enumerated() {
            guard i < values.count else { break }
            let value = values[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            switch roleForField(name) {
            case .headword: if m.headword == nil { m.headword = value }
            case .definition: if m.definition == nil { m.definition = value }
            case .phonetic: if m.phonetic == nil { m.phonetic = value }
            case .pos: if m.pos == nil { m.pos = value }
            case .tags: if m.tags == nil { m.tags = value }
            case .example: if m.example == nil { m.example = value }
            case .other: break
            }
        }
        // 回退：无显式 headword 字段时，取第一个非空值
        if m.headword == nil {
            for v in values {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { m.headword = trimmed; break }
            }
        }
        return m
    }

    static func makeSchedule(card: AnkiCard, crt: Date, entityId: EntityID) -> ScheduleStateComponent {
        let queueStr: String
        switch card.queue {
        case -1: queueStr = "suspended"
        case 0: queueStr = "new"
        case 1, 3: queueStr = "learning"
        case 2: queueStr = "review"
        default: queueStr = "new"
        }
        let difficulty = Double(card.factor) / 1000.0
        let dueAt: Date?
        if card.queue == 2 {
            // review: due 是从 crt 起的天数偏移
            dueAt = Date(timeIntervalSince1970: crt.timeIntervalSince1970 + Double(card.due) * 86400)
        } else if card.queue == 1 || card.queue == 3 {
            dueAt = Date()  // learning: 立即到期
        } else {
            dueAt = nil  // new / suspended: 无到期日
        }
        return ScheduleStateComponent(
            entityId: entityId, stability: nil, difficulty: difficulty, dueAt: dueAt,
            intervalDays: card.ivl > 0 ? Double(card.ivl) : nil,
            reps: card.reps, lapses: card.lapses, lastRating: nil, lastReviewedAt: nil,
            schedulerId: nil, queue: queueStr, customDataJson: nil)
    }
}
