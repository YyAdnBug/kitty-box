// 收文件：拖到程序坞图标上、在访达里用「打开方式」选了 Kitty Box（Info.plist 的 CFBundleDocumentTypes 声明了能收哪些），
// 交给 Navigator 分派；访达「服务」菜单交给 Services（启动时登记）；访达扩展用 App 自己的网址指明交给哪个工具（Services.request）。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let services = Services()

  func applicationDidFinishLaunching(_ notification: Notification) {
    Appearance(rawValue: UserDefaults.standard.string(forKey: Prefs.appearance) ?? "")?.apply()
    NSApp.servicesProvider = services
    NSUpdateDynamicServices()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.filter(\.isFileURL)
    if !files.isEmpty { Navigator.shared.receive(files) }
    for request in urls.compactMap(Services.request) {
      Navigator.shared.take(request.tool, request.files)
    }
  }
}
