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

        let hostingView = NSHostingView(rootView: ContentView())
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
}

struct ContentView: View {
    var body: some View {
        Text("Hello, WordReciting")
            .padding()
    }
}
