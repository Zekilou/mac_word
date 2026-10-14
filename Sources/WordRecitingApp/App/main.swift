import AppKit
import SwiftUI

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    /// 安装标准主菜单（在窗口出现前完成，保证 ⌘Q/⌘W/⌘C/⌘V 从第一刻起可用）。
    /// @ai: 纯 AppKit 壳不会自动获得标准菜单；不装会让复制/粘贴/退出全部失效（见 AppMainMenu）。
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppMainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .headerView
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active

        let world = makeWorld()
        let hostingView = NSHostingView(rootView: ContentView(world: world))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .fullSizeContentView, .miniaturizable, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = visualEffectView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// 关闭最后一个窗口即退出应用。
    /// @ai: 本项目是单一内容窗口的应用（非文档型）。不实现此回调时，关窗后进程仍在后台运行，
    ///      而窗口实例一次性创建、没有 reopen 处理 → 用户既看不到窗口也无法再用 ⌘W 关掉它，
    ///      只能去活动监视器杀进程。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 点击 Dock 图标且无可见窗口时重新开窗（配合上面的「关窗即退出」，此路径用于
    /// 窗口被最小化/隐藏等仍存活的情形，保证用户点 Dock 能找回窗口）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// 退出前释放重量资源：停 llama-server 子进程 + 释放进程内模型缓存。
    /// @ai: llama.framework 的 Metal device 全局析构在 macOS 27 beta 上有竞态崩溃
    ///     （ggml_metal_rsets_free abort，exit() 全局析构与后台 residency 线程竞态）。
    ///      这里先释放模型权重 + 停子进程，减少占用与竞态窗口；backend 析构竞态是
    ///      llama.cpp 已知问题，非本应用可修，彻底解决需等 llama.cpp 适配 macOS 27。
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        LlamaServerProcess.shared.stopIdleWatcher()
        LlamaServerProcess.shared.stop()
        LlamaModelCache.shared.releaseAll()
    }

    /// 构建持久化 World：~/Library/Application Support/wordincontxt/db.sqlite。
    /// 若存在旧目录 WordRecitingApp 而新目录不存在，自动做一次性迁移。
    /// 文件 DB 失败时回退 in-memory（保证 app 可启动）。
    private func makeWorld() -> World {
        do {
            let dir = try AppIdentity.ensureSupportDirectory()
            let dbPath = dir.appendingPathComponent("db.sqlite").path
            let appDB = try AppDatabase.file(dbPath)
            let world = World(database: appDB)
            // 词频坐标回填（幂等，资源缺失时自动跳过）
            VocabularyMaintenance.backfillLemmaFrequency(world: world)
            VocabularyMaintenance.backfillMastery(world: world)
            VocabularyMaintenance.backfillDailyStats(world: world)
            return world
        } catch {
            // 回退：进程内内存库（关 app 即丢，仅用于兜底启动）
            let appDB = (try? AppDatabase.inMemory()) ?? (try! AppDatabase.inMemory())
            let world = World(database: appDB)
            VocabularyMaintenance.backfillLemmaFrequency(world: world)
            VocabularyMaintenance.backfillMastery(world: world)
            VocabularyMaintenance.backfillDailyStats(world: world)
            return world
        }
    }
}
