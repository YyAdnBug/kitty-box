// 打包的忽略清单（PLAN §2「忽略清单」，B3–B6）。IgnoreRules 是匹配：按名字的通配符（* 和 ?），路径里任意一层都算，
// 以 / 结尾的只认文件夹，不分大小写（磁盘和 Windows 都不分）；纯函数，单测锁住。IgnoreList 是用户的清单：系统杂文件默认勾上、
// 开发目录默认不勾、自己加的，改了就记住（存在偏好里），打包页和以后的设置页都改它。解压跳过的杂文件（B7）也用这里的匹配。

import Foundation
import Observation

nonisolated struct IgnoreRules: Sendable {
  private struct Rule {
    var pattern: String
    var name: [Character]
    var directoriesOnly: Bool
  }

  /// 解压时不解出来的杂文件（B7）
  static let unpackJunk = IgnoreRules(["__MACOSX", "._*", ".DS_Store"])

  private let rules: [Rule]

  init(_ patterns: [String]) {
    rules = patterns.map { pattern in
      let directoriesOnly = pattern.hasSuffix("/")
      return Rule(
        pattern: pattern,
        name: Array(Self.folded(String(pattern.dropLast(directoriesOnly ? 1 : 0)))),
        directoriesOnly: directoriesOnly)
    }
  }

  /// 相对路径的哪一层被哪条规则命中，返回那条规则；isDirectory 说最后一层是不是文件夹
  func match(_ relativePath: String, isDirectory: Bool) -> String? {
    let parts = relativePath.split(separator: "/")
    for (index, part) in parts.enumerated() {
      let folder = index < parts.count - 1 || isDirectory
      let name = Array(Self.folded(String(part)))
      if let rule = rules.first(where: {
        (folder || !$0.directoriesOnly) && Self.wildcard($0.name, name)
      }) {
        return rule.pattern
      }
    }
    return nil
  }

  /// 加规则前的检查：有问题返回给人看的原因
  static func problem(with pattern: String, existing: [String]) -> String? {
    let name = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
    if name.trimmingCharacters(in: .whitespaces).isEmpty { return "规则不能是空的。" }
    if name.contains("/") { return "规则只认名字，不要带中间的 /，比如写「草稿/」而不是「网站/草稿」。" }
    if existing.contains(where: { folded($0) == folded(pattern) }) { return "「\(pattern)」已经在清单里了。" }
    return nil
  }

  /// * 配任意多个字符（不跨层），? 配一个
  static func wildcard(_ pattern: [Character], _ name: [Character]) -> Bool {
    var (p, n, star, mark) = (0, 0, -1, 0)
    while n < name.count {
      if p < pattern.count, pattern[p] == "?" || pattern[p] == name[n] {
        p += 1
        n += 1
      } else if p < pattern.count, pattern[p] == "*" {
        (star, mark) = (p, n)
        p += 1
      } else if star >= 0 {
        p = star + 1
        mark += 1
        n = mark
      } else {
        return false
      }
    }
    while p < pattern.count, pattern[p] == "*" { p += 1 }
    return p == pattern.count
  }

  /// 不分大小写；访达给的名字常是分解形式（NFD），手打的规则是合成形式，先统一
  private static func folded(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.lowercased()
  }
}

/// 用户的忽略清单（B3、B5）
@Observable final class IgnoreList {
  struct Item {
    var pattern: String
    var note: String
  }

  /// 系统杂文件：默认勾上
  static let system = [
    Item(pattern: ".DS_Store", note: "访达每个文件夹里的显示设置"),
    Item(pattern: "._*", note: "拷到非 Mac 格式的盘上时生成的附加信息"),
    Item(pattern: "__MACOSX", note: "访达打包时带的附加信息"),
    Item(pattern: ".Spotlight-V100", note: "聚焦的索引"),
    Item(pattern: ".Trashes", note: "外接盘的废纸篓"),
    Item(pattern: ".fseventsd", note: "文件系统的事件日志"),
    Item(pattern: ".TemporaryItems", note: "临时文件"),
    Item(pattern: "Icon\r", note: "文件夹的自定义图标"),
    Item(pattern: "Thumbs.db", note: "Windows 的缩略图缓存"),
    Item(pattern: "desktop.ini", note: "Windows 的文件夹设置"),
    Item(pattern: "$RECYCLE.BIN", note: "Windows 的回收站"),
  ]
  /// 开发目录：列着、默认不勾
  static let developer = [
    Item(pattern: ".git", note: "Git 仓库"),
    Item(pattern: ".svn", note: "SVN 仓库"),
    Item(pattern: "node_modules", note: "npm 依赖"),
    Item(pattern: ".venv", note: "Python 虚拟环境"),
    Item(pattern: "__pycache__", note: "Python 缓存"),
    Item(pattern: ".idea", note: "JetBrains 的工程设置"),
    Item(pattern: ".vscode", note: "VS Code 的工程设置"),
  ]

  /// 关掉的系统项和自己加的项
  private(set) var off: Set<String>
  /// 勾上的开发目录
  private(set) var developerOn: Set<String>
  /// 自己加的，按加的顺序
  private(set) var custom: [String]
  private let defaults: UserDefaults

  /// defaults：单测传临时偏好域，不碰用户的
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    off = Set(defaults.stringArray(forKey: Prefs.ignoreOff) ?? [])
    developerOn = Set(defaults.stringArray(forKey: Prefs.ignoreDeveloperOn) ?? [])
    custom = defaults.stringArray(forKey: Prefs.ignoreCustom) ?? []
  }

  var rules: IgnoreRules {
    IgnoreRules(
      (Self.system.map(\.pattern) + custom).filter { !off.contains($0) }
        + Self.developer.map(\.pattern).filter(developerOn.contains))
  }

  func isOn(_ pattern: String) -> Bool {
    Self.developer.contains { $0.pattern == pattern }
      ? developerOn.contains(pattern) : !off.contains(pattern)
  }

  func set(_ pattern: String, on: Bool) {
    if Self.developer.contains(where: { $0.pattern == pattern }) {
      if on { developerOn.insert(pattern) } else { developerOn.remove(pattern) }
    } else {
      if on { off.remove(pattern) } else { off.insert(pattern) }
    }
    save()
  }

  /// 有问题时不加，返回原因
  func add(_ pattern: String) -> String? {
    let pattern = pattern.trimmingCharacters(in: .whitespaces)
    let existing = Self.system.map(\.pattern) + Self.developer.map(\.pattern) + custom
    if let problem = IgnoreRules.problem(with: pattern, existing: existing) { return problem }
    custom.append(pattern)
    save()
    return nil
  }

  func remove(_ pattern: String) {
    custom.removeAll { $0 == pattern }
    off.remove(pattern)
    save()
  }

  private func save() {
    defaults.set(off.sorted(), forKey: Prefs.ignoreOff)
    defaults.set(developerOn.sorted(), forKey: Prefs.ignoreDeveloperOn)
    defaults.set(custom, forKey: Prefs.ignoreCustom)
  }
}
