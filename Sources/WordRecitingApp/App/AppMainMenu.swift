import AppKit

/// 应用主菜单构建。
/// @ai: 本项目用纯 AppKit 壳（NSApplication + AppDelegate），**不会**自动获得 Xcode 模板那套
///      标准菜单。实测：不设 `NSApp.mainMenu` 时 AppKit 只建一个空的应用菜单
///      （items=1 / 子项=0），于是 ⌘Q ⌘W ⌘C ⌘V ⌘A ⌘Z 全部失效——
///      而应用里有大量 TextField（主题、目标词、API Key、RSS 源、搜索框），
///      用户连「粘贴」都做不到。这里补齐最小可用的标准菜单。
///      菜单项用 `nil` target 走响应者链（NSApp / firstResponder 自动分发），
///      所以「编辑」菜单的剪切/复制/粘贴能作用于当前聚焦的文本框。
enum AppMainMenu {

    /// 安装主菜单（幂等；在 applicationWillFinishLaunching 里调用最稳）。
    @MainActor
    static func install(into app: NSApplication = .shared) {
        app.mainMenu = build(appName: AppIdentity.brandName)
    }

    /// 构建主菜单（拆出来便于单测断言结构）。
    @MainActor
    static func build(appName: String) -> NSMenu {
        let mainMenu = NSMenu()

        // ---- 应用菜单 ----
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "关于 \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        let hide = appMenu.addItem(withTitle: "隐藏 \(appName)",
                                   action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command]
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        // @ai: ⌘Q 是应用退出的唯一常规途径（Dock 右键之外）。
        appMenu.addItem(withTitle: "退出 \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // ---- 编辑菜单（文本框剪切/复制/粘贴/全选，缺失会让粘贴彻底不可用）----
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // ---- 窗口菜单（⌘W 关闭 / ⌘M 最小化）----
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        app.windowsMenu = windowMenu

        return mainMenu
    }
}
