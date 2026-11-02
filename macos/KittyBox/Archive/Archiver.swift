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
    /// 包放在这里：第一样东西所在的文件夹
    var base: URL
    var items: [URL]
    /// 要打进去的（文件、链接，和本来就空的文件夹），按所在的文件夹分组：路径相对那个文件夹，7zz 在那里跑一次，
    /// 都加进同一个包（选中的东西可以来自不同的文件夹，同访达「压缩」，在包里都在最上层）
    var groups: [(base: URL, files: [String])]
    /// 各组的合在一起（数个数、列 Windows 不认的名字）
    var files: [String]
    /// 被规则排掉的（文件夹算一项，里面的不再往下看）
    var ignored: [(path: String, rule: String)]
    var windowsProblems: [(path: String, reason: String)]
    /// 不同文件夹里同名的几样东西：包里只放得下一个（7zz 后加的会悄悄顶掉先加的，实测），不让打
    var clashes: [String]
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

  /// 列出要打进去的文件（B6）：在后台遍历，被规则命中的文件夹不再往下看；选中的东西或规则变了（任务被取消）就不往下列了
  @concurrent nonisolated static func plan(_ picked: [URL], rules: IgnoreRules) async -> PackPlan {
    // 同一样东西加了两次（带不带结尾的 /）、已经在另一个选中的文件夹里面的，不再单列
    var unique: [URL] = []
    for url in picked where !unique.contains(where: { $0.path == url.path }) { unique.append(url) }
    let items = unique.filter { item in !unique.contains { item.path.hasPrefix($0.path + "/") } }
    let fileManager = FileManager.default
    var files: [String] = []
    var folders: [String] = []
    var ignored: [(path: String, rule: String)] = []
    var nonEmpty: Set<String> = []
    /// 顶层名字 → 它所在的文件夹（分组用）
    var parents: [String: URL] = [:]
    var clashes: [String] = []
    for item in items {
      let top = item.lastPathComponent
      // 不分大小写、统一合成形式：解到 Mac 上时这两个会撞名
      let key = top.precomposedStringWithCanonicalMapping.lowercased()
      if parents.updateValue(item.deletingLastPathComponent(), forKey: key) != nil {
        clashes.append(top)
      }
      let isFolder = isDirectory(try? fileManager.attributesOfItem(atPath: item.path))
      if let rule = rules.match(top, isDirectory: isFolder) {
        ignored.append((top, rule))
        continue
      }
      guard isFolder,
        let walker = fileManager.enumerator(
          at: item, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      else {
        files.append(top)
        continue
      }
      folders.append(top)
      // 按层记名字拼相对路径（不从 url.path 里截：/var 和 /private/var 对不上）
      var names = [top]
      while let url = walker.nextObject() as? URL, !Task.isCancelled {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
        names.removeLast(names.count - walker.level)
        nonEmpty.insert(names.joined(separator: "/"))
        names.append(url.lastPathComponent)
        let path = names.joined(separator: "/")
        // 上面各层进来时已经比过（命中的整个跳过了），只比最后一层
        if let rule = rules.match(url.lastPathComponent, isDirectory: isFolder) {
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
    var groups: [(base: URL, files: [String])] = []
    for file in files {
      let top = file.prefix { $0 != "/" }.precomposedStringWithCanonicalMapping.lowercased()
      let parent = parents[top] ?? items[0].deletingLastPathComponent()
      if let index = groups.firstIndex(where: { $0.base.path == parent.path }) {
        groups[index].files.append(file)
      } else {
        groups.append((parent, [file]))
      }
    }
    return PackPlan(
      base: items[0].deletingLastPathComponent(), items: items, groups: groups, files: files,
      ignored: ignored, windowsProblems: WindowsNames.problems(in: files), clashes: clashes)
  }

  /// 打好的包默认放在 plan.base 里，重名加「 2」；target 是「打包到…」选的位置（那里已有的包先挪到废纸篓，
  /// 不然 7zz 会把新的并进旧包）。progress 报 0–1（7zz 的 -bsp1 百分比）；任务被取消时停掉 7zz、删掉打了一半的包，
  /// 抛 CancellationError
  static func pack(
    _ plan: PackPlan, options: PackOptions, to target: URL? = nil,
    progress: @escaping (Double) -> Void = { _ in }
  ) async throws -> URL {
    if let name = plan.clashes.first {
      throw Failure.failed("「\(name)」有不止一个（在不同的文件夹里），包里只放得下一个，先移除一个。")
    }
    if let problem = passwordProblem(options) { throw Failure.failed(problem) }
    // 「打包到…」选了要打进去的那样东西（或选中的文件夹里、要打进去的旧包）、点了替换：下面会把它挪进废纸篓，
    // 7zz 再说找不到文件，重试还是一样
    if let target {
      let packed =
        plan.items
        + plan.groups.flatMap { group in group.files.map { group.base.appending(path: $0) } }
      let path = target.standardizedFileURL.path
      if packed.contains(where: { $0.standardizedFileURL.path == path }) {
        throw Failure.failed("「\(target.lastPathComponent)」也在要打进去的东西里，换个名字或位置存包。")
      }
    }
    let archive =
      target
      ?? plan.base.appending(path: archiveName(for: plan.items, format: options.format)).uniqued()
    if target != nil, FileManager.default.fileExists(atPath: archive.path) {
      try FileManager.default.trashItem(at: archive, resultingItemURL: nil)
    }
    let list = FileManager.default.temporaryDirectory.appending(path: "kittybox-\(UUID()).txt")
    defer { try? FileManager.default.removeItem(at: list) }
    var arguments = [
      // -spd：名字里的 * ? [ 不当通配符（不然「Why?.txt」会把旁边的「Why1.txt」也打进去，实测）
      "a", "-t\(options.format == .zip ? "zip" : "7z")", "-snl", "-spd", "-scsUTF-8", "-bso0",
      "-bsp1", options.level.flag, archive.path, "@" + list.path,
    ]
    if !options.password.isEmpty {
      arguments.append("-p" + options.password)
      arguments.append(
        options.format == .sevenZip
          ? "-mhe=on" : "-mem=" + (options.windowsCompatible ? "ZipCrypto" : "AES256"))
    }
    // 清单一行一个名字；带换行的（Icon␍ 的 \r 也算）会被拆开、两头的空格会被去掉、两头都是引号的会被去掉引号
    // （「"q"」变成旁边的「q」，实测），这些放在 -- 后面的命令行上。
    // ponytail: 这种名字成千上万时会超过命令行长度上限（约 1 MB），真遇到再分批
    let fits = { (name: String) in
      !name.contains(where: \.isNewline) && name.first?.isWhitespace == false
        && name.last?.isWhitespace == false && !(name.hasPrefix("\"") && name.hasSuffix("\""))
    }
    do {
      for (index, group) in plan.groups.enumerated() {
        try group.files.filter(fits).joined(separator: "\n")
          .write(to: list, atomically: true, encoding: .utf8)
        let result = try await Subprocess.run(
          sevenZip, arguments + ["--"] + group.files.filter { !fits($0) }, captures: true,
          quality: .userInitiated, directory: group.base,
          watch: { text in
            if let percent = lastPercent(in: text) {
              progress((Double(index) + percent) / Double(plan.groups.count))
            }
          })
        try Task.checkCancellation()
        guard result.status == 0 else { throw Failure.failed("打包没成功：" + summary(of: result)) }
      }
    } catch {
      // 前几组已经加进去了也删掉：打了一半的包不留在正式的名字下
      try? FileManager.default.removeItem(at: archive)
      throw error
    }
    return archive
  }

  // MARK: 解压

  /// 解到压缩包旁边（folder 是「解到…」选的文件夹）：包里只有一样东西时直接放出来，不然放进和包同名的文件夹（B8）。重名加「 2」。
  /// progress 报 0–1：7zz 的 -bsp1 百分比；zip 按 tar -v 解出来的条数 / 中央目录里的条数；别的 tar 一族不知道总数、不报。
  /// 任务被取消时停掉子进程、删掉解了一半的文件夹，抛 CancellationError
  static func unpack(
    _ archive: URL, into folder: URL? = nil, password: String = "",
    progress: @escaping (Double) -> Void = { _ in }
  ) async throws -> URL {
    let parent = folder ?? archive.deletingLastPathComponent()
    let name = folderName(for: archive)
    let work = parent.appending(path: ".\(name) 解压中").uniqued()
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
    do {
      // 没给密码也要传一个：不传的话 tar 会对着空的标准输入连问上万次，7zz 会卡在问密码；不加密的包会忽略它。
      // 不走标准输入：tar 从那里读到错的密码会再问上万次、十几秒才放弃，还不报「Incorrect passphrase」（2026-11 实测）
      let given = password.isEmpty ? "kitty-box-no-password" : password
      let result: Subprocess.Result
      let wrongPassword: Bool
      if usesTar(archive) {
        var arguments = ["-xvf", archive.path, "-C", work.path, "--passphrase", given]
        let entries = await zipEntries(archive)
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
        // -spd：包的名字里的 ? * 不当通配符（不然解「Why?.7z」会把旁边的「Why1.7z」也解出来，实测）。
        // 在临时文件夹里跑、不用 -o：-o 里的 * 会被换成包名（「a*b.7z」解到了旁边的「.aa*bb 解压中」，实测）
        result = try await Subprocess.run(
          sevenZip, ["x", "-y", "-spd", "-bso0", "-bsp1", "-p" + given, "--", archive.path],
          captures: true, quality: .userInitiated, directory: work,
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
      // 几万个文件要删一两秒，放到后台，不卡窗口
      await discard(work)
      throw error
    }
  }

  @concurrent nonisolated private static func discard(_ url: URL) async {
    try? FileManager.default.removeItem(at: url)
  }

  /// zip 的中央目录（十万条要读、判断一阵子，放到后台）；不是 zip 或读不出时是 nil
  @concurrent nonisolated private static func zipEntries(_ archive: URL) async -> [ZipNames.Entry]?
  {
    ZipNames.isZip(archive) ? ZipNames.entries(of: archive) : nil
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
    if ZipNames.isZip(archive) {
      guard let entries = await zipContents(archive) else { throw Failure.failed("读不出这个 zip。") }
      return entries
    }
    let tarFamily = usesTar(archive)
    let result: Subprocess.Result
    if tarFamily {
      // 从访达打开的 App 没有 UTF-8 的 locale，tar 列出来的中文名会变成「\344\273\243」这样的转义（2026-11 实测）
      result = try await Subprocess.run(
        tar, ["-tf", archive.path], captures: true, environment: ["LC_ALL": "en_US.UTF-8"])
    } else {
      let given = password.isEmpty ? "kitty-box-no-password" : password
      result = try await Subprocess.run(
        sevenZip, ["l", "-ba", "-slt", "-spd", "-sccUTF-8", "-p" + given, "--", archive.path],
        captures: true)
      if (result.output + result.error).contains("Wrong password") {
        throw password.isEmpty ? Failure.needsPassword : Failure.wrongPassword
      }
    }
    guard result.status == 0 else { throw Failure.failed("读不出这个包：" + summary(of: result)) }
    return await parsed(result.output, tarFamily: tarFamily)
  }

  /// 十万条的包要拆、筛一两秒，放到后台（同 plan、settle）
  @concurrent nonisolated private static func zipContents(_ archive: URL) async -> [Entry]? {
    guard let raw = ZipNames.entries(of: archive) else { return nil }
    let charset = ZipNames.charset(for: raw)
    return withoutJunk(
      raw.map {
        Entry(path: ZipNames.name(of: $0, charset: charset), size: $0.size.map(Int64.init))
      })
  }

  @concurrent nonisolated private static func parsed(_ output: String, tarFamily: Bool) async
    -> [Entry]
  {
    withoutJunk(
      tarFamily
        ? output.split(separator: "\n").map { Entry(path: String($0), size: nil) }
        : listed(output))
  }

  nonisolated private static func withoutJunk(_ entries: [Entry]) -> [Entry] {
    entries.filter {
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
    // 只有一个隐藏的（.git、.zshrc）或链接时照样放进文件夹：放出来访达里看不见，还会悄悄落在包旁边起作用
    if children.count == 1, !children[0].hasPrefix("."),
      (try? fileManager.destinationOfSymbolicLink(atPath: work.appending(path: children[0]).path))
        == nil
    {
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

  /// 分卷包（.001、.part1.rar，旁边有 .z01 的 zip、有 .r00 的 rar）：解完不挪到废纸篓（别的卷还在，只挪一个反而乱）
  nonisolated static func isMultiVolume(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    let ext = url.pathExtension
    let stem = url.deletingPathExtension().path
    return (ext.count == 3 && ext.allSatisfy(\.isNumber))
      || name.range(of: #"\.part\d+\.rar$"#, options: .regularExpression) != nil
      || ["z01", "r00"].contains { FileManager.default.fileExists(atPath: stem + "." + $0) }
  }

  /// 分卷包的第 2 卷起（.002、.part2.rar）换成第一卷：7zz 从第一卷读整套，单独解后面的只会失败。
  /// 一整套拖进来就只解一次；第一卷不在旁边时原样留着（解的时候说清楚）
  nonisolated static func firstVolume(of url: URL) -> URL {
    let name = url.lastPathComponent
    let first: String
    if let match = name.firstMatch(of: /^(.+\.)(\d{3})$/), Int(match.2) ?? 0 > 1 {
      first = match.1 + "001"
    } else if let match = name.firstMatch(of: /^(.+\.part)(\d+)(\.rar)$/.ignoresCase()),
      Int(match.2) ?? 0 > 1
    {
      first = match.1 + String(repeating: "0", count: match.2.count - 1) + "1" + match.3
    } else {
      return url
    }
    let candidate = url.deletingLastPathComponent().appending(path: first)
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : url
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

  /// 给人看的出错原因：认得的说成中文；不然是标准错误里最后一行有用的。只看标准错误：7zz 的进度在标准输出、满是退格，
  /// tar 最后那句「Error exit delayed」不说原因，tar -v 解出一条写一行「x 名字」（出错的那条后面才跟「: 原因」，
  /// 坏的是第一条时最后一行是后面好好的那条，实测）
  private static func summary(of result: Subprocess.Result) -> String {
    let lines = result.error.split(whereSeparator: \.isNewline).map {
      String(String.UnicodeScalarView($0.unicodeScalars.filter { $0.value >= 0x20 }))
        .trimmingCharacters(in: .whitespaces)
    }
    .filter {
      !$0.isEmpty && !$0.contains("Error exit delayed")
        && !($0.hasPrefix("x ") && !$0.contains(": "))
    }
    let known = [
      ("CRC Failed", "压缩包坏了（校验对不上），可能没下载完整。"),
      ("bad CRC", "压缩包坏了（校验对不上），可能没下载完整。"),
      ("Data Error", "压缩包坏了，可能没下载完整。"),
      ("decompression failed", "压缩包坏了，可能没下载完整。"),
      ("Damaged", "压缩包坏了，可能没下载完整。"),
      ("Truncated", "压缩包不完整，可能没下载完。"),
      ("Unexpected end", "压缩包不完整，可能没下载完。"),
      ("Cannot open the file as", "不是压缩包，或者是分卷包的后几卷（要从第一卷解）。"),
      ("Unrecognized archive format", "不是压缩包，或者是不支持的格式。"),
      ("Path contains '..'", "包里有指向外面的路径（../），为了安全不解。"),
      ("No space left", "磁盘空间不够了。"),
      ("Read-only file system", "这个位置是只读的。"),
      ("Operation not permitted", "没有权限读写这个位置（系统设置 › 隐私与安全性 › 文件与文件夹）。"),
      ("Permission denied", "没有权限读写这个位置。"),
      ("errno=2 ", "有文件找不到了（移走或删掉了？）。"),
    ]
    // 不分大小写：tar 写的是「truncated gzip input」
    if let hit = known.first(where: { key, _ in
      lines.contains { $0.localizedCaseInsensitiveContains(key) }
    }) {
      return hit.1
    }
    return lines.last.map { String($0.prefix(200)) } ?? "退出码 \(result.status)"
  }
}
