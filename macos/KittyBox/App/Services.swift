// 访达「服务」菜单（M5）：在访达里选中文件 → 右键 › 服务 ›「用 Kitty Box 打包 / 解压 / 转换图片 / 去 Gemini 角标」，
// 把选中的文件交给那个工具（Navigator.take），打开主窗口。菜单项写在 Config/Info.plist 的 NSServices（NSSendFileTypes：
// 解压只对压缩包、转换和去角标只对图片出现）；AppDelegate 启动时把它设成 NSApp.servicesProvider。
// 不另写访达扩展（FinderSync 要多一个 target、多一层签名），服务菜单够用。

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

  @objc func gemini(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) { take(.gemini, pasteboard) }

  private func take(_ tool: Tool, _ pasteboard: NSPasteboard) {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    guard !urls.isEmpty else { return }
    navigator.take(tool, urls)
  }
}
