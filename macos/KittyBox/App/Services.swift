// 访达「服务」菜单（M5）：在访达里选中文件 → 右键 › 服务 ›「用 Kitty Box 打包 / 解压 / 转换图片 / 去 AI 水印 / 去背景」，
// 把选中的文件交给那个工具（Navigator.take），打开主窗口。菜单项写在 Config/Info.plist 的 NSServices（NSSendFileTypes：
// 解压只对压缩包、转换、去水印、去背景只对图片出现）；AppDelegate 启动时把它设成 NSApp.servicesProvider。
// M9 起另有访达扩展（KittyBoxFinder）把这几项放到右键菜单第一层：它在沙盒里，用 App 自己的网址把工具和文件交过来（request）；
// 「直接打包」带着凭证，不开窗口直接打（Navigator.packNow）。
// 服务菜单留着：不用在系统设置里打开就能用，别的 App 的「服务」里也有。

import AppKit

final class Services: NSObject {
  /// 平时就是 Navigator.shared；单测传自己的
  private let navigator: Navigator

  init(navigator: Navigator = .shared) {
    self.navigator = navigator
  }

  @objc func pack(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) { take(.pack, pasteboard) }

  @objc func unpack(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) { take(.unpack, pasteboard) }

  @objc func convert(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) { take(.convert, pasteboard) }

  @objc func aiMark(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) { take(.aiMark, pasteboard) }

  @objc func cutout(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) { take(.cutout, pasteboard) }

  /// 访达扩展点了「用 Kitty Box …」：<App 的 bundle id>://open?tool=pack&file=/a&file=/b → 交给哪个工具、哪些文件。
  /// 别的网页、App 也能打开这个网址，最多是把文件放进工具页，不会自己开始做。
  /// 「直接打包」另带 run=<凭证>（Prefs.finderKey，只有 App 和访达扩展知道）：对得上 now 才是 true，不开窗口直接打
  static func request(
    from url: URL, key: String? = UserDefaults.standard.string(forKey: Prefs.finderKey)
  ) -> (tool: Tool, files: [URL], now: Bool)? {
    guard url.scheme == Bundle.main.bundleIdentifier?.lowercased(),
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let tool = items.first(where: { $0.name == "tool" })?.value.flatMap(Tool.init(rawValue:))
    else { return nil }
    let files = items.filter { $0.name == "file" }.compactMap(\.value).map { URL(filePath: $0) }
    let now = key != nil && items.first(where: { $0.name == "run" })?.value == key
    return files.isEmpty ? nil : (tool, files, now)
  }

  private func take(_ tool: Tool, _ pasteboard: NSPasteboard) {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    guard !urls.isEmpty else { return }
    navigator.take(tool, urls)
  }
}
