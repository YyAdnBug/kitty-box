// 结果放在原文件旁边时不覆盖已有的：重名就加「 2」「 3」……（同访达），加在扩展名前面。打包、解压、图片转换、去水印共用；
// 几路一起写的（图片转换、去背景、AI 水印）用 reserved()：挑名字和占住是一步，两路不会挑中同一个。
// 去水印的结果另外在名字后面加「-去水印」（D7）。

import Foundation

extension URL {
  nonisolated func uniqued() -> URL {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: path) else { return self }
    let folder = deletingLastPathComponent()
    let ext = pathExtension
    let stem = deletingPathExtension().lastPathComponent
    for number in 2... {
      let candidate = folder.appending(path: "\(stem) \(number)" + (ext.isEmpty ? "" : "." + ext))
      if !fileManager.fileExists(atPath: candidate.path) { return candidate }
    }
    return self
  }

  /// 同 uniqued()，但挑中就马上占住（建一个空文件，独占地建：别人已经占了就换下一个号）。几路一起写图时用它：
  /// ImageIO 到 Finalize 才建文件、还会盖掉已有的，只查「在不在」的话两路会挑中同一个名字、后写的盖掉先写的。
  /// 写的人直接写进这个文件；没写成要自己删掉。文件夹不能写时抛系统的错（「没有权限存储…」），不往下数号
  nonisolated func reserved() throws -> URL {
    let folder = deletingLastPathComponent()
    let ext = pathExtension
    let stem = deletingPathExtension().lastPathComponent
    for number in 1... {
      let candidate =
        number == 1
        ? self : folder.appending(path: "\(stem) \(number)" + (ext.isEmpty ? "" : "." + ext))
      do {
        try Data().write(to: candidate, options: .withoutOverwriting)
        return candidate
      } catch CocoaError.fileWriteFileExists {
        continue
      }
    }
    return self
  }

  /// 同一个文件夹里、名字后面加一段：「图.png」加「-去水印」是「图-去水印.png」
  nonisolated func adding(_ suffix: String) -> URL {
    let ext = pathExtension
    return deletingLastPathComponent().appending(
      path: deletingPathExtension().lastPathComponent + suffix + (ext.isEmpty ? "" : "." + ext))
  }
}
