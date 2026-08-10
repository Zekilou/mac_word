import XCTest
import GRDB
@testable import WordRecitingApp

final class WorldTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func seed(_ id: String, _ kind: NodeKind, textA: String? = nil) throws {
        try world.registry.insertNode(id: id, kind: kind, createdAt: epoch)
        if let textA {
            try world.registry.upsertComponent(
                TextComponent(entityId: id, textA: textA, textB: nil, language: nil))
        }
    }

    private func textA(_ id: String) throws -> String? {
        let tc: TextComponent? = try world.registry.fetchComponents(for: id, table: "comp_text")
        return tc?.textA
    }

    // MARK: - World 装配

    func testWorldHoldsRegistryAndGraph() throws {
        XCTAssertNotNil(world.registry)
        XCTAssertNotNil(world.graph)
        XCTAssertIdentical(world.registry.database, appDB)
    }

    // MARK: - 测试 System：向匹配节点的 textA 追加 " ✓"

    /// 测试 System：requiresAll=[.text]，向所有匹配节点的 comp_text.textA 追加 " ✓"。
    struct AppendCheckmarkSystem: System {
        static let requiresAll: [ComponentID] = [.text]
        typealias Context = Void

        func execute(world: World, db: Database, entities: [EntityID], context: Void) throws {
            for id in entities {
                let tc: TextComponent? = try world.registry.fetchComponents(
                    db, for: id, table: "comp_text")
                guard var comp = tc else { continue }
                comp.textA = (comp.textA ?? "") + " ✓"
                try world.registry.upsertComponent(db, comp)
            }
        }
    }

    func testRunSystemModifiesMatchedComponents() throws {
        try seed("c1", .card, textA: "hello")
        try seed("c2", .card, textA: "world")
        try seed("c3", .card)  // 无 comp_text，不会被匹配

        try world.run(AppendCheckmarkSystem(), context: ())

        XCTAssertEqual(try textA("c1"), "hello ✓")
        XCTAssertEqual(try textA("c2"), "world ✓")
        XCTAssertNil(try textA("c3"))
    }

    // MARK: - requiresAll 过滤

    func testRunSystemOnlyMatchesEntitiesWithRequiredComponents() throws {
        try seed("t1", .card, textA: "a")
        try seed("t2", .card, textA: "b")
        try seed("t3", .card)  // 无 text

        try world.run(AppendCheckmarkSystem(), context: ())

        // 只有 t1, t2 被修改
        XCTAssertEqual(try textA("t1"), "a ✓")
        XCTAssertEqual(try textA("t2"), "b ✓")
        XCTAssertNil(try textA("t3"))
    }

    // MARK: - 事务原子性

    /// 测试 System：更新后抛错，验证事务回滚。
    struct ThrowingSystem: System {
        static let requiresAll: [ComponentID] = [.text]
        struct Ctx: Sendable { let shouldThrow: Bool }

        func execute(world: World, db: Database, entities: [EntityID], context: Ctx) throws {
            for id in entities {
                let tc: TextComponent? = try world.registry.fetchComponents(
                    db, for: id, table: "comp_text")
                guard var comp = tc else { continue }
                comp.textA = (comp.textA ?? "") + " X"
                try world.registry.upsertComponent(db, comp)
            }
            if context.shouldThrow {
                throw NSError(domain: "WorldTests", code: 99, userInfo: nil)
            }
        }
    }

    func testSystemThrowingRollsBackTransaction() throws {
        try seed("rb1", .card, textA: "orig")

        XCTAssertThrowsError(
            try world.run(ThrowingSystem(), context: ThrowingSystem.Ctx(shouldThrow: true))
        ) { error in
            XCTAssertEqual((error as NSError).code, 99)
        }
        // 回滚：textA 应保持原值
        XCTAssertEqual(try textA("rb1"), "orig")
    }

    func testSystemNotThrowingCommits() throws {
        try seed("ok1", .card, textA: "orig")

        try world.run(ThrowingSystem(), context: ThrowingSystem.Ctx(shouldThrow: false))
        XCTAssertEqual(try textA("ok1"), "orig X")
    }

    // MARK: - run 内通过 registry.db 版本方法写入

    /// 验证 System 可在事务内通过 registry 的 db 版本方法插入节点。
    struct InsertNodeSystem: System {
        static let requiresAll: [ComponentID] = [.text]
        struct Ctx: Sendable { let newId: String }
        func execute(world: World, db: Database, entities: [EntityID], context: Ctx) throws {
            try world.registry.insertNode(
                db, id: context.newId, kind: .card, createdAt: Date())
        }
    }

    func testSystemCanInsertNodeViaRegistryDbVersion() throws {
        try seed("src", .card, textA: "x")
        try world.run(InsertNodeSystem(), context: InsertNodeSystem.Ctx(newId: "new-by-system"))
        let row = try world.registry.fetchNode(id: "new-by-system")
        XCTAssertEqual(row?.kind, .card)
    }
}
