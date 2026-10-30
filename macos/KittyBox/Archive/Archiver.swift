// 打包和解压（PLAN §2）。解压：zip 和 tar 一族交给系统 tar（zip 先用 ZipNames 判断文件名编码），其余（7z、RAR、iso…）交给随包的 7zz。
// 打包只用 7zz：先按忽略清单自己列出要打的文件（plan），清单交给 7zz（`@清单`），看到的就是打进去的。
// 结果都放在原文件旁边，不碰原文件；解压先解到旁边一个隐藏的临时文件夹，做完再挪成正式的名字，失败时不留半截东西。
// 等子进程的时候不占主线程（Subprocess 在进程外跑）；遍历文件夹、解完后的清理是 @concurrent。

import Foundation

enum Archiver {
  nonisolated enum Format: String, CaseIterable {
    case zip
    case sevenZip = "7z"
  }

  nonisolated struct PackOptions {
    var format = Format.zip
    /// 空 = 不设密码
    var password = ""
    /// zip 设了密码时用 ZipCrypto，Windows 自带解压也能开，但容易被破解（B10）；默认 AES-256
    var windowsCompatible = false
  }

  nonisolated struct PackPlan: Sendable {
    /// 选中的东西所在的文件夹；清单里的路径都相对它，包也放在这里
    var base: URL
    var items: [URL]
    /// 要打进去的：文件、链接，和本来就空的文件夹
    var files: [String]
    /// 被规则排掉的（文件夹算一项，里面的不再往下看）
    var ignored: [(path: String, rule: String)]
    var windowsProblems: [(path: String, reason: String)]
  }

