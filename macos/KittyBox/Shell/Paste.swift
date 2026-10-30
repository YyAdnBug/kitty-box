// ⌘V 粘贴文件：Edit 菜单的「粘贴」换成自己的（KittyBoxApp），输入框里照常粘贴文字；别处把剪贴板里的东西交给当前工具
// （Navigator.give，收不了再分派）——
// 访达里拷贝的文件原样交出去；只有图片数据（截图到剪贴板、浏览器里「拷贝图像」）时，原样存成「下载」里的
// 「粘贴的图片 日期 时间」再交出去，处理的结果就放在它旁边（同拖进来的文件）。

import AppKit
import UniformTypeIdentifiers

enum Paste {
  /// 菜单「粘贴」（⌘V）
  static func perform() {
    if NSApp.keyWindow?.firstResponder is NSText {
      NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
      return
    }
    let urls = files(from: .general)
    guard !urls.isEmpty else { return NSSound.beep() }
    Navigator.shared.give(urls)
  }

  /// 剪贴板里的文件；没有文件、只有图片数据时存成 folder 里的一个文件。什么都没有（或存不下）是空的
  static func files(from pasteboard: NSPasteboard, savingTo folder: URL = .downloadsDirectory)
    -> [URL]
  {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
      !urls.isEmpty
    {
      return urls
    }
    guard let (data, type) = imageData(in: pasteboard) else { return [] }
    let stamp = Date.now.formatted(
      .verbatim(
        "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
        timeZone: .current, calendar: .current))
    let ext = type.preferredFilenameExtension ?? "png"
    let target = folder.appending(path: "粘贴的图片 \(stamp).\(ext)").uniqued()
    do {
      try data.write(to: target, options: .withoutOverwriting)
    } catch {
      return []
    }
    return [target]
  }

  /// 剪贴板里的第一份图片数据（同 Kitty Tools 便签：先挑常见的有损 / 无损格式，再退到任何图片类型，比如截图的 TIFF）
  private static func imageData(in pasteboard: NSPasteboard) -> (Data, UTType)? {
    let types = pasteboard.types ?? []
    let preferred: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .webP]
    let candidates =
      preferred.map { NSPasteboard.PasteboardType($0.identifier) }.filter(types.contains)
      + types.filter { UTType($0.rawValue)?.conforms(to: .image) == true }
    for type in candidates {
      if let data = pasteboard.data(forType: type), !data.isEmpty, let uti = UTType(type.rawValue) {
        return (data, uti)
      }
    }
    return nil
  }
}
