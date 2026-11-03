// 访达扩展（M9）：访达右键菜单的第一层，不用再进「服务」（用户问「右键菜单必须放在服务里面吗，能不能挪出来」，又要「右键新建任意文件」）。
// - 选中文件右键：「用 Kitty Box 打包… / 直接打包 / 解压 / 转换图片 / 转换视频 / 去 AI 水印 / 去背景」，只列选中的文件全都用得上的；
//   各带 App 里那个工具的符号（模板图、单色，同访达自己的菜单项，不放彩色色块）。
//   点了用 App 自己的网址把工具和文件交给 App：<App 的 bundle id>://open?tool=pack&file=/a&file=/b（App 那边是 Services.request）。
//   「直接打包」（用户要「右键点击后能直接打包，就类似快捷操作」）另带 App 偏好里的凭证（run=），App 不开窗口直接打在旁边；
//   App 没开着时藏着开（不弹主窗口、不抢前台）。
// - 文件夹空白处右键：「新建文件 ▸」文本文件、Markdown、Word、Excel、PPT（模板在 Templates/，Word 用系统 textutil 转的，
//   Excel、PPT 是手写的最小 Office Open XML），再加上「新建文件模板」文件夹里用户自己放的任何文件（放什么就能新建什么）。
//   拷一份到这个文件夹，重名加「 2」，日期是新建的时候（不带模板的）；拷不进去（沙盒例外以外的地方、只读的盘）响一声。
//   模板文件夹第一次用时放进 Starters/ 里的几个例子（JSON、HTML、Python、Shell、CSV），只放一次，删了不再放回来。
//   「自定义后缀…」（用户要「新建文件添加一个自定义后缀」）：问后缀的框由 App 弹（<id>://suffix?folder=/a，App 那边是 NewFile）——
//   扩展是后台进程（BackgroundOnly），弹不出窗口，原来在这里弹，点了没反应。
// - 两处都有「用 X 打开」（用户要「右键进入指定应用」）：App 设置里选的那几个 App（默认只有终端），空白处打开这个文件夹，
//   选中的打开选中的；它认不得的文件改开所在的文件夹（终端碰到文本、图片会当脚本跑）。App 列表从 App 的偏好里读。
// 扩展必须在沙盒里：交给 App 的那几项不碰文件；新建文件要写用户的文件夹，靠 Config/Finder.entitlements 里的例外（home 和外接盘），
// 读 App 的偏好也是那里的只读例外。
// 看所有位置（directoryURLs 设成根目录），不只是某几个文件夹里才有菜单。
// 要在 系统设置 › 通用 › 登录项与扩展 › 访达 里打开它（App 的设置 › 通用 › 访达 有按钮）。

import AppKit
import FinderSync
import ImageIO
import UniformTypeIdentifiers
import os

/// 拷不进去这类失败记一笔（扩展没有界面，Console 里按 subsystem 看）
private let log = Logger(subsystem: "com.yy.kitty-box", category: "finder")

final class FinderMenu: FIFinderSync {
  /// 选中的文件交给 App 的哪个工具（rawValue 就是 App 的 Tool.rawValue；packNow 交给 pack，另带凭证）
  private enum Tool: String, CaseIterable {
    case pack, packNow, unpack, convert, videoConvert, aiMark, cutout

    var title: String {
      switch self {
      // 「…」：还要在 App 里点「打包」；直接打包不用
      case .pack: "用 Kitty Box 打包…"
      case .packNow: "用 Kitty Box 直接打包"
      case .unpack: "用 Kitty Box 解压"
      case .convert: "用 Kitty Box 转换图片"
      case .videoConvert: "用 Kitty Box 转换视频"
      case .aiMark: "用 Kitty Box 去 AI 水印"
      case .cutout: "用 Kitty Box 去背景"
      }
    }

    /// 同 App 里各工具的符号（Tool.symbol，描边的基础名）
    var symbol: String {
      switch self {
      case .pack: "archivebox"
      case .packNow: "archivebox.fill"
      case .unpack: "arrow.up.bin"
      case .convert: "photo.on.rectangle.angled"
      case .videoConvert: "play.rectangle.on.rectangle"
      case .aiMark: "sparkles"
      case .cutout: "circle.rectangle.filled.pattern.diagonalline"
      }
    }

    /// 同 App 里各工具收什么（Archiver.isArchive、ImageConverter.canRead、VideoDelogo.isVideo），按扩展名判断，不读文件
    func fits(_ url: URL) -> Bool {
      let ext = url.pathExtension.lowercased()
      let type = UTType(filenameExtension: ext)
      return switch self {
      case .pack, .packNow: true
      case .unpack: Self.archives.contains(ext) || (ext.count == 3 && ext.allSatisfy(\.isNumber))
      case .convert, .aiMark, .cutout:
        type.map { type in Self.images.contains { type.conforms(to: $0) } } == true
      case .videoConvert: type?.conforms(to: .movie) == true
      }
    }

