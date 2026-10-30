// 应用入口：普通窗口 App（A1：有程序坞图标，文件能拖上去；不像 Kitty Tools 只在菜单栏）。
// 只有一扇窗，内容是首页 HomeView；关掉窗口后点程序坞图标会再打开它。

import SwiftUI

@main
struct KittyBoxApp: App {
  var body: some Scene {
    Window("Kitty Box", id: "main") {
      HomeView()
    }
    .defaultSize(width: 640, height: 240)
    .windowResizability(.contentMinSize)
  }
}
