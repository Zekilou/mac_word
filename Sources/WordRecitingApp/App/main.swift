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

    /// 构建持久化 World：~/Library/Application Support/WordRecitingApp/db.sqlite。
    /// 文件 DB 失败时回退 in-memory（保证 app 可启动）。
    private func makeWorld() -> World {
        do {
            let fm = FileManager.default
            let support = try fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let dir = support.appendingPathComponent("WordRecitingApp", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
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
