// 主窗口选的是哪个工具，和收进来的文件往哪送（A1、A2）。主窗口是侧边栏 + 工具页（MainView），没有首页。
// - 拖到侧边栏的某一项：交给那个工具。
// - 拖进工具页、⌘V 粘贴：交给当前工具；当前工具一个都收不了时照下面分派。
// - 拖到程序坞图标、访达里「打开方式」：全是压缩包就解压；当前工具（打包除外）全收得了就给它；里面有图片或视频就弹出来问交给谁；
//   别的交给打包。
// - App 自己的网址（访达扩展；别的网页、App 也能打开）：交给指明的工具，压缩包只放进解压页、不自己开始；
//   访达「直接打包」（带着凭证）不开窗口、不进打包页，直接打在旁边（packNow）。
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
  /// 访达「直接打包」在打的（packNow），一次右键一个
  @ObservationIgnored private var packing: [UUID: Task<Void, Never>] = [:]
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

  /// 访达右键「用 Kitty Box 直接打包」（2026-11-03，用户要「右键点击后能直接打包，就类似快捷操作」）：不开窗口、不进打包页，
  /// 照打包页记着的格式、压缩级别、忽略清单，不设密码，包放在第一样东西旁边（同访达「压缩」）。
  /// 做完程序坞图标跳一下；没打成弹框说原因。App 是为它藏着开的（还没在程序坞里露过面）就打完自己退，同访达的快速操作
  func packNow(_ urls: [URL]) {
    let id = UUID()
    // 默认值同 PackView 的 @AppStorage
    let options = Archiver.PackOptions(
      format: Archiver.Format(rawValue: defaults.string(forKey: Prefs.packFormat) ?? "") ?? .zip,
      level: Archiver.Level(rawValue: defaults.string(forKey: Prefs.packLevel) ?? "") ?? .normal)
    let rules = pack.ignore.rules
    packing[id] = Task {
      do {
        let plan = await Archiver.plan(urls, rules: rules)
        try Task.checkCancellation()
        guard !plan.files.isEmpty else {
          throw Archiver.Failure.failed("选中的东西都在忽略清单里，没有要打包的文件。")
        }
        let url = try await ProcessInfo.processInfo.working("正在打包") {
          try await Archiver.pack(plan, options: options)
        }
        NSApp.finished("已生成「\(url.lastPathComponent)」")
      } catch is CancellationError {
        // 退出 App 时停下的（stopAll）：不再喊退出
        packing[id] = nil
        return
      } catch {
        NSApp.finished("没打成：" + error.localizedDescription)
        let alert = NSAlert()
        alert.messageText = "没打成包"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
      }
      packing[id] = nil
      if NSApp.activationPolicy() == .accessory, !busy { NSApp.terminate(nil) }
    }
  }

  /// 还在写文件的活：打包（含访达直接打包）、解压、一批图 / 视频、视频台标导出（退出 App、更新前要问）。
  /// 读一张图、画笔擦除补一笔不算：只在内存里，停了不留东西
  var busy: Bool {
    pack.running || !packing.isEmpty || unpack.running || video.isExporting
      || [convert, videoConvert, cutout, aiMark].contains(where: \.running)
  }

  /// 退出 App 前：都停下，等各自的收尾走完再回来——子进程停掉（SIGTERM）、解了一半的「.名字 解压中」、
  /// 打了一半的包、转了一半的视频删掉（不然 tar、7zz 在 App 退出后接着跑，半截的东西留在原文件旁边）
  func stopAll() async {
    // 一起喊停、一起等：不用一个收完尾再停下一个
    await withDiscardingTaskGroup { group in
      group.addTask { await self.pack.stopAndWait() }
      for task in packing.values {
        group.addTask {
          task.cancel()
          await task.value
        }
      }
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
