// 主窗口选的是哪个工具，和收进来的文件往哪送（A1、A2）。主窗口是侧边栏 + 工具页（MainView），没有首页。
// - 拖到侧边栏的某一项：交给那个工具。
// - 拖进工具页、⌘V 粘贴：交给当前工具；当前工具一个都收不了时照下面分派。
// - 拖到程序坞图标、访达里「打开方式」：全是压缩包就解压；当前工具（打包除外）全收得了就给它；里面有图片或视频就弹出来问交给谁；
//   别的交给打包。
// 各工具的状态（选了什么、做到哪了）放在这里，切到别的工具再回来还在。

import AppKit
import Observation
import SwiftUI

@Observable final class Navigator {
  static let shared = Navigator()

  /// 侧边栏选中的工具（上次用的那个，记在偏好里）
  var tool: Tool {
    didSet { defaults.set(tool.rawValue, forKey: Prefs.lastTool) }
  }
  let pack = PackModel()
  let unpack = UnpackModel()
  let convert = ImageBatch()
  let gemini = ImageBatch()
  let erase = EraseModel()
  let video = VideoMarkModel()
  /// 收到了、要问交给哪个工具的文件
  var pending: [URL] = []
  /// 「添加文件…」（⌘O、工具栏的 +、空状态的按钮）：MainView 弹出选文件，选好交给当前工具
  var importing = false
  /// MainView 出现时记下，窗口关着时收到文件用它重新打开
  @ObservationIgnored var openWindow: OpenWindowAction?
  @ObservationIgnored private let defaults: UserDefaults

  /// 单测、截图自检传一个临时的偏好域进来，不写用户的偏好
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    tool = Tool(rawValue: defaults.string(forKey: Prefs.lastTool) ?? "") ?? .pack
  }

  func open(_ tool: Tool, with urls: [URL]) {
    pending = []
    switch tool {
    case .pack: pack.add(urls)
    case .unpack: unpack.add(urls.filter(Archiver.isArchive))
    case .convert: convert.add(urls)
    case .gemini: gemini.add(urls)
    case .erase: if let first = urls.first(where: ImageConverter.canRead) { erase.load(first) }
    case .video: if let first = urls.first(where: VideoDelogo.isVideo) { video.load(first) }
    }
    self.tool = tool
  }

  /// 没指明给谁的一批文件（程序坞、打开方式，或当前工具收不了的）
  func route(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    if urls.allSatisfy(Archiver.isArchive) {
      open(.unpack, with: urls)
    } else if tool != .pack, urls.allSatisfy({ tool.accepts($0) }) {
      open(tool, with: urls)
    } else if urls.contains(where: { ImageConverter.canRead($0) || VideoDelogo.isVideo($0) }) {
      pending = urls
    } else {
      open(.pack, with: urls)
    }
  }

  /// 拖进工具页、⌘V 粘贴：当前工具收得了就给它，一个都收不了再分派
  func give(_ urls: [URL]) {
    if accepts(tool, urls) {
      open(tool, with: urls)
    } else {
      route(urls)
    }
  }

  /// 这批文件里有没有这个工具能收的（问交给谁时只列能收的）
  func accepts(_ tool: Tool, _ urls: [URL]) -> Bool {
    urls.contains(where: tool.accepts)
  }

  /// 文件拖到程序坞图标、或在访达里「打开方式」选了本 App
  func receive(_ urls: [URL]) {
    route(urls)
    openWindow?(id: KittyBoxApp.windowID)
    NSApp.activate()
  }
}

extension Tool {
  func accepts(_ url: URL) -> Bool {
    switch self {
    case .pack: true
    case .unpack: Archiver.isArchive(url)
    case .convert, .gemini, .erase: ImageConverter.canRead(url)
    case .video: VideoDelogo.isVideo(url)
    }
  }
}
