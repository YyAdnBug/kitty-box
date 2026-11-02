// 主窗口选的是哪个工具，和收进来的文件往哪送（A1、A2）。主窗口是侧边栏 + 工具页（MainView），没有首页。
// - 拖到侧边栏的某一项：交给那个工具。
// - 拖进工具页、⌘V 粘贴：交给当前工具；当前工具一个都收不了时照下面分派。
// - 拖到程序坞图标、访达里「打开方式」：全是压缩包就解压；当前工具（打包除外）全收得了就给它；里面有图片或视频就弹出来问交给谁；
//   别的交给打包。
// - App 自己的网址（访达扩展；别的网页、App 也能打开）：交给指明的工具，压缩包只放进解压页、不自己开始。
// 各工具的状态（选了什么、做到哪了）放在这里，切到别的工具再回来还在；退出 App 前问有没有活在做、停下等收尾（busy、stopAll）。

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
  let convert = FileBatch()
  let videoConvert = FileBatch(accepts: VideoDelogo.isVideo)
  let cutout = FileBatch()
  let aiMark = FileBatch()
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

  /// autostart = false：压缩包只放进解压页，等用户点「开始解压」（App 自己的网址交过来的）
  func open(_ tool: Tool, with urls: [URL], autostart: Bool = true) {
    pending = []
    switch tool {
    case .pack: pack.add(urls)
    case .unpack: unpack.add(urls.filter(Archiver.isArchive), autostart: autostart)
    case .convert: convert.add(urls)
    case .videoConvert: videoConvert.add(urls)
    case .cutout: cutout.add(urls)
    case .aiMark: aiMark.add(urls)
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

  /// 访达「服务」菜单、App 自己的网址指明了交给哪个工具（Services）：交给它、打开主窗口。
  /// 网址谁都能打开（网页、别的 App），只把文件放进工具页、不自己开始做：autostart = false
  func take(_ tool: Tool, _ urls: [URL], autostart: Bool = true) {
    open(tool, with: urls, autostart: autostart)
    openWindow?(id: KittyBoxApp.windowID)
    NSApp.activate()
  }

  /// 还在写文件的活：打包、解压、一批图 / 视频、视频台标导出（退出 App、更新前要问）。
  /// 读一张图、画笔擦除补一笔不算：只在内存里，停了不留东西
  var busy: Bool {
    pack.running || unpack.running || video.isExporting
      || [convert, videoConvert, cutout, aiMark].contains(where: \.running)
  }

  /// 退出 App 前：都停下，等各自的收尾走完再回来——子进程停掉（SIGTERM）、解了一半的「.名字 解压中」、
  /// 打了一半的包、转了一半的视频删掉（不然 tar、7zz 在 App 退出后接着跑，半截的东西留在原文件旁边）
  func stopAll() async {
    // 一起喊停、一起等：不用一个收完尾再停下一个
    await withDiscardingTaskGroup { group in
      group.addTask { await self.pack.stopAndWait() }
      group.addTask { await self.unpack.stopAll() }
      group.addTask { await self.video.stopAndWait() }
      for batch in [convert, videoConvert, cutout, aiMark] {
        group.addTask { await batch.stopAndWait() }
      }
    }
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
    case .convert, .cutout, .aiMark, .erase: ImageConverter.canRead(url)
    case .video, .videoConvert: VideoDelogo.isVideo(url)
    }
  }
}
