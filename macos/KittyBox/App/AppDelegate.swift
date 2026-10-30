// 收文件：拖到程序坞图标上、在访达里用「打开方式」选了 Kitty Box（Info.plist 的 CFBundleDocumentTypes 声明了能收哪些），
// 交给 Navigator 分派。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    Navigator.shared.receive(urls)
  }
}
