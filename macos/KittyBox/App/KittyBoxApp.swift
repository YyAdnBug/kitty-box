// 应用入口：普通窗口 App（A1：有程序坞图标，文件能拖上去；不像 Kitty Tools 只在菜单栏）。设置窗口（SettingsView，⌘,）。
// 主窗口是 MainView（侧边栏 + 工具页），关掉后点程序坞图标、或往图标上拖文件，会再打开它；另有关于窗口（AboutView）。
// App 菜单的「关于 Kitty Box」换成自己的关于窗口，下面加「检查更新…」；打开 App 10 秒后自动查一次更新（Updater）。
// 编辑菜单的「粘贴」换成自己的：⌘V 能把文件交给工具（Paste）；文件菜单「添加文件…」⌘O；「工具」菜单 ⌘1–⌘6 切工具。

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
      MainView()
    }
    .defaultSize(width: 1040, height: 680)
    // 标题栏透明、不占地方：各页的页头顶到窗口最上面、和红绿灯一排（原来页头压在标题栏下面，上面空着一大条，用户报）。
    // 透明的标题栏才把那一排的点击交给页里的按钮（不透明时整排都归标题栏、只能拖窗口，2026-10-30 实测）
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .commands { AppCommands() }

    Settings {
      SettingsView()
    }

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
    CommandGroup(replacing: .newItem) {
      Button("添加文件…") {
        openWindow(id: KittyBoxApp.windowID)
        Navigator.shared.importing = true
      }
      .keyboardShortcut("o")
    }
    CommandMenu("工具") {
      ForEach(Array(Tool.allCases.enumerated()), id: \.element) { index, tool in
        Button(tool.title) {
          openWindow(id: KittyBoxApp.windowID)
          Navigator.shared.tool = tool
        }
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
      }
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
