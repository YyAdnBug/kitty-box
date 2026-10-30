// 首页的导航，和拖进来的文件往哪送（A1、A2）：拖到某一格就交给那个工具；拖到程序坞图标或首页空白处，全是压缩包就直接解压，
// 不然交给打包。ponytail: 图片转换、去水印做好之前，非压缩包只有打包能收；M2 起改成「打开首页让你选」。
// 各工具页的状态（选了什么、做到哪了）放在这里，回到首页再进去还在。

import AppKit
import Observation
import SwiftUI

@Observable final class Navigator {
  static let shared = Navigator()

  var path: [Tool] = []
  let pack = PackModel()
  let unpack = UnpackModel()
  /// 首页出现时记下，窗口关着时收到文件用它重新打开
  @ObservationIgnored var openWindow: OpenWindowAction?

  func open(_ tool: Tool, with urls: [URL]) {
    switch tool {
    case .pack: pack.add(urls)
    case .unpack: unpack.add(urls)
    case .convert, .watermark: break
    }
    path = [tool]
  }

  func route(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    open(urls.allSatisfy(Archiver.isArchive) ? .unpack : .pack, with: urls)
  }

  /// 文件拖到程序坞图标、或在访达里「打开方式」选了本 App
  func receive(_ urls: [URL]) {
    route(urls)
    openWindow?(id: KittyBoxApp.windowID)
    NSApp.activate()
  }
}
