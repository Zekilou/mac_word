import XCTest
import AppKit
@testable import WordRecitingApp

/// 主菜单构建测试（回归）。
/// @ai: 纯 AppKit 壳不设 `NSApp.mainMenu` 时，AppKit 只建一个空应用菜单，
///      ⌘Q/⌘W/⌘C/⌘V/⌘A 全部失效（有大量 TextField 却无法粘贴）。
final class AppMainMenuTests: XCTestCase {

    @MainActor
    func testMenuContainsEssentialCommands() {
        let menu = AppMainMenu.build(appName: "wordincontxt")

        // 收集全部 (标题, keyEquivalent) 对
        var entries: [String: String] = [:]
        func walk(_ m: NSMenu) {
            for item in m.items {
                if let sub = item.submenu {
                    walk(sub)
                } else if !item.keyEquivalent.isEmpty {
                    entries[item.title] = item.keyEquivalent
                }
            }
        }
        walk(menu)

        // ⌘Q 退出（无主菜单时应用无法常规退出）
        XCTAssertEqual(entries["退出 wordincontxt"], "q", "缺少 ⌘Q 退出")
        // 编辑菜单三件套（缺失则文本框无法剪切/复制/粘贴）
        XCTAssertEqual(entries["剪切"], "x", "缺少 ⌘X 剪切")
        XCTAssertEqual(entries["拷贝"], "c", "缺少 ⌘C 拷贝")
        XCTAssertEqual(entries["粘贴"], "v", "缺少 ⌘V 粘贴")
        XCTAssertEqual(entries["全选"], "a", "缺少 ⌘A 全选")
        // 窗口
        XCTAssertEqual(entries["关闭窗口"], "w", "缺少 ⌘W 关闭窗口")
        XCTAssertEqual(entries["最小化"], "m", "缺少 ⌘M 最小化")
    }

    /// 顶级菜单应包含「应用 / 编辑 / 窗口」三组（窗口组注册为 windowsMenu）。
    @MainActor
    func testMenuTopLevelStructure() {
        let menu = AppMainMenu.build(appName: "wordincontxt")
        XCTAssertGreaterThanOrEqual(menu.items.count, 3, "至少有 应用/编辑/窗口 三个顶级菜单")
        let titles = menu.items.compactMap { $0.submenu?.title }
        XCTAssertTrue(titles.contains("编辑"), "应有编辑菜单，实际：\(titles)")
        XCTAssertTrue(titles.contains("窗口"), "应有窗口菜单，实际：\(titles)")
    }

    /// 安装后 `NSApp.mainMenu` 必须非空且带 ⌘Q（端到端确认 install 生效）。
    @MainActor
    func testInstallSetsApplicationMainMenu() {
        let app = NSApplication.shared
        let saved = app.mainMenu
        defer { app.mainMenu = saved }

        AppMainMenu.install(into: app)
        XCTAssertNotNil(app.mainMenu, "install 后 mainMenu 不应为 nil")

        let hasQuit = app.mainMenu?.items.contains { item in
            item.submenu?.items.contains { $0.keyEquivalent == "q" } ?? false
        } ?? false
        XCTAssertTrue(hasQuit, "安装后应能用 ⌘Q 退出（此前完全缺失）")
    }
}
