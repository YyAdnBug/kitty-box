// 首页的导航，和拖进来的文件往哪送（A1、A2）：拖到某一格就交给那个工具；拖到程序坞图标或首页空白处，全是压缩包就直接解压，
// 里面有图片或视频就回首页、顶上一条提示让你点一格交给它（图片可能要转格式、去水印、打包），别的交给打包。
// 各工具页的状态（选了什么、做到哪了）放在这里，回到首页再进去还在。

import AppKit
import Observation
import SwiftUI

@Observable final class Navigator {
  static let shared = Navigator()

  var path: [Tool] = []
  let pack = PackModel()
  let unpack = UnpackModel()
  let convert = ImageBatch()
  let watermark = WatermarkModel()
  /// 拖进来、还没决定交给哪个工具的文件
  var pending: [URL] = []
  /// 首页出现时记下，窗口关着时收到文件用它重新打开
  @ObservationIgnored var openWindow: OpenWindowAction?

  func open(_ tool: Tool, with urls: [URL]) {
    pending = []
    switch tool {
    case .pack: pack.add(urls)
    case .unpack: unpack.add(urls.filter(Archiver.isArchive))
    case .convert: convert.add(urls)
    case .watermark: watermark.add(urls)
    }
    path = [tool]
  }

  func route(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    if urls.allSatisfy(Archiver.isArchive) {
      open(.unpack, with: urls)
    } else if urls.contains(where: { ImageConverter.canRead($0) || VideoDelogo.isVideo($0) }) {
      pending = urls
      path = []
    } else {
      open(.pack, with: urls)
    }
  }

  /// 这批文件能不能交给这个工具（首页上不能收的格子变淡、点不了）
  func accepts(_ tool: Tool, _ urls: [URL]) -> Bool {
    switch tool {
    case .pack: true
    case .unpack: urls.contains(where: Archiver.isArchive)
    case .convert: urls.contains(where: ImageConverter.canRead)
    case .watermark: urls.contains { ImageConverter.canRead($0) || VideoDelogo.isVideo($0) }
    }
  }

  /// 文件拖到程序坞图标、或在访达里「打开方式」选了本 App
  func receive(_ urls: [URL]) {
    route(urls)
    openWindow?(id: KittyBoxApp.windowID)
    NSApp.activate()
  }
}
