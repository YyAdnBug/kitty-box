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

  /// 压缩级别（M5）：7zz 的 -mx0 / 1 / 5 / 9
  nonisolated enum Level: String, CaseIterable {
    case store, fast, normal, smallest

    var title: String {
      switch self {
      case .store: "存储"
      case .fast: "快"
      case .normal: "标准"
      case .smallest: "最小"
      }
    }

    var flag: String {
      switch self {
      case .store: "-mx0"
      case .fast: "-mx1"
      case .normal: "-mx5"
      case .smallest: "-mx9"
      }
    }
  }

  nonisolated struct PackOptions {
    var format = Format.zip
    /// 空 = 不设密码
    var password = ""
    /// zip 设了密码时用 ZipCrypto，Windows 自带解压也能开，但容易被破解（B10）；默认 AES-256
    var windowsCompatible = false
    var level = Level.normal
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

  /// 打好的包放在 plan.base 里，重名加「 2」。progress 报 0–1（7zz 的 -bsp1 百分比）；任务被取消时停掉 7zz、删掉打了一半的包，
  /// 抛 CancellationError
  static func pack(
    _ plan: PackPlan, options: PackOptions, progress: @escaping (Double) -> Void = { _ in }
  ) async throws -> URL {
    if let problem = passwordProblem(options) { throw Failure.failed(problem) }
    let archive = plan.base.appending(path: archiveName(for: plan.items, format: options.format))
      .uniqued()
    let list = FileManager.default.temporaryDirectory.appending(path: "kittybox-\(UUID()).txt")
    // ponytail: 名字里带换行的文件会把清单拆坏；真遇到再换成一个一个传
    try plan.files.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: list) }
    var arguments = [
      "a", "-t\(options.format == .zip ? "zip" : "7z")", "-snl", "-scsUTF-8", "-bso0", "-bsp1",
      options.level.flag, archive.path, "@" + list.path,
    ]
    if !options.password.isEmpty {
      arguments.append("-p" + options.password)
      arguments.append(
        options.format == .sevenZip
          ? "-mhe=on" : "-mem=" + (options.windowsCompatible ? "ZipCrypto" : "AES256"))
    }
    let result = try await Subprocess.run(
      sevenZip, arguments, captures: true, quality: .userInitiated, directory: plan.base,
      watch: { if let percent = lastPercent(in: $0) { progress(percent) } })
    guard result.status == 0, !Task.isCancelled else {
      try? FileManager.default.removeItem(at: archive)
      try Task.checkCancellation()
      throw Failure.failed("打包没成功：" + summary(of: result))
    }
    return archive
  }

  // MARK: 解压

  /// 解到压缩包旁边：包里只有一样东西时直接放出来，不然放进和包同名的文件夹（B8）。重名加「 2」。
  /// progress 报 0–1：7zz 的 -bsp1 百分比；zip 按 tar -v 解出来的条数 / 中央目录里的条数；别的 tar 一族不知道总数、不报。
  /// 任务被取消时停掉子进程、删掉解了一半的文件夹，抛 CancellationError
  static func unpack(
    _ archive: URL, password: String = "", progress: @escaping (Double) -> Void = { _ in }
  ) async throws -> URL {
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
        var arguments = ["-xvf", archive.path, "-C", work.path, "--passphrase", given]
        let entries = ZipNames.isZip(archive) ? ZipNames.entries(of: archive) : nil
        if let entries {
          arguments += ["--options", "hdrcharset=" + ZipNames.charset(for: entries).rawValue]
        }
        // tar -v 每解出一条在标准错误写一行
        var done = 0
        let total = entries?.count ?? 0
        result = try await Subprocess.run(
          tar, arguments, captures: true, quality: .userInitiated,
          watch: { text in
            done += text.count { $0 == "\n" }
            if total > 0 { progress(min(Double(done) / Double(total), 1)) }
          })
        // ZipCrypto 的密码只校验一个字节：错的密码有 1/256 混过校验，解到一半才因为数据对不上失败，报的不是「密码不对」。
        // 加了密的 zip 解不成就当密码不对（ponytail: 真坏了的加密包也会这么说）
        wrongPassword =
          result.error.contains("Incorrect passphrase")
          || entries?.contains(where: \.encrypted) == true
      } else {
        result = try await Subprocess.run(
          sevenZip, ["x", "-y", "-bso0", "-bsp1", "-o" + work.path, "-p" + given, archive.path],
          captures: true, quality: .userInitiated,
          watch: { if let percent = lastPercent(in: $0) { progress(percent) } })
        wrongPassword = (result.output + result.error).contains("Wrong password")
      }
      try Task.checkCancellation()
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

  /// 包里的一个文件（「看看里面」，M6）；大小不知道（tar 一族、ZIP64 的大条目）时是 nil
  nonisolated struct Entry: Identifiable, Sendable {
    let path: String
    let size: Int64?
    var id: String { path }
  }

  /// 包里有什么：只列文件（文件夹不算一项），去掉解压时会跳过的杂文件（B7）。zip 读中央目录（GBK 名字也读对），
  /// tar 一族用 tar -tf（没有大小），别的用 7zz l -slt；连文件名都加了密的 7z 没给对密码时抛 needsPassword / wrongPassword
  static func contents(of archive: URL, password: String = "") async throws -> [Entry] {
    let entries: [Entry]
    if ZipNames.isZip(archive) {
      guard let raw = ZipNames.entries(of: archive) else { throw Failure.failed("读不出这个 zip。") }
      let charset = ZipNames.charset(for: raw)
      entries = raw.map {
        Entry(path: ZipNames.name(of: $0, charset: charset), size: $0.size.map(Int64.init))
      }
    } else if usesTar(archive) {
      let result = try await Subprocess.run(tar, ["-tf", archive.path], captures: true)
      guard result.status == 0 else { throw Failure.failed("读不出这个包：" + summary(of: result)) }
      entries = result.output.split(separator: "\n").map { Entry(path: String($0), size: nil) }
    } else {
      let given = password.isEmpty ? "kitty-box-no-password" : password
      let result = try await Subprocess.run(
        sevenZip, ["l", "-ba", "-slt", "-sccUTF-8", "-p" + given, archive.path], captures: true)
      if (result.output + result.error).contains("Wrong password") {
        throw password.isEmpty ? Failure.needsPassword : Failure.wrongPassword
      }
      guard result.status == 0 else { throw Failure.failed("读不出这个包：" + summary(of: result)) }
      entries = listed(result.output)
    }
    return entries.filter {
      !$0.path.hasSuffix("/") && IgnoreRules.unpackJunk.match($0.path, isDirectory: false) == nil
    }
  }

  /// 7zz l -slt 的输出：空行隔开的一段段「键 = 值」；Attributes 以 D 开头或 Folder = + 的是文件夹，不要
  nonisolated static func listed(_ output: String) -> [Entry] {
    output.components(separatedBy: "\n\n").compactMap { block in
      var fields: [String: String] = [:]
      for line in block.split(separator: "\n") {
        guard let range = line.range(of: " = ") else { continue }
        fields[String(line[..<range.lowerBound])] = String(line[range.upperBound...])
      }
      guard let path = fields["Path"], !path.isEmpty, fields["Folder"] != "+",
        fields["Attributes"]?.hasPrefix("D") != true
      else { return nil }
      return Entry(path: path, size: fields["Size"].flatMap { Int64($0) })
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

  /// 分卷包（.001、.part1.rar）：解完不挪到废纸篓（别的卷还在，只挪一个反而乱）
  nonisolated static func isMultiVolume(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    let ext = url.pathExtension
    return (ext.count == 3 && ext.allSatisfy(\.isNumber))
      || name.range(of: #"\.part\d+\.rar$"#, options: .regularExpression) != nil
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

  /// 7zz -bsp1 的进度：「 32% 6 + 名字」这样的片段用退格隔开，取最后一个百分数
  nonisolated static func lastPercent(in text: String) -> Double? {
    text.matches(of: /(\d{1,3})%/).last.flatMap { Double($0.output.1) }.map { min($0 / 100, 1) }
  }

  /// 给人看的出错原因：工具最后一行有内容的输出
  private static func summary(of result: Subprocess.Result) -> String {
    let lines = (result.error + "\n" + result.output).split(whereSeparator: \.isNewline)
    let last = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return last.map { String($0.prefix(200)) } ?? "退出码 \(result.status)"
  }
}
