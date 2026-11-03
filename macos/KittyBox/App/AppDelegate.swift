// 收文件：拖到程序坞图标上、在访达里用「打开方式」选了 Kitty Box（Info.plist 的 CFBundleDocumentTypes 声明了能收哪些），
// 交给 Navigator 分派；访达「服务」菜单交给 Services（启动时登记）；访达扩展用 App 自己的网址指明交给哪个工具（Services.request），
// 网址谁都能打开，只放进工具页、不自己开始做；带着对得上的凭证的「直接打包」不开窗口直接打（Navigator.packNow）；
// 「新建文件 ▸ 自定义后缀…」的框也由这里弹（NewFile，扩展弹不出窗口）。
// 退出（⌘Q、注销、「更新并重新打开」）时还有活在做：先问，要退就都停下、等半截的东西删掉再退；画笔擦除改了没存也先问。
// 右键程序坞图标：八个工具，点了打开主窗口、切到那一个。
// 程序坞图标（2026-11-03 用户要「直接打包 dock 不弹出」）：Info.plist 设了 LSUIElement，启动时先没有图标，正常启动马上切成普通 App；
// 访达「直接打包」藏着开的不切，一直不在程序坞里露面，打完自己退（Navigator.packNow）；之后被打开了再切。

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let services = Services()
  /// 后台弹框（NSAlert.runModalFromBackground）：这次激活不切成普通 App
  static var askingInBackground = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    Appearance(rawValue: UserDefaults.standard.string(forKey: Prefs.appearance) ?? "")?.apply()
    NSApp.servicesProvider = services
    NSUpdateDynamicServices()
    // 访达扩展的凭证（Prefs.finderKey）：没有就生成一个，以后不变
    if UserDefaults.standard.string(forKey: Prefs.finderKey) == nil {
      UserDefaults.standard.set(UUID().uuidString, forKey: Prefs.finderKey)
    }
    // 藏着开的却没等来访达的活（登录时恢复了藏着的 App、登录项勾了「隐藏」）：不是为后台的活开的，切回普通 App（还藏着，点程序坞出来）。
    // ponytail: 按时间猜，访达交来的网址都是启动后一下子就到；真遇到慢的，改成扩展带一个启动参数
    if NSApp.activationPolicy() == .accessory {
      Task {
        try? await Task.sleep(for: .seconds(3))
        if NSApp.activationPolicy() == .accessory, !Navigator.shared.busy, !Self.askingInBackground
        {
          NSApp.setActivationPolicy(.regular)
        }
      }
    }
  }

  // 访达「直接打包」藏着开的（OpenConfiguration.hides，这时已经是藏着的）留着不露面；别的启动马上切成普通 App。
  // 不等激活再切：从别处启动时不一定激活得了（命令行 open -a 就没激活，2026-11-03 实测），会留下没有程序坞图标、没有菜单栏的窗口
  func applicationWillFinishLaunching(_ notification: Notification) {
    if !NSApp.isHidden { NSApp.setActivationPolicy(.regular) }
  }

  // 藏着开的、打包还没完就被打开了（双击、点程序坞里固定的图标）：这时再切，打完也不退
  // 后台弹框（没打成包、问后缀）的那次激活不算
  func applicationWillBecomeActive(_ notification: Notification) {
    if NSApp.activationPolicy() != .regular, !Self.askingInBackground {
      NSApp.setActivationPolicy(.regular)
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.filter(\.isFileURL)
    if !files.isEmpty { Navigator.shared.receive(files) }
    for request in urls.compactMap({ Services.request(from: $0) }) {
      if request.now, request.tool == .pack {
        Navigator.shared.packNow(request.files)
      } else {
        Navigator.shared.take(request.tool, request.files, autostart: false)
      }
    }
    for folder in urls.compactMap(NewFile.folder) { NewFile.ask(in: folder) }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let navigator = Navigator.shared
    let busy = navigator.busy
    // 后台直接打包时（藏着开的，没有程序坞图标）不问，直接停下收尾：问了也看不见，注销、关机会卡在这里
    if busy, NSApp.activationPolicy() != .accessory {
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

extension NSAlert {
  /// 弹框，App 在后台时也一样（访达直接打包没打成、问后缀；藏着开的 App 没有程序坞图标）：框照样到最前面（模态面板那一层，
  /// 系统不让激活时也在别的窗口上面，点一下就能打字），藏着的主窗口不跟着出来，这次激活不切成普通 App。框关了退不退由调用的人定
  @discardableResult func runModalFromBackground() -> NSApplication.ModalResponse {
    let background = NSApp.activationPolicy() == .accessory
    if background {
      for window in NSApp.windows { window.orderOut(nil) }
    }
    AppDelegate.askingInBackground = background
    defer { AppDelegate.askingInBackground = false }
    NSApp.activate()
    return runModal()
  }
}