    /// 系统读得了的图片（同 ImageConverter.canRead）：只看「是图片」的话 SVG、AI、EMF 也算，App 那边却收不了
    private static let images = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
      .compactMap { UTType($0) }

    /// ponytail: 抄的 Archiver.archiveExtensions，那边加了这里跟着加
    private static let archives: Set<String> = [
      "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
      "lz",
      "lzma", "z", "cab", "iso", "arj", "lzh", "cpio", "xar", "wim",
    ]
  }

  /// App 的 id：扩展的 id 是 App 的 id 加 .finder（Debug、Release 各认各的）
  private static let appID =
    (Bundle.main.bundleIdentifier.map { ($0 as NSString).deletingPathExtension })
    ?? "com.yy.kitty-box"

  /// App 的偏好（Finder.entitlements 的只读例外）：「用 App 打开」的列表、直接打包的凭证
  private static var appDefaults: UserDefaults? { UserDefaults(suiteName: appID) }

  /// 随扩展的模板，按这个顺序排在菜单最前面
  private static let builtIn = [
    "文本文件.txt", "Markdown.md", "Word 文档.docx", "Excel 表格.xlsx", "PPT 演示文稿.pptx",
  ]

  /// 模板文件夹里先放的例子（Starters/，进包后和自带的一样平铺在 Resources 里）
  private static let starters = [
    "JSON 文件.json", "HTML 网页.html", "Python 脚本.py", "Shell 脚本.sh", "CSV 表格.csv",
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
    case .contextualMenuForItems: itemMenu()
    case .contextualMenuForContainer: folderMenu()
    default: nil
    }
  }

  // MARK: 交给 App

  private func itemMenu() -> NSMenu? {
    guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else {
      return nil
    }
    let menu = NSMenu()
    for (index, tool) in Tool.allCases.enumerated() where urls.allSatisfy(tool.fits) {
      let item = menu.addItem(withTitle: tool.title, action: #selector(hand(_:)), keyEquivalent: "")
      item.tag = index
      // 系统符号本来就是模板图：访达按菜单的字色画
      item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
    }
    addOpenWith(to: menu, action: #selector(openItems(_:)))
    return menu
  }

  @objc private func hand(_ sender: AnyObject?) {
    guard let index = (sender as? NSMenuItem)?.tag, Tool.allCases.indices.contains(index),
      let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty
    else { return }
    let tool = Tool.allCases[index]
    var link = URLComponents()
    // App 用自己的 id 当网址的 scheme
    link.scheme = Self.appID
    link.host = "open"
    link.queryItems =
      [URLQueryItem(name: "tool", value: tool == .packNow ? Tool.pack.rawValue : tool.rawValue)]
      + urls.map { URLQueryItem(name: "file", value: $0.path) }
    let configuration = NSWorkspace.OpenConfiguration()
    if tool == .packNow {
      // ponytail: 键名抄的 App 的 Prefs.finderKey；App 还没开过一次时没有凭证，App 照「打包…」放进打包页
      link.queryItems?.append(
        URLQueryItem(name: "run", value: Self.appDefaults?.string(forKey: "finderKey")))
      configuration.activates = false
      // 开着的 App 不藏（藏了用户正看着的窗口也没了）
      configuration.hides =
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.appID).isEmpty
    }
    guard let url = link.url else { return }
    NSWorkspace.shared.open(url, configuration: configuration) { _, error in
      if let error { log.error("交给 App 失败：\(error, privacy: .public)") }
    }
  }

  // MARK: 新建文件

  private func folderMenu() -> NSMenu? {
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
      withTitle: "自定义后缀…", action: #selector(createCustom(_:)), keyEquivalent: "")
    templates.addItem(
      withTitle: "添加自己的模板…", action: #selector(showTemplates(_:)), keyEquivalent: "")
    let menu = NSMenu()
    menu.addItem(withTitle: "新建文件", action: nil, keyEquivalent: "").submenu = templates
    addOpenWith(to: menu, action: #selector(openFolder(_:)))
    return menu
  }

  /// 随扩展的几个在前，用户放的按名字排在后面（隐藏文件不算）
  private static func templates() -> [URL] {
    copyStarters()
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
    let target = Self.freeName(template.lastPathComponent, in: folder)
    do {
      try FileManager.default.copyItem(at: template, to: target)
    } catch {
      log.error("新建文件失败：\(error, privacy: .public)")
      NSSound.beep()
      return
    }
    // 拷贝会带上模板的日期：新建的文件是现在建的，不然在「最近使用」、按日期排时排到老文件里
    try? FileManager.default.setAttributes(
      [.creationDate: Date.now, .modificationDate: Date.now], ofItemAtPath: target.path)
  }

  /// 问后缀的框交给 App 弹（App 那边是 NewFile）：扩展是后台进程，弹不出窗口
  @objc private func createCustom(_ sender: AnyObject?) {
    guard let folder = FIFinderSyncController.default().targetedURL() else { return }
    var link = URLComponents()
    link.scheme = Self.appID
    link.host = "suffix"
    link.queryItems = [URLQueryItem(name: "folder", value: folder.path)]
    if let url = link.url { NSWorkspace.shared.open(url) }
  }

  /// 这个文件夹里没人用的名字：重名加「 2」「 3」
  private static func freeName(_ name: String, in folder: URL) -> URL {
    let (stem, ext) = ((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
    var target = folder.appending(path: name)
    var number = 2
    while FileManager.default.fileExists(atPath: target.path) {
      target = folder.appending(path: "\(stem) \(number)" + (ext.isEmpty ? "" : "." + ext))
      number += 1
    }
    return target
  }

  /// 第一次用模板文件夹时放进几个例子；记在扩展自己的偏好里，只放一次（删掉的不再放回来），同名的不盖
  private static func copyStarters() {
    guard !UserDefaults.standard.bool(forKey: "startersCopied"),
      (try? FileManager.default.createDirectory(
        at: userTemplates, withIntermediateDirectories: true)) != nil
    else { return }
    for name in starters {
      guard let source = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
      try? FileManager.default.copyItem(at: source, to: userTemplates.appending(path: name))
    }
    UserDefaults.standard.set(true, forKey: "startersCopied")
  }

  @objc private func showTemplates(_ sender: AnyObject?) {
    try? FileManager.default.createDirectory(
      at: Self.userTemplates, withIntermediateDirectories: true)
    NSWorkspace.shared.open(Self.userTemplates)
  }

  // MARK: 用 App 打开

  /// App 设置里选的 App（bundle id，这台 Mac 上找得到的），从 App 的偏好里读（Finder.entitlements 的只读例外）。
  /// ponytail: 键名和默认值抄的 App 的 Prefs.openWithApps、OpenWithSection，那边改了这里跟着改
  private static var openWithApps: [URL] {
    (appDefaults?.stringArray(forKey: "openWithApps") ?? ["com.apple.Terminal"])
      .compactMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
  }

  /// 每个 App 一项「用 X 打开」，带它的图标；tag 是它在 openWithApps 里的位置
  private func addOpenWith(to menu: NSMenu, action: Selector) {
    for (index, app) in Self.openWithApps.enumerated() {
      var name = FileManager.default.displayName(atPath: app.path)
      if name.hasSuffix(".app") { name.removeLast(4) }
      // 「用终端打开」「用 Visual Studio Code 打开」：西文名两边空一格，同「用 Kitty Box 打包」
      let gap = { (end: Character?) in end?.isASCII == true ? " " : "" }
      let item = menu.addItem(
        withTitle: "用" + gap(name.first) + name + gap(name.last) + "打开", action: action,
        keyEquivalent: "")
      item.tag = index
      item.image = NSWorkspace.shared.icon(forFile: app.path)
      item.image?.size = NSSize(width: 16, height: 16)
    }
  }

  /// 空白处右键：打开这个文件夹（终端开在这里）
  @objc private func openFolder(_ sender: AnyObject?) {
    guard let folder = FIFinderSyncController.default().targetedURL() else { return }
    open([folder], with: sender)
  }

  @objc private func openItems(_ sender: AnyObject?) {
    guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else {
      return
    }
    open(urls, with: sender)
  }

  /// 文件夹原样给；文件给那个 App 认得的（系统登记的它能开的类型），认不得的改给所在的文件夹，几个落到同一个文件夹只给一次
  private func open(_ urls: [URL], with sender: AnyObject?) {
    let apps = Self.openWithApps
    guard let index = (sender as? NSMenuItem)?.tag, apps.indices.contains(index) else { return }
    let app = apps[index]
    var targets: [URL] = []
    for url in urls {
      let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      let opens =
        folder
        || NSWorkspace.shared.urlsForApplications(toOpen: url).contains { $0.path == app.path }
      let target = opens ? url : url.deletingLastPathComponent()
      if !targets.contains(target) { targets.append(target) }
    }
    NSWorkspace.shared.open(targets, withApplicationAt: app, configuration: .init()) { _, error in
      if let error { log.error("用 App 打开失败：\(error, privacy: .public)") }
    }
  }
}
