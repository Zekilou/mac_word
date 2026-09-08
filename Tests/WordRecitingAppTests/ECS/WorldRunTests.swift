import XCTest
import GRDB
@testable import WordRecitingApp

/// World.run 对空 requiresAll 的短路：不依赖 entity 集合的 System 不应做全表 id 扫描。
final class WorldRunTests: XCTestCase {

    private final class ProbeBox: @unchecked Sendable {
        var captured: [EntityID] = []
    }

    private struct ProbeEmptySystem: System {
        static let requiresAll: [ComponentID] = []
        typealias Context = ProbeBox
        func execute(world: World, db: Database, entities: [EntityID], context: ProbeBox) throws {
            context.captured = entities
        }
    }

    private struct ProbeTextSystem: System {
        static let requiresAll: [ComponentID] = [.text]
        typealias Context = ProbeBox
        func execute(world: World, db: Database, entities: [EntityID], context: ProbeBox) throws {
            context.captured = entities
        }
    }

    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    /// requiresAll 为空 = 该 System 不依赖 entity 集合，应传入空数组而非全表 id。
    func testEmptyRequiresAllPassesNoEntities() throws {
        try world.registry.insertNode(id: "N1", kind: .lemma, createdAt: Date())

        let box = ProbeBox()
        try world.run(ProbeEmptySystem(), context: box)

        XCTAssertTrue(box.captured.isEmpty)
    }

    /// requiresAll 非空时仍按组件签名过滤。
    func testNonEmptyRequiresAllStillFilters() throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.insertNode(id: "N2", kind: .card, createdAt: Date())

        let box = ProbeBox()
        try world.run(ProbeTextSystem(), context: box)

        XCTAssertEqual(box.captured, ["L1"])
    }
}
