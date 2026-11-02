// 收文件：拖到程序坞图标上、在访达里用「打开方式」选了 Kitty Box（Info.plist 的 CFBundleDocumentTypes 声明了能收哪些），
// 交给 Navigator 分派；访达「服务」菜单交给 Services（启动时登记）；访达扩展用 App 自己的网址指明交给哪个工具（Services.request），
// 网址谁都能打开，只放进工具页、不自己开始做。
// 退出（⌘Q、注销、「更新并重新打开」）时还有活在做：先问，要退就都停下、等半截的东西删掉再退；画笔擦除改了没存也先问。
// 右键程序坞图标：八个工具，点了打开主窗口、切到那一个。

import AppKit
import SwiftUI

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
      Navigator.shared.take(request.tool, request.files, autostart: false)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let navigator = Navigator.shared
    let busy = navigator.busy
    if busy {
      let alert = NSAlert()
      alert.messageText = "还有没做完的活，要退出吗？"
      alert.informativeText = "退出会先停下来，做了一半的文件删掉，原文件不动。"
      // 默认按钮是「取消」：误按 ⌘Q 不丢东西
      alert.addButton(withTitle: "取消")
      alert.addButton(withTitle: "退出").hasDestructiveAction = true
      guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
    }
    // 画笔擦除擦过没存：同换图时问的那一句（存储 / 取消 / 不存储）
    guard navigator.erase.mayDiscard() else { return .terminateCancel }
    guard busy else { return .terminateNow }
    // 这个任务在主队列上跑：谁要从 Task 里退出 App，用 perform(afterDelay:) 发 terminate，
    // 别在主队列的任务里直接调（等回话的时候主队列排不上，这里永远不回，见 Updater.install）
    Task {
      await navigator.stopAll()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    for tool in Tool.allCases {
      let item = menu.addItem(
        withTitle: tool.title, action: #selector(openTool(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = tool.rawValue
    }
    return menu
  }

  @objc private func openTool(_ item: NSMenuItem) {
    guard let tool = (item.representedObject as? String).flatMap(Tool.init(rawValue:)) else {
      return
    }
    Navigator.shared.tool = tool
    Navigator.shared.openWindow?(id: KittyBoxApp.windowID)
    NSApp.activate()
  }
}
