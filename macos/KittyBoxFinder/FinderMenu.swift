// 访达扩展（M9）：访达右键菜单的第一层，不用再进「服务」（用户问「右键菜单必须放在服务里面吗，能不能挪出来」，又要「右键新建任意文件」）。
// - 选中文件右键：「用 Kitty Box 打包 / 解压 / 转换图片 / 转换视频 / 去 AI 水印 / 去背景」，只列选中的文件全都用得上的。
//   点了用 App 自己的网址把工具和文件交给 App：<App 的 bundle id>://open?tool=pack&file=/a&file=/b（App 那边是 Services.request）。
// - 文件夹空白处右键：「新建文件 ▸」文本文件、Markdown、Word、Excel、PPT（模板在 Templates/，Word 用系统 textutil 转的，
//   Excel、PPT 是手写的最小 Office Open XML），再加上「新建文件模板」文件夹里用户自己放的任何文件（放什么就能新建什么）。
//   拷一份到这个文件夹，重名加「 2」。
// 扩展必须在沙盒里：交给 App 的那几项不碰文件；新建文件要写用户的文件夹，靠 Config/Finder.entitlements 里的例外（home 和外接盘）。
// 看所有位置（directoryURLs 设成根目录），不只是某几个文件夹里才有菜单。
// 要在 系统设置 › 通用 › 登录项与扩展 › 访达 里打开它（App 的设置 › 通用 › 访达 有按钮）。

import AppKit
import FinderSync
import UniformTypeIdentifiers

final class FinderMenu: FIFinderSync {
  /// 选中的文件交给 App 的哪个工具（rawValue 就是 App 的 Tool.rawValue）
  private enum Tool: String, CaseIterable {
    case pack, unpack, convert, videoConvert, aiMark, cutout

    var title: String {
      switch self {
      case .pack: "用 Kitty Box 打包"
      case .unpack: "用 Kitty Box 解压"
      case .convert: "用 Kitty Box 转换图片"
      case .videoConvert: "用 Kitty Box 转换视频"
      case .aiMark: "用 Kitty Box 去 AI 水印"
      case .cutout: "用 Kitty Box 去背景"
      }
    }

    /// 同 App 里各工具收什么（Archiver.isArchive、ImageConverter.canRead、VideoDelogo.isVideo），按扩展名判断，不读文件
    func fits(_ url: URL) -> Bool {
      let ext = url.pathExtension.lowercased()
      let type = UTType(filenameExtension: ext)
      return switch self {
      case .pack: true
      case .unpack: Self.archives.contains(ext) || (ext.count == 3 && ext.allSatisfy(\.isNumber))
      case .convert, .aiMark, .cutout: type?.conforms(to: .image) == true
      case .videoConvert: type?.conforms(to: .movie) == true
      }
    }

    /// ponytail: 抄的 Archiver.archiveExtensions，那边加了这里跟着加
    private static let archives: Set<String> = [
      "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
      "lz",
      "lzma", "z", "cab", "iso", "arj", "lzh", "cpio", "xar", "wim",
    ]
  }

  /// 随扩展的模板，按这个顺序排在菜单最前面
  private static let builtIn = [
    "文本文件.txt", "Markdown.md", "Word 文档.docx", "Excel 表格.xlsx", "PPT 演示文稿.pptx",
  ]

  /// 用户自己的模板：~/Library/Application Support/Kitty Box/新建文件模板（App 设置里同一个文件夹）。
  /// 沙盒里 FileManager 给的 home 是容器，这里要真的 home
  private static var userTemplates: URL {
    URL(filePath: String(cString: getpwuid(getuid()).pointee.pw_dir))
      .appending(path: "Library/Application Support/Kitty Box/新建文件模板")
  }

  override init() {
    super.init()
    FIFinderSyncController.default().directoryURLs = [URL(filePath: "/")]
  }

  // 访达在主线程上要菜单、点菜单项
  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    switch menuKind {
    case .contextualMenuForItems: toolMenu()
    case .contextualMenuForContainer: newFileMenu()
    default: nil
    }
  }

  // MARK: 交给 App

  private func toolMenu() -> NSMenu? {
    guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else {
      return nil
    }
    let menu = NSMenu()
    for (index, tool) in Tool.allCases.enumerated() where urls.allSatisfy(tool.fits) {
      menu.addItem(withTitle: tool.title, action: #selector(hand(_:)), keyEquivalent: "").tag =
        index
    }
    return menu
  }

  @objc private func hand(_ sender: AnyObject?) {
    guard let index = (sender as? NSMenuItem)?.tag, Tool.allCases.indices.contains(index),
      let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty,
      let id = Bundle.main.bundleIdentifier
    else { return }
    var link = URLComponents()
    // 扩展的 id 是 App 的 id 加 .finder，App 用自己的 id 当网址的 scheme（Debug、Release 各认各的）
    link.scheme = (id as NSString).deletingPathExtension
    link.host = "open"
    link.queryItems =
      [URLQueryItem(name: "tool", value: Tool.allCases[index].rawValue)]
      + urls.map { URLQueryItem(name: "file", value: $0.path) }
    if let url = link.url { NSWorkspace.shared.open(url) }
  }

  // MARK: 新建文件

  private func newFileMenu() -> NSMenu? {
    guard FIFinderSyncController.default().targetedURL() != nil else { return nil }
    let templates = NSMenu()
    for (index, template) in Self.templates().enumerated() {
      let item = templates.addItem(
        withTitle: template.deletingPathExtension().lastPathComponent,
        action: #selector(create(_:)),
        keyEquivalent: "")
      item.tag = index
      item.image = NSWorkspace.shared.icon(forFile: template.path)
      item.image?.size = NSSize(width: 16, height: 16)
    }
    templates.addItem(.separator())
    templates.addItem(
      withTitle: "添加自己的模板…", action: #selector(showTemplates(_:)), keyEquivalent: "")
    let menu = NSMenu()
    menu.addItem(withTitle: "新建文件", action: nil, keyEquivalent: "").submenu = templates
    return menu
  }

  /// 随扩展的几个在前，用户放的按名字排在后面（隐藏文件不算）
  private static func templates() -> [URL] {
    let own =
      (try? FileManager.default.contentsOfDirectory(
        at: userTemplates, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return builtIn.compactMap { Bundle.main.url(forResource: $0, withExtension: nil) }
      + own.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
  }

  @objc private func create(_ sender: AnyObject?) {
    let templates = Self.templates()
    guard let index = (sender as? NSMenuItem)?.tag, templates.indices.contains(index),
      let folder = FIFinderSyncController.default().targetedURL()
    else { return }
    let template = templates[index]
    let (stem, ext) = (template.deletingPathExtension().lastPathComponent, template.pathExtension)
    var target = folder.appending(path: template.lastPathComponent)
    var number = 2
    while FileManager.default.fileExists(atPath: target.path) {
      target = folder.appending(path: "\(stem) \(number)" + (ext.isEmpty ? "" : "." + ext))
      number += 1
    }
    try? FileManager.default.copyItem(at: template, to: target)
  }

  @objc private func showTemplates(_ sender: AnyObject?) {
    try? FileManager.default.createDirectory(
      at: Self.userTemplates, withIntermediateDirectories: true)
    NSWorkspace.shared.open(Self.userTemplates)
  }
}
