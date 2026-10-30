// 结果放在原文件旁边时不覆盖已有的：重名就加「 2」「 3」……（同访达），加在扩展名前面。打包、解压、图片转换、去水印共用。

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
}
