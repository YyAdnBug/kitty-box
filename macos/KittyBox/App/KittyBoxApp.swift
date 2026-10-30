// 应用入口：普通窗口 App（A1：有程序坞图标，文件能拖上去；不像 Kitty Tools 只在菜单栏）。
// 主窗口是首页 HomeView，关掉后点程序坞图标、或往图标上拖文件，会再打开它；另有关于窗口（AboutView）。
// App 菜单的「关于 Kitty Box」换成自己的关于窗口，下面加「检查更新…」；打开 App 10 秒后自动查一次更新（Updater）。

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
    .defaultSize(width: 640, height: 240)
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
    CommandGroup(replacing: .appInfo) {
      Button("关于 Kitty Box") { openWindow(id: KittyBoxApp.aboutID) }
      Button("检查更新…") {
        openWindow(id: KittyBoxApp.aboutID)
        Task { await Updater.shared.check() }
      }
    }
  }
}
