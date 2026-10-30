// 应用入口：普通窗口 App（A1：有程序坞图标，文件能拖上去；不像 Kitty Tools 只在菜单栏）。
// 主窗口是首页 HomeView，关掉后点程序坞图标、或往图标上拖文件，会再打开它；另有关于窗口（AboutView）。
// App 菜单的「关于 Kitty Box」换成自己的关于窗口，下面加「检查更新…」；打开 App 10 秒后自动查一次更新（Updater）。
// 编辑菜单的「粘贴」换成自己的：⌘V 能把文件交给工具（Paste）。

import AppKit
import SwiftUI

@main
struct KittyBoxApp: App {
  static let windowID = "main"
  static let aboutID = "about"
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  init() {
    Updater.shared.start()
  }

  var body: some Scene {
    Window("Kitty Box", id: Self.windowID) {
      HomeView()
    }
    .defaultSize(width: 760, height: 520)
    // 紧凑工具栏：标准的那种在 26 上返回按钮是 36 pt 的玻璃圆，把标题栏撑到 52 pt 高
    .windowToolbarStyle(.unifiedCompact)
    .windowResizability(.contentMinSize)
    .commands { AppCommands() }

    Window("关于 Kitty Box", id: Self.aboutID) {
      AboutView()
    }
    .windowResizability(.contentSize)
  }
}

private struct AppCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    // 「粘贴」换成自己的（Paste）：输入框里照常，别处 ⌘V 把剪贴板里的文件交给工具；同组的剪切、拷贝、全选照系统的发给响应链
    CommandGroup(replacing: .pasteboard) {
      Button("剪切") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
        .keyboardShortcut("x")
      Button("拷贝") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
        .keyboardShortcut("c")
      Button("粘贴") { Paste.perform() }.keyboardShortcut("v")
      Button("全选") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        .keyboardShortcut("a")
    }
    CommandGroup(replacing: .appInfo) {
      Button("关于 Kitty Box") { openWindow(id: KittyBoxApp.aboutID) }
      Button("检查更新…") {
        openWindow(id: KittyBoxApp.aboutID)
        Task { await Updater.shared.check() }
      }
    }
  }
}
