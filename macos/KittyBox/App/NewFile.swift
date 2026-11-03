// 访达「新建文件 ▸ 自定义后缀…」的框（2026-11-03，用户要「新建文件添加一个自定义后缀」）。框原来在访达扩展里弹，点了没反应：
// 扩展是后台进程（BackgroundOnly），弹不出窗口。现在扩展用 App 自己的网址把文件夹交过来：<App 的 bundle id>://suffix?folder=/a，
// App 弹框问后缀（记着上次填的），建一个空的「YAML 文件.yaml」，重名加「 2」；框关了 App 藏起来，访达回到前面。
// 框里「以后列在「新建文件」里」默认勾着：模板文件夹里也放一个同名的空文件，下次直接点；已有这个后缀的模板（含自带的）就不再放。
// 网址谁都能打开：最多弹个框，建不建要用户点。

import AppKit

enum NewFile {
  /// 访达扩展的「新建文件模板」文件夹（FinderMenu.userTemplates，设置里「打开模板文件夹」同一个）
  static var templates: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Kitty Box/新建文件模板")
  }

  /// ponytail: 抄的访达扩展自带的五种（FinderMenu.builtIn）的后缀，那边加了这里跟着加
  private static let builtIn: Set = ["txt", "md", "docx", "xlsx", "pptx"]

  /// <App 的 bundle id>://suffix?folder=/a → /a；别的网址不认
  static func folder(from url: URL) -> URL? {
    guard url.scheme == Bundle.main.bundleIdentifier?.lowercased(), url.host() == "suffix",
      let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "folder" })?.value
    else { return nil }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  /// 填的后缀 → 文件名：前后的点和空格去掉，「yaml」→「YAML 文件.yaml」；空的、带 / 或 : 的（进不了文件名）是 nil
  static func name(for suffix: String) -> String? {
    let suffix = suffix.trimmingCharacters(
      in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    guard !suffix.isEmpty, !suffix.contains("/"), !suffix.contains(":") else { return nil }
    return "\(suffix.uppercased()) 文件.\(suffix)"
  }

  static func ask(in folder: URL) {
    let alert = NSAlert()
    alert.messageText = "新建什么后缀的文件？"
    alert.informativeText = "在「\(FileManager.default.displayName(atPath: folder.path))」里新建一个空文件。"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = UserDefaults.standard.string(forKey: Prefs.lastSuffix) ?? ""
    field.placeholderString = "比如 json、py、sh"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "以后列在「新建文件」里"
    alert.suppressionButton?.state = .on
    alert.addButton(withTitle: "新建")
    alert.addButton(withTitle: "取消")
    NSApp.activate()
    let answer = alert.runModal()
    // 是在访达里点的：框关了回到访达
    NSApp.hide(nil)
    guard answer == .alertFirstButtonReturn else { return }
    guard let name = name(for: field.stringValue) else {
      NSSound.beep()
      return
    }
    let suffix = (name as NSString).pathExtension
    UserDefaults.standard.set(suffix, forKey: Prefs.lastSuffix)
    do {
      try Data().write(to: folder.appending(path: name).uniqued(), options: .withoutOverwriting)
    } catch {
      NSSound.beep()
      return
    }
    let own =
      (try? FileManager.default.contentsOfDirectory(
        at: templates, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    let known =
      builtIn.contains(suffix.lowercased())
      || own.contains { $0.pathExtension.lowercased() == suffix.lowercased() }
    if alert.suppressionButton?.state == .on, !known {
      try? FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
      try? Data().write(to: templates.appending(path: name), options: .withoutOverwriting)
    }
  }
}
