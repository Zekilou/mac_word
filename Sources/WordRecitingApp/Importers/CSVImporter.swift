import Foundation

enum CSVImportError: Error, Sendable {
    case emptyFile
    case unrecognizedFormat
    case readFailed(URL, String)
}

/// CSV / TSV 导入器：自动识别分隔符，按列名识别字段，输出 ImportBatch。
/// 列识别优先级：lemma/headword/word > pos/词性 > front/正面 > back/背面 > tags。
/// @ai: 不直接写库，只输出 ImportBatch 交给 ImportSystem。
struct CSVImporter: WordImporter {
    static let identifier = "csv"
    static let supportedExtensions = ["csv", "tsv", "txt"]

    func canImport(url: URL) -> Bool {
        Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    func readNodes(from url: URL, progress: @escaping (Double) -> Void) async throws -> ImportBatch {
        progress(0)
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CSVImportError.readFailed(url, error.localizedDescription)
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CSVImportError.emptyFile
        }
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
            .map(String.init)
        guard let headerLine = lines.first, !headerLine.isEmpty else {
            throw CSVImportError.emptyFile
        }
        let delimiter = Self.detectDelimiter(in: headerLine)
        let headers = Self.parseLine(headerLine, delimiter: delimiter)
        let cols = Self.mapColumns(headers)
        guard cols.hasAnyKnown else {
            throw CSVImportError.unrecognizedFormat
        }
        let deckId = "deck-\(Self.sanitize(url.deletingPathExtension().lastPathComponent))"
        let deckName = url.deletingPathExtension().lastPathComponent
        let now = Date()

        var nodes: [ImportBatch.NodeSpec] = []
        var texts: [TextComponent] = []
        var lemmaMetas: [LemmaMetaComponent] = []
        var tagSets: [TagSetComponent] = []
        var scheds: [ScheduleStateComponent] = []
        var edges: [ImportBatch.EdgeSpec] = []
        var failures: [ImportBatch.FailureSpec] = []

        // Deck node + meta
        nodes.append(.init(id: deckId, kind: .deck, createdAt: now))
        let deckMeta = DeckMetaComponent(
            entityId: deckId, name: deckName, sourceKind: DeckSourceKind.csv.rawValue,
            sourcePath: url.path, importedAt: now)

        let dataLines = Array(lines.dropFirst())
        let total = max(dataLines.count, 1)
        for (idx, line) in dataLines.enumerated() {
            let rowIndex = idx + 2  // 1-based，含 header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                failures.append(.init(
                    entityId: "fail-\(deckId)-\(rowIndex)", deckId: deckId,
                    rowIndex: rowIndex, rawLine: line, reason: "empty line"))
                progress(Double(idx + 1) / Double(total))
                continue
            }
            let fields = Self.parseLine(line, delimiter: delimiter)
            let front = cols.front.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""
            let back = cols.back.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""
            let lemma = cols.lemma.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""
            let pos = cols.pos.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""
            let tags = cols.tags.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""

            // 关键字段校验：lemma 与 front 至少有一个非空
            if lemma.isEmpty && front.isEmpty {
                failures.append(.init(
                    entityId: "fail-\(deckId)-\(rowIndex)", deckId: deckId,
                    rowIndex: rowIndex, rawLine: line,
                    reason: "missing key field (lemma and front both empty)"))
                progress(Double(idx + 1) / Double(total))
                continue
            }

            if !lemma.isEmpty {
                let lemmaId = "lemma-\(deckId)-\(Self.sanitize(lemma))"
                let cardId = "card-\(deckId)-\(Self.sanitize(front.isEmpty ? lemma : front))"
                nodes.append(.init(id: lemmaId, kind: .lemma, createdAt: now))
                lemmaMetas.append(LemmaMetaComponent(
                    entityId: lemmaId, pos: pos.isEmpty ? nil : pos,
                    phoneticUs: nil, phoneticUk: nil, sensesJson: nil))
                texts.append(TextComponent(
                    entityId: lemmaId,
                    textA: front.isEmpty ? lemma : front,
                    textB: back.isEmpty ? nil : back, language: nil))
                nodes.append(.init(id: cardId, kind: .card, createdAt: now))
                scheds.append(Self.makeInitialSchedule(entityId: cardId, now: now))
                if !tags.isEmpty {
                    tagSets.append(Self.makeTagSet(entityId: cardId, tags: tags))
                }
                edges.append(.init(id: "has-card-\(cardId)", srcId: deckId, dstId: cardId, rel: .has, createdAt: now))
                edges.append(.init(id: "has-lemma-\(lemmaId)", srcId: deckId, dstId: lemmaId, rel: .has, createdAt: now))
                edges.append(.init(id: "inst-\(cardId)-\(lemmaId)", srcId: cardId, dstId: lemmaId, rel: .instantiates, createdAt: now))
            } else {
                let cardId = "card-\(deckId)-\(Self.sanitize(front))"
                nodes.append(.init(id: cardId, kind: .card, createdAt: now))
                texts.append(TextComponent(
                    entityId: cardId, textA: front,
                    textB: back.isEmpty ? nil : back, language: nil))
                scheds.append(Self.makeInitialSchedule(entityId: cardId, now: now))
                if !tags.isEmpty {
                    tagSets.append(Self.makeTagSet(entityId: cardId, tags: tags))
                }
                edges.append(.init(id: "has-card-\(cardId)", srcId: deckId, dstId: cardId, rel: .has, createdAt: now))
            }
            progress(Double(idx + 1) / Double(total))
        }
        progress(1.0)
        return ImportBatch(
            deckId: deckId, nodes: nodes, textComponents: texts,
            deckMetas: [deckMeta], lemmaMetas: lemmaMetas, tagSets: tagSets,
            scheduleStates: scheds, edges: edges, failures: failures)
    }

    // MARK: - Helpers

    private struct ColumnMap {
        let lemma: Int?
        let pos: Int?
        let front: Int?
        let back: Int?
        let tags: Int?
        var hasAnyKnown: Bool { lemma != nil || pos != nil || front != nil || back != nil || tags != nil }
    }

    static func detectDelimiter(in line: String) -> Character {
        let candidates: [(Character, Int)] = [",", "\t", ";"].map { ch in
            (ch, line.reduce(0) { $1 == ch ? $0 + 1 : $0 })
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0 ?? ","
    }

    /// 简易 CSV 行解析，支持双引号包裹与 "" 转义。
    static func parseLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        current.append("\""); i += 2; continue
                    } else { inQuotes = false }
                } else { current.append(ch) }
            } else {
                if ch == "\"" { inQuotes = true }
                else if ch == delimiter { fields.append(current); current = "" }
                else { current.append(ch) }
            }
            i += 1
        }
        fields.append(current)
        return fields
    }

    private static func mapColumns(_ headers: [String]) -> ColumnMap {
        var lemma: Int? = nil, pos: Int? = nil, front: Int? = nil, back: Int? = nil, tags: Int? = nil
        for (i, h) in headers.enumerated() {
            let key = h.lowercased().trimmingCharacters(in: .whitespaces)
            switch key {
            case "lemma", "headword", "word":
                if lemma == nil { lemma = i }
            case "pos", "词性":
                if pos == nil { pos = i }
            case "front", "正面":
                if front == nil { front = i }
            case "back", "背面":
                if back == nil { back = i }
            case "tags", "tag":
                if tags == nil { tags = i }
            default: break
            }
        }
        return ColumnMap(lemma: lemma, pos: pos, front: front, back: back, tags: tags)
    }

    /// 把任意字符串清理为安全的 id 片段：小写 + 非字母数字转连字符。
    static func sanitize(_ s: String) -> String {
        let trimmed = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var lastHyphen = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar); lastHyphen = false
            } else if !lastHyphen {
                result.append("-"); lastHyphen = true
            }
        }
        return result.isEmpty ? "x" : result
    }

    static func makeInitialSchedule(entityId: EntityID, now: Date) -> ScheduleStateComponent {
        // @ai: `difficulty` 承载 SM-2 的 factor，策略里以 `state.difficulty ?? 2.5` 取默认值。
        //      旧实现写死 `difficulty: 0` → `?? 2.5` 永远不生效，factor 恒为 0，
        //      于是第二次复习 `interval = previousInterval * 0 = 0`，卡片永远当天到期。
        //      新卡应留 nil，让策略用默认 factor 2.5。
        ScheduleStateComponent(
            entityId: entityId, stability: nil, difficulty: nil, dueAt: now,
            intervalDays: nil, reps: 0, lapses: 0, lastRating: nil,
            lastReviewedAt: nil, schedulerId: nil, queue: "new", customDataJson: nil)
    }

    static func makeTagSet(entityId: EntityID, tags: String) -> TagSetComponent {
        let arr = tags.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let json = (try? JSONEncoder().encode(arr))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return TagSetComponent(entityId: entityId, tagsJson: json)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
