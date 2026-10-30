// Windows 不认的文件名（B11）：打包前列出来，改不改由用户，不拦着打包、不自动改名。
// 三种：带 \ : * ? " < > | 或控制字符；结尾是空格或点；CON、PRN、AUX、NUL、COM1–9、LPT1–9 这类保留名（带扩展名也算）。
// 访达里显示成 / 的那个字符，在磁盘上存的其实是 :。全角的「：」「？」没问题。

import Foundation

nonisolated enum WindowsNames {
  /// 一层名字的问题，没问题是 nil
  static func problem(with name: String) -> String? {
    if let bad = name.unicodeScalars.first(where: { "\\:*?\"<>|".unicodeScalars.contains($0) }) {
      return bad == ":" ? "带 :（访达里显示成 /）" : "带 \(bad)"
    }
    if name.unicodeScalars.contains(where: { $0.value < 0x20 }) { return "带控制字符" }
    if name.hasSuffix(" ") || name.hasSuffix(".") { return "结尾是空格或点" }
    let stem = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    if reserved.contains(stem.uppercased()) { return "是 Windows 的保留名" }
    return nil
  }

  /// 相对路径里有问题的那一层（同一个文件夹只报一次）
  static func problems(in relativePaths: [String]) -> [(path: String, reason: String)] {
    var seen: Set<String> = []
    var found: [(path: String, reason: String)] = []
    for path in relativePaths {
      var prefix = ""
      for part in path.split(separator: "/") {
        prefix += prefix.isEmpty ? String(part) : "/" + part
        guard let reason = problem(with: String(part)) else { continue }
        if seen.insert(prefix).inserted { found.append((prefix, reason)) }
        break
      }
    }
    return found
  }

  private static let reserved: Set<String> = Set(
    ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
}
