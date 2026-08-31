import AppKit
import SwiftUI

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

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
            return World(database: appDB)
        } catch {
            // 回退：进程内内存库（关 app 即丢，仅用于兜底启动）
            let appDB = (try? AppDatabase.inMemory()) ?? (try! AppDatabase.inMemory())
            return World(database: appDB)
        }
    }
}