  nonisolated enum Failure: LocalizedError, Equatable {
    case needsPassword
    case wrongPassword
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .needsPassword: "这个包有密码。"
      case .wrongPassword: "密码不对。"
      case .failed(let reason): reason
      }
    }
  }

  // MARK: 打包

  /// 列出要打进去的文件（B6）：在后台遍历，被规则命中的文件夹不再往下看
  @concurrent nonisolated static func plan(_ items: [URL], rules: IgnoreRules) async -> PackPlan {
    let fileManager = FileManager.default
    var files: [String] = []
    var folders: [String] = []
    var ignored: [(path: String, rule: String)] = []
    var nonEmpty: Set<String> = []
    for item in items {
      let top = item.lastPathComponent
      let isFolder = isDirectory(try? fileManager.attributesOfItem(atPath: item.path))
      if let rule = rules.match(top, isDirectory: isFolder) {
        ignored.append((top, rule))
        continue
      }
      guard isFolder, let walker = fileManager.enumerator(atPath: item.path) else {
        files.append(top)
        continue
      }
      folders.append(top)
      while let sub = walker.nextObject() as? String {
        let path = top + "/" + sub
        nonEmpty.insert(String(path[..<path.lastIndex(of: "/")!]))
        let isFolder = isDirectory(walker.fileAttributes)
        if let rule = rules.match(path, isDirectory: isFolder) {
          ignored.append((path, rule))
          if isFolder { walker.skipDescendants() }
        } else if isFolder {
          folders.append(path)
        } else {
          files.append(path)
        }
      }
    }
    // 里面有东西要打的文件夹跟着文件进去；本来就空的文件夹单独列上，解开时还在。清单里写文件夹的话 7zz 会把它整个
    // 递归打进去（-r- 也拦不住，实测），连被忽略的一起，所以里面只剩被忽略的东西的文件夹不列：它在包里就没了
    var filled: Set<String> = []
    for file in files {
      var path = Substring(file)
      while let slash = path.lastIndex(of: "/") {
        path = path[..<slash]
        if !filled.insert(String(path)).inserted { break }
      }
    }
    files += folders.filter { !filled.contains($0) && !nonEmpty.contains($0) }
    return PackPlan(
      base: items[0].deletingLastPathComponent(), items: items, files: files, ignored: ignored,
      windowsProblems: WindowsNames.problems(in: files))
  }

  /// 打好的包放在 plan.base 里，重名加「 2」
  static func pack(_ plan: PackPlan, options: PackOptions) async throws -> URL {
    if let problem = passwordProblem(options) { throw Failure.failed(problem) }
    let archive = plan.base.appending(path: archiveName(for: plan.items, format: options.format))
      .uniqued()
    let list = FileManager.default.temporaryDirectory.appending(path: "kittybox-\(UUID()).txt")
    // ponytail: 名字里带换行的文件会把清单拆坏；真遇到再换成一个一个传
    try plan.files.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: list) }
    var arguments = [
      "a", "-t\(options.format == .zip ? "zip" : "7z")", "-snl", "-scsUTF-8", "-bso0", "-bsp0",
      archive.path, "@" + list.path,
    ]
    if !options.password.isEmpty {
      arguments.append("-p" + options.password)
      arguments.append(
        options.format == .sevenZip
          ? "-mhe=on" : "-mem=" + (options.windowsCompatible ? "ZipCrypto" : "AES256"))
    }
    let result = try await Subprocess.run(
      sevenZip, arguments, captures: true, quality: .userInitiated, directory: plan.base)
    guard result.status == 0 else {
      try? FileManager.default.removeItem(at: archive)
      throw Failure.failed("打包没成功：" + summary(of: result))
    }
    return archive
  }

  // MARK: 解压

  /// 解到压缩包旁边：包里只有一样东西时直接放出来，不然放进和包同名的文件夹（B8）。重名加「 2」
  static func unpack(_ archive: URL, password: String = "") async throws -> URL {
    let parent = archive.deletingLastPathComponent()
    let name = folderName(for: archive)
    let work = parent.appending(path: ".\(name) 解压中").uniqued()
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
    do {
      // 没给密码也要传一个：不传的话 tar 会对着空的标准输入连问上万次，7zz 会卡在问密码；不加密的包会忽略它
      let given = password.isEmpty ? "kitty-box-no-password" : password
      let result: Subprocess.Result
      let wrongPassword: Bool
      if usesTar(archive) {
        var arguments = ["-xf", archive.path, "-C", work.path, "--passphrase", given]
        if ZipNames.isZip(archive) {
          let charset = ZipNames.charset(of: archive) ?? .utf8
          arguments += ["--options", "hdrcharset=" + charset.rawValue]
        }
        result = try await Subprocess.run(tar, arguments, captures: true, quality: .userInitiated)
        wrongPassword = result.error.contains("Incorrect passphrase")
      } else {
        result = try await Subprocess.run(
          sevenZip, ["x", "-y", "-bso0", "-bsp0", "-o" + work.path, "-p" + given, archive.path],
          captures: true, quality: .userInitiated)
        wrongPassword = (result.output + result.error).contains("Wrong password")
      }
      if result.status != 0 {
        if wrongPassword { throw password.isEmpty ? Failure.needsPassword : Failure.wrongPassword }
        throw Failure.failed("解压没成功：" + summary(of: result))
      }
      return try await settle(work, from: archive, name: name)
    } catch {
      try? FileManager.default.removeItem(at: work)
      throw error
    }
  }

  /// 解完之后：去掉杂文件（B7）；包带着「从网上下载」的隔离标记时，解出来的每样东西都带上（同系统的归档实用工具，
  /// 不然包里的 App 打开时不会再被检查）；再挪成正式的名字
  @concurrent nonisolated private static func settle(_ work: URL, from archive: URL, name: String)
    async throws -> URL
  {
    let fileManager = FileManager.default
    let quarantine = try? archive.resourceValues(forKeys: [.quarantinePropertiesKey])
      .quarantineProperties
    var junk: [URL] = []
    if let walker = fileManager.enumerator(atPath: work.path) {
      while let path = walker.nextObject() as? String {
        let isFolder = isDirectory(walker.fileAttributes)
        if IgnoreRules.unpackJunk.match(path, isDirectory: isFolder) != nil {
          junk.append(work.appending(path: path))
          if isFolder { walker.skipDescendants() }
        } else if let quarantine,
          walker.fileAttributes?[.type] as? FileAttributeType != .typeSymbolicLink
        {
          var url = work.appending(path: path)
          var values = URLResourceValues()
          values.quarantineProperties = quarantine
          try? url.setResourceValues(values)
        }
      }
    }
    for url in junk { try? fileManager.removeItem(at: url) }

    let parent = work.deletingLastPathComponent()
    let children = try fileManager.contentsOfDirectory(atPath: work.path)
    if children.count == 1 {
      let target = parent.appending(path: children[0]).uniqued()
      try fileManager.moveItem(at: work.appending(path: children[0]), to: target)
      try fileManager.removeItem(at: work)
      return target
    }
    let target = parent.appending(path: name).uniqued()
    try fileManager.moveItem(at: work, to: target)
    return target
  }

  // MARK: 名字和判断（纯函数）

  /// 7zz 打 zip 时不收中文这类非 ASCII 的密码（报 E_INVALIDARG，2026-10-30 实测），7z 没这个限制
  nonisolated static func passwordProblem(_ options: PackOptions) -> String? {
    guard options.format == .zip, !options.password.allSatisfy({ $0.isASCII && !$0.isNewline })
    else { return nil }
    return "zip 的密码只能用英文字母、数字和符号；要用中文密码请选 7z。"
  }

  /// 拖进来的东西里哪些当压缩包（按扩展名；分卷 .001、.part1.rar 也算）
  nonisolated static func isArchive(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return archiveExtensions.contains(ext) || (ext.count == 3 && ext.allSatisfy(\.isNumber))
  }

  /// zip（看文件头）和 tar 一族交给系统 tar：7zz 解 .tar.gz 只解出一层 .tar，解 GBK 名字的 zip 会坏
  nonisolated static func usesTar(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return ZipNames.isZip(url) || tarSuffixes.contains { name.hasSuffix($0) }
  }

  /// 解出来的文件夹叫什么：去掉扩展名，连带 .tar、分卷号（.001）、.part1
  nonisolated static func folderName(for archive: URL) -> String {
    var name = archive.lastPathComponent
    if let suffix = tarSuffixes.first(where: { name.lowercased().hasSuffix($0) }), suffix.count > 4
    {
      name = String(name.dropLast(suffix.count))
      return name.isEmpty ? archive.lastPathComponent : name
    }
    let ext = (name as NSString).pathExtension
    if ext.count == 3, ext.allSatisfy(\.isNumber) {
      name = (name as NSString).deletingPathExtension
    }
    name = (name as NSString).deletingPathExtension
    if let part = name.range(of: #"\.part\d+$"#, options: [.regularExpression, .caseInsensitive]) {
      name.removeSubrange(part)
    }
    return name.isEmpty ? archive.lastPathComponent : name
  }

  /// 打出来的包叫什么：一样东西就用它的名字，几样就叫「归档」（同访达）
  nonisolated static func archiveName(for items: [URL], format: Format) -> String {
    (items.count == 1 ? items[0].lastPathComponent : "归档") + "." + format.rawValue
  }

  // MARK: 其余

  private static var sevenZip: String {
    Bundle.main.url(forAuxiliaryExecutable: "7zz")?.path ?? "7zz"
  }
  private static let tar = "/usr/bin/tar"

  nonisolated private static let tarSuffixes = [
    ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz", ".tar.zst", ".tzst",
  ]
  nonisolated private static let archiveExtensions: Set<String> = [
    "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "lz",
    "lzma", "z", "cab", "iso", "arj", "lzh", "cpio", "xar", "wim",
  ]

  nonisolated private static func isDirectory(_ attributes: [FileAttributeKey: Any]?) -> Bool {
    attributes?[.type] as? FileAttributeType == .typeDirectory
  }

  /// 给人看的出错原因：工具最后一行有内容的输出
  private static func summary(of result: Subprocess.Result) -> String {
    let lines = (result.error + "\n" + result.output).split(whereSeparator: \.isNewline)
    let last = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return last.map { String($0.prefix(200)) } ?? "退出码 \(result.status)"
  }
}
