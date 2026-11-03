// Archiver：真的调包里的 7zz 和系统 tar，在临时目录里各跑一遍往返——zip / 7z、带密码和不带、ZipCrypto、
// GBK 名字的 zip、忽略清单和空文件夹、解压时去掉杂文件、只有一样东西时不多套一层、隔离标记跟着走、
// 打包报进度、半路停下不留半个包、「看看里面」列出文件（GBK 名字读对、杂文件不列、名字加密的 7z 要密码）；
// 怪名字（? * [ ]、两头空格、两头引号、换行、Icon␍、分解形式、链接）往返一个字节不差、包名带 * 也解在原地、不同文件夹的东西打进一个包、同名的不让打、
// 坏包说清楚、解到一半停下不留临时文件夹、../ 解不到外面、只有一个隐藏的东西时不放到包旁边、tar 一族和 ditto 的 zip、
// 分卷包、打包到 / 解到所选位置、只读的文件夹说是权限；外加名字和进度解析的纯函数。

import CoreServices
import Foundation
import Testing

@testable import KittyBox

struct ArchiverTests {
  /// 每个测试一个临时目录，测完删掉
  private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")

    init() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult func file(_ path: String, _ text: String = "hi") throws -> URL {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
      return url
    }

    func folder(_ path: String) throws -> URL {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    func exists(_ path: String) -> Bool {
      FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    /// 包挪到 out/ 下再解，解出来的东西就在 out/ 里，不和原文件撞名
    func moveToOut(_ archive: URL) throws -> URL {
      let out = try folder("out")
      let moved = out.appending(path: archive.lastPathComponent)
      try FileManager.default.moveItem(at: archive, to: moved)
      return moved
    }
  }

  /// 猫咪相册：要打的、系统杂文件、开发目录、空文件夹
  private func album(in box: Sandbox) throws -> URL {
    try box.file("猫咪相册/封面.txt")
    try box.file("猫咪相册/.DS_Store")
    try box.file("猫咪相册/照片/IMG_0001.txt")
    try box.file("猫咪相册/照片/._IMG_0001.txt")
    try box.file("猫咪相册/网站/node_modules/react/index.js")
    try box.file("猫咪相册/网站/debug.log")
    _ = try box.folder("猫咪相册/空的")
    return box.root.appending(path: "猫咪相册")
  }

  private let rules = IgnoreRules(IgnoreList.system.map(\.pattern) + ["node_modules", "*.log"])

  @Test func planFollowsRules() async throws {
    let box = try Sandbox()
    let plan = await Archiver.plan([try album(in: box)], rules: rules)
    // 网站/ 里的东西全被排掉了：它不进清单（进了 7zz 会把它整个递归打进去，连被忽略的一起）
    #expect(Set(plan.files) == ["猫咪相册/封面.txt", "猫咪相册/照片/IMG_0001.txt", "猫咪相册/空的"])
    // ._ 开头的附加信息文件系统遍历时就跳过了（实测），不进清单，也不出现在「忽略了」里
    #expect(
      Set(plan.ignored.map(\.path)) == [
        "猫咪相册/.DS_Store", "猫咪相册/网站/node_modules", "猫咪相册/网站/debug.log",
      ])
    #expect(plan.windowsProblems.isEmpty)
  }

  @Test(arguments: [Archiver.Format.zip, .sevenZip])
  func roundTrip(format: Archiver.Format) async throws {
    let box = try Sandbox()
    let plan = await Archiver.plan([try album(in: box)], rules: rules)
    let archive = try await Archiver.pack(plan, options: .init(format: format))
    #expect(archive.lastPathComponent == "猫咪相册." + format.rawValue)

    let result = try await Archiver.unpack(try box.moveToOut(archive))
    // 包里只有「猫咪相册」一个文件夹：直接放出来，不再套一层
    #expect(result.lastPathComponent == "猫咪相册")
    #expect(box.exists("out/猫咪相册/封面.txt"))
    #expect(box.exists("out/猫咪相册/照片/IMG_0001.txt"))
    #expect(box.exists("out/猫咪相册/空的"))
    #expect(!box.exists("out/猫咪相册/网站"))
    #expect(!box.exists("out/猫咪相册/.DS_Store"))
    #expect(!box.exists("out/猫咪相册/网站/node_modules"))
    #expect(!box.exists("out/猫咪相册/网站/debug.log"))
    // 临时文件夹没留下
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: box.root.appending(path: "out").path)
        .count == 2)
  }

  @Test(arguments: [
    (Archiver.Format.zip, false), (Archiver.Format.zip, true), (Archiver.Format.sevenZip, false),
  ])
  func passwords(format: Archiver.Format, windowsCompatible: Bool) async throws {
    let box = try Sandbox()
    let plan = await Archiver.plan([try box.file("机密.txt", "secret")], rules: rules)
    let password = format == .zip ? "Meow 123!" : "喵 123"
    let archive = try await Archiver.pack(
      plan, options: .init(format: format, password: password, windowsCompatible: windowsCompatible)
    )
    let moved = try box.moveToOut(archive)
    if format == .zip { #expect(ZipNames.entries(of: moved)?.allSatisfy(\.encrypted) == true) }

    await #expect(throws: Archiver.Failure.needsPassword) { try await Archiver.unpack(moved) }
    await #expect(throws: Archiver.Failure.wrongPassword) {
      try await Archiver.unpack(moved, password: "不对")
    }
    let result = try await Archiver.unpack(moved, password: password)
    #expect(try String(contentsOf: result, encoding: .utf8) == "secret")
    #expect(result.lastPathComponent == "机密.txt")
  }

  /// 打一个大包：边打边报进度，报了之后停下来，7zz 停掉、打了一半的包删掉
  @Test func packReportsProgressAndStops() async throws {
    let box = try Sandbox()
    let noise = try #require(FileHandle(forReadingAtPath: "/dev/urandom"))
    _ = try box.folder("大")
    for index in 1...4 {
      try noise.readData(ofLength: 40_000_000).write(to: box.root.appending(path: "大/\(index).bin"))
    }
    let plan = await Archiver.plan([box.root.appending(path: "大")], rules: rules)
    var reported: [Double] = []
    let packing = Task {
      try await Archiver.pack(plan, options: .init(format: .sevenZip)) { reported.append($0) }
    }
    for _ in 0..<100 where reported.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!reported.isEmpty)
    packing.cancel()
    await #expect(throws: CancellationError.self) { try await packing.value }
    #expect(!box.exists("大.7z"))
  }

  /// 压缩级别：同一堆重复的字，「存储」原样装、「最小」压得很小
  @Test func compressionLevels() async throws {
    let box = try Sandbox()
    let text = String(repeating: "喵呜 Kitty Box 打包测试。", count: 40_000)
    let plan = await Archiver.plan([try box.file("长文.txt", text)], rules: rules)
    let stored = try await Archiver.pack(plan, options: .init(format: .zip, level: .store))
    let smallest = try await Archiver.pack(plan, options: .init(format: .zip, level: .smallest))
    func size(_ url: URL) throws -> Int {
      try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
    #expect(try size(stored) > text.utf8.count)
    #expect(try size(smallest) < text.utf8.count / 20)
  }

  @Test func multiVolumeNames() {
    #expect(Archiver.isMultiVolume(URL(filePath: "/tmp/资源.7z.001")))
    #expect(Archiver.isMultiVolume(URL(filePath: "/tmp/资源.part1.rar")))
    #expect(!Archiver.isMultiVolume(URL(filePath: "/tmp/资源.rar")))
    #expect(!Archiver.isMultiVolume(URL(filePath: "/tmp/资源.zip")))
  }

  @Test func percentFromSevenZipProgress() {
    #expect(
      Archiver.lastPercent(in: "  0M Scan\u{8}\u{8}  0%\u{8}\u{8} 32% 6 + big/f6.bin\u{8} 65% 6")
        == 0.65)
    #expect(Archiver.lastPercent(in: "  0M Scan") == nil)
  }

  /// 7zz 打 zip 不收中文密码：先拦下来说清楚，不去跑 7zz
  @Test func zipRejectsNonASCIIPassword() async throws {
    let box = try Sandbox()
    let plan = await Archiver.plan([try box.file("a.txt")], rules: rules)
    await #expect(throws: Archiver.Failure.self) {
      try await Archiver.pack(plan, options: .init(format: .zip, password: "喵"))
    }
    #expect(!box.exists("a.txt.zip"))
    #expect(Archiver.passwordProblem(.init(format: .sevenZip, password: "喵")) == nil)
  }

  /// Windows 打的包：名字是 GBK、不标 UTF-8
  @Test func gbkZip() async throws {
    let box = try Sandbox()
    let archive = box.root.appending(path: "报告.zip")
    try zipData([(gbkName, false), (Array("readme.txt".utf8), false)]).write(to: archive)
    let result = try await Archiver.unpack(archive)
    // 两样东西：放进和包同名的文件夹
    #expect(result.lastPathComponent == "报告")
    #expect(box.exists("报告/报告/中文文件.txt"))
    #expect(box.exists("报告/readme.txt"))
  }

  @Test(arguments: [Archiver.Format.zip, .sevenZip])
  func contentsListFilesWithoutJunk(format: Archiver.Format) async throws {
    let box = try Sandbox()
    let plan = await Archiver.plan([try album(in: box)], rules: rules)
    let archive = try await Archiver.pack(plan, options: .init(format: format))
    let entries = try await Archiver.contents(of: archive)
    #expect(Set(entries.map(\.path)) == ["猫咪相册/封面.txt", "猫咪相册/照片/IMG_0001.txt"])
    #expect(entries.allSatisfy { $0.size == 2 })
  }

  @Test func contentsOfGBKZipAndLockedNames() async throws {
    let box = try Sandbox()
    let zip = box.root.appending(path: "报告.zip")
    try zipData([(gbkName, false), (Array("readme.txt".utf8), false)]).write(to: zip)
    #expect(try await Archiver.contents(of: zip).map(\.path) == ["报告/中文文件.txt", "readme.txt"])

    // 7z 设了密码连文件名也加密：不给密码看不了，给了就能看
    let plan = await Archiver.plan([try box.file("机密.txt", "secret")], rules: rules)
    let locked = try await Archiver.pack(
      plan, options: .init(format: .sevenZip, password: "喵 123"))
    await #expect(throws: Archiver.Failure.needsPassword) {
      try await Archiver.contents(of: locked)
    }
    #expect(try await Archiver.contents(of: locked, password: "喵 123").map(\.path) == ["机密.txt"])
  }

  @Test func severalItemsGoInAFolder() async throws {
    let box = try Sandbox()
    let items = [try box.file("a.txt"), try box.file("b.txt")]
    let archive = try await Archiver.pack(
      await Archiver.plan(items, rules: rules), options: .init())
    #expect(archive.lastPathComponent == "归档.zip")
    let result = try await Archiver.unpack(try box.moveToOut(archive))
    #expect(result.lastPathComponent == "归档")
    #expect(box.exists("out/归档/a.txt") && box.exists("out/归档/b.txt"))
  }

  /// 从网上下载的包解出来的东西也带隔离标记（同系统的归档实用工具）
  @Test func quarantineFollows() async throws {
    let box = try Sandbox()
    try box.file("工具/run.sh")
    let plan = await Archiver.plan([box.root.appending(path: "工具")], rules: rules)
    var archive = try box.moveToOut(try await Archiver.pack(plan, options: .init()))
    var values = URLResourceValues()
    values.quarantineProperties = [
      kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
      kLSQuarantineAgentNameKey as String: "KittyBoxTests",
    ]
    try archive.setResourceValues(values)

    let result = try await Archiver.unpack(archive)
    let extracted = result.appending(path: "run.sh")
    let properties = try extracted.resourceValues(forKeys: [.quarantinePropertiesKey])
      .quarantineProperties
    #expect(properties?[kLSQuarantineAgentNameKey as String] as? String == "KittyBoxTests")
  }

  /// 目录树：相对路径 → 内容（文件按字节、链接按指向、文件夹记 /），往返前后逐字节比
  private func tree(_ root: URL) throws -> [String: String] {
    let fileManager = FileManager.default
    var result: [String: String] = [:]
    guard let walker = fileManager.enumerator(atPath: root.path) else { return [:] }
    while let path = walker.nextObject() as? String {
      let url = root.appending(path: path)
      switch walker.fileAttributes?[.type] as? FileAttributeType {
      case .typeSymbolicLink?:
        result[path] = "→ " + (try fileManager.destinationOfSymbolicLink(atPath: url.path))
      case .typeDirectory?: result[path] = "/"
      default: result[path] = try Data(contentsOf: url).base64EncodedString()
      }
    }
    return result
  }

  /// 怪名字：? * [ ] 不当通配符，两头的空格、换行、Icon␍、- @ ; " 开头、分解形式、emoji、空文件夹、链接，
  /// 打进去解出来一个字节不差
  @Test(arguments: [Archiver.Format.zip, .sevenZip])
  func oddNamesRoundTrip(format: Archiver.Format) async throws {
    let box = try Sandbox()
    let names = [
      "Why?.txt", "Why1.txt", "a*.md", "abc.md", "br[a].txt", "bra.txt", " lead.txt", "trail.txt ",
      "new\nline.txt", "Icon\r", "-dash.txt", "@at.txt", ";semi.txt", "q\"uote.txt", "\"q\".txt",
      "e\u{301}.txt", "中文 名字.txt", "猫 😺.txt", "sub dir /x.txt", "sub/ y.txt", ".hidden",
    ]
    for (index, name) in names.enumerated() { try box.file("怪名字/" + name, "内容 \(index)") }
    _ = try box.folder("怪名字/空的")
    let source = box.root.appending(path: "怪名字")
    try FileManager.default.createSymbolicLink(
      atPath: source.appending(path: "link").path, withDestinationPath: "Why1.txt")
    try FileManager.default.createSymbolicLink(
      atPath: source.appending(path: "dirlink").path, withDestinationPath: "sub")

    let plan = await Archiver.plan([source], rules: IgnoreRules([]))
    let archive = try await Archiver.pack(plan, options: .init(format: format))
    let result = try await Archiver.unpack(try box.moveToOut(archive))
    #expect(try tree(result) == tree(source))
  }

  /// 只选「Why?.txt」：旁边的「Why1.txt」不跟着进去；解「Why?.7z」也不连带旁边的「Why1.7z」
  @Test func wildcardCharactersAreLiteral() async throws {
    let box = try Sandbox()
    let picked = try box.file("Why?.txt", "选的")
    try box.file("Why1.txt", "没选")
    let archive = try await Archiver.pack(
      await Archiver.plan([picked], rules: rules), options: .init(format: .sevenZip))
    #expect(try await Archiver.contents(of: archive).map(\.path) == ["Why?.txt"])

    let other = try await Archiver.pack(
      await Archiver.plan([box.root.appending(path: "Why1.txt")], rules: rules),
      options: .init(format: .sevenZip))
    #expect(other.lastPathComponent == "Why1.txt.7z")
    let out = try box.folder("out")
    let result = try await Archiver.unpack(archive, into: out)
    #expect(try String(contentsOf: result, encoding: .utf8) == "选的")
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["Why?.txt"])

    // 两头都是引号的名字：清单会去掉引号、打成旁边的「q」
    let quoted = try box.file("\"q\"", "选的")
    try box.file("q", "没选")
    let packed = try await Archiver.pack(
      await Archiver.plan([quoted], rules: rules), options: .init(format: .sevenZip))
    #expect(try await Archiver.contents(of: packed).map(\.path) == ["\"q\""])

    // 包名带 *：7zz 的 -o 会把 * 换成包名、解到别处去
    let star = try await Archiver.pack(
      await Archiver.plan([try box.file("a*b.txt", "星")], rules: rules),
      options: .init(format: .sevenZip))
    let starOut = try box.folder("星")
    let unpacked = try await Archiver.unpack(star, into: starOut)
    #expect(try String(contentsOf: unpacked, encoding: .utf8) == "星")
    #expect(try FileManager.default.contentsOfDirectory(atPath: starOut.path) == ["a*b.txt"])
  }

  /// 选的东西来自不同的文件夹：各自的文件都进去（第一个文件夹里同名的那个不会顶替），包放在第一样东西旁边；
  /// 7z 带密码（连文件名加密）分几次加进同一个包也行
  @Test(arguments: [(Archiver.Format.zip, ""), (.zip, "Meow 1"), (.sevenZip, "喵 1")])
  func itemsFromDifferentFolders(format: Archiver.Format, password: String) async throws {
    let box = try Sandbox()
    let report = try box.file("x/report.txt", "报告")
    try box.file("x/invoice.txt", "旧的、没选")
    let invoice = try box.file("y/invoice.txt", "新的")
    try box.file("y/资料/inner.txt", "里面")
    let plan = await Archiver.plan(
      [report, invoice, box.root.appending(path: "y/资料")], rules: rules)
    #expect(plan.clashes.isEmpty)
    #expect(plan.groups.count == 2)
    let archive = try await Archiver.pack(
      plan, options: .init(format: format, password: password))
    #expect(archive.deletingLastPathComponent().lastPathComponent == "x")
    let result = try await Archiver.unpack(try box.moveToOut(archive), password: password)
    #expect(
      try tree(result) == [
        "report.txt": Data("报告".utf8).base64EncodedString(),
        "invoice.txt": Data("新的".utf8).base64EncodedString(), "资料": "/",
        "资料/inner.txt": Data("里面".utf8).base64EncodedString(),
      ])
  }

  /// 不同文件夹里同名的（不分大小写）包里只放得下一个：不让打；同一样东西加两次、选了文件夹又选了它里面的，只算一次
  @Test func clashesAndDuplicates() async throws {
    let box = try Sandbox()
    let one = try box.file("x/r.txt")
    let two = try box.file("y/R.txt")
    let clash = await Archiver.plan([one, two], rules: rules)
    #expect(clash.clashes == ["R.txt"])
    await #expect(throws: Archiver.Failure.self) {
      try await Archiver.pack(clash, options: .init())
    }

    let folder = try box.folder("相册")
    let child = try box.file("相册/a.txt")
    let plan = await Archiver.plan(
      [folder, URL(filePath: folder.path + "/"), child], rules: rules)
    #expect(plan.items.count == 1)
    #expect(plan.clashes.isEmpty)
    let archive = try await Archiver.pack(plan, options: .init())
    #expect(archive.lastPathComponent == "相册.zip")
    #expect(try await Archiver.contents(of: archive).map(\.path) == ["相册/a.txt"])
  }

  /// 坏了的包说「坏了」，不是 7zz 满是退格的进度；解了一半的临时文件夹不留
  @Test func brokenArchiveSaysWhy() async throws {
    let box = try Sandbox()
    let noise = try #require(FileHandle(forReadingAtPath: "/dev/urandom"))
    try noise.readData(ofLength: 300_000).write(to: box.root.appending(path: "data.bin"))
    let archive = try await Archiver.pack(
      await Archiver.plan([box.root.appending(path: "data.bin")], rules: rules),
      options: .init(format: .sevenZip, level: .store))
    var bytes = try Data(contentsOf: archive)
    for index in stride(from: 1000, to: 200_000, by: 997) { bytes[index] ^= 0xFF }
    let broken = try box.folder("out").appending(path: "坏.7z")
    try bytes.write(to: broken)
    do {
      _ = try await Archiver.unpack(broken)
      Issue.record("坏包居然解开了")
    } catch Archiver.Failure.failed(let reason) {
      #expect(reason.contains("坏了"))
      #expect(!reason.unicodeScalars.contains { $0.value < 0x20 })
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: broken.deletingLastPathComponent().path)
        == ["坏.7z"])

    // zip 走 tar：坏的是第一条时，最后一行是后面好好的「x c.bin」，不能拿它当原因
    for name in ["a.bin", "b.bin", "c.bin"] {
      try noise.readData(ofLength: 2000).write(to: box.root.appending(path: name))
    }
    let zip = try await Archiver.pack(
      await Archiver.plan(
        ["a.bin", "b.bin", "c.bin"].map { box.root.appending(path: $0) }, rules: rules),
      options: .init(level: .store))
    var zipBytes = try Data(contentsOf: zip)
    zipBytes[500] ^= 0xFF
    let brokenZip = box.root.appending(path: "out/坏.zip")
    try zipBytes.write(to: brokenZip)
    do {
      _ = try await Archiver.unpack(brokenZip)
      Issue.record("坏 zip 居然解开了")
    } catch Archiver.Failure.failed(let reason) {
      #expect(reason.contains("坏了"))
    }
  }

  /// 解到一半停下：子进程停掉、隐藏的「.名字 解压中」删掉
  @Test func unpackStopsAndCleansUp() async throws {
    let box = try Sandbox()
    let noise = try #require(FileHandle(forReadingAtPath: "/dev/urandom"))
    try noise.readData(ofLength: 40_000_000).write(to: try box.folder("大").appending(path: "1.bin"))
    // PPMd 解得慢（每秒几十 MB），停得下来；「存储」的包一眨眼就解完了，赶不上停
    let sevenZip = try #require(Bundle.main.url(forAuxiliaryExecutable: "7zz"))
    let out = try box.folder("out")
    let made = try await Subprocess.run(
      sevenZip.path, ["a", "-t7z", "-m0=PPMd", out.appending(path: "大.7z").path, "大"],
      directory: box.root)
    #expect(made.status == 0)
    var reported: [Double] = []
    let unpacking = Task {
      try await Archiver.unpack(out.appending(path: "大.7z")) { reported.append($0) }
    }
    for _ in 0..<100 where reported.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!reported.isEmpty)
    unpacking.cancel()
    await #expect(throws: CancellationError.self) { try await unpacking.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["大.7z"])
  }

  /// 包里的 ../ 和绝对路径解不到外面去：带 ../ 的整个不解（说清楚为什么），绝对路径落在解压的文件夹里
  @Test func entriesNeverEscape() async throws {
    let box = try Sandbox()
    let inside = try box.folder("in")
    let slip = inside.appending(path: "slip.zip")
    try zipData([(Array("ok.txt".utf8), false), (Array("../escape.txt".utf8), false)]).write(
      to: slip)
    do {
      _ = try await Archiver.unpack(slip)
      Issue.record("带 ../ 的包居然解开了")
    } catch Archiver.Failure.failed(let reason) {
      #expect(reason.contains("../"))
    }
    #expect(!box.exists("escape.txt"))

    let absolute = "/tmp/kittybox-\(UUID()).txt"
    let abs = inside.appending(path: "abs.zip")
    try zipData([(Array("ok.txt".utf8), false), (Array(absolute.utf8), false)]).write(to: abs)
    let result = try await Archiver.unpack(abs)
    #expect(!FileManager.default.fileExists(atPath: absolute))
    #expect(FileManager.default.fileExists(atPath: result.appending(path: absolute).path))
  }

  /// 包里只有一个隐藏的东西或一个链接：照样放进和包同名的文件夹，不悄悄落在包旁边
  @Test func loneHiddenItemOrLinkStaysInAFolder() async throws {
    let box = try Sandbox()
    let dot = box.root.appending(path: "dot.zip")
    try zipData([(Array(".git/config".utf8), false)]).write(to: dot)
    let result = try await Archiver.unpack(dot)
    #expect(result.lastPathComponent == "dot")
    #expect(box.exists("dot/.git/config"))
    #expect(!box.exists(".git"))

    let link = box.root.appending(path: "victim")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
    let archive = try box.moveToOut(
      try await Archiver.pack(await Archiver.plan([link], rules: rules), options: .init()))
    let unpacked = try await Archiver.unpack(archive)
    #expect(unpacked.lastPathComponent == "victim")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: unpacked.appending(path: "victim").path)
        == "/etc/hosts")
  }

  /// tar 一族交给系统 tar：解出来、看看里面都对
  @Test(arguments: [
    ("t.tar", "-cf"), ("t.tar.gz", "-czf"), ("t.tgz", "-czf"), ("t.tar.bz2", "-cjf"),
    ("t.tar.xz", "-cJf"),
  ])
  func tarFamily(name: String, flag: String) async throws {
    let box = try Sandbox()
    try box.file("src/代码/main.c", "int main() {}")
    try box.file("src/代码/说明.md", "# 说明")
    let archive = box.root.appending(path: name)
    let made = try await Subprocess.run(
      "/usr/bin/tar", [flag, archive.path, "-C", box.root.appending(path: "src").path, "代码"])
    #expect(made.status == 0)
    #expect(Set(try await Archiver.contents(of: archive).map(\.path)) == ["代码/main.c", "代码/说明.md"])
    let result = try await Archiver.unpack(archive)
    #expect(result.lastPathComponent == "代码")
    #expect(try tree(result) == tree(box.root.appending(path: "src/代码")))
  }

  /// 访达、ditto 打的 zip：UTF-8 字节、不标志，名字照样对
  @Test func dittoZip() async throws {
    let box = try Sandbox()
    try box.file("src/报告/中文文件.txt", "中文")
    try box.file("src/报告/émoji 😺.txt", "猫")
    let archive = box.root.appending(path: "报告.zip")
    let made = try await Subprocess.run(
      "/usr/bin/ditto",
      ["-c", "-k", "--keepParent", box.root.appending(path: "src/报告").path, archive.path])
    #expect(made.status == 0)
    let result = try await Archiver.unpack(archive)
    #expect(try tree(result) == tree(box.root.appending(path: "src/报告")))
  }

  /// 分卷包：后几卷换成第一卷；第一卷解得出整套
  @Test func splitVolumes() async throws {
    let box = try Sandbox()
    let noise = try #require(FileHandle(forReadingAtPath: "/dev/urandom"))
    let data = noise.readData(ofLength: 250_000)
    try data.write(to: try box.folder("src").appending(path: "data.bin"))
    let sevenZip = try #require(Bundle.main.url(forAuxiliaryExecutable: "7zz"))
    let made = try await Subprocess.run(
      sevenZip.path, ["a", "-t7z", "-v100k", "-mx0", "../资源.7z", "data.bin"],
      directory: box.root.appending(path: "src"))
    #expect(made.status == 0)
    let volumes = ["001", "002", "003"].map { box.root.appending(path: "资源.7z." + $0) }
    #expect(volumes.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(volumes.map(Archiver.firstVolume) == Array(repeating: volumes[0], count: 3))
    // 第一卷不在旁边：原样留着
    #expect(
      Archiver.firstVolume(of: URL(filePath: "/tmp/没有.7z.002"))
        == URL(filePath: "/tmp/没有.7z.002"))
    #expect(Archiver.isMultiVolume(volumes[1]))

    let result = try await Archiver.unpack(volumes[0])
    #expect(try Data(contentsOf: result) == data)
    // 单独解后面的一卷：说清楚要从第一卷解
    do {
      _ = try await Archiver.unpack(volumes[1])
      Issue.record("第二卷居然单独解开了")
    } catch Archiver.Failure.failed(let reason) {
      #expect(reason.contains("第一卷"))
    }

    // .part2.rar → .part1.rar（位数照旧）
    try box.file("书.part01.rar")
    #expect(
      Archiver.firstVolume(of: box.root.appending(path: "书.part02.rar")).lastPathComponent
        == "书.part01.rar")
  }

  /// 打包到所选位置；解到所选文件夹（「打包到…」「解到…」）
  @Test func packToAndUnpackInto() async throws {
    let box = try Sandbox()
    let plan = await Archiver.plan([try box.file("a.txt", "甲")], rules: rules)
    let target = try box.folder("别处").appending(path: "自己起的名.zip")
    let archive = try await Archiver.pack(plan, options: .init(), to: target)
    #expect(archive == target)
    let into = try box.folder("解到这里")
    let result = try await Archiver.unpack(archive, into: into)
    #expect(result.deletingLastPathComponent().lastPathComponent == "解到这里")
    #expect(try String(contentsOf: result, encoding: .utf8) == "甲")
    // 「打包到…」选了要打进去的那个文件、点了替换：不打，它也不进废纸篓
    let source = box.root.appending(path: "a.txt")
    await #expect(throws: Archiver.Failure.self) {
      try await Archiver.pack(plan, options: .init(), to: source)
    }
    #expect(box.exists("a.txt"))
    // 选的是文件夹、存到它里面那个要打进去的旧包上：同样不打，旧包不进废纸篓
    let old = try box.file("项目/旧.zip", "旧")
    let folderPlan = await Archiver.plan([box.root.appending(path: "项目")], rules: rules)
    await #expect(throws: Archiver.Failure.self) {
      try await Archiver.pack(folderPlan, options: .init(), to: old)
    }
    #expect(box.exists("项目/旧.zip"))
  }

  /// 包放不进去（文件夹只读）：说清楚是权限
  @Test func unwritableFolderSaysSo() async throws {
    let box = try Sandbox()
    let folder = try box.folder("只读")
    let plan = await Archiver.plan([try box.file("只读/a.txt")], rules: rules)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }
    do {
      _ = try await Archiver.pack(plan, options: .init())
      Issue.record("只读的文件夹里居然打出了包")
    } catch Archiver.Failure.failed(let reason) {
      #expect(reason.contains("权限"))
    }
  }

  @Test func names() throws {
    func folder(_ name: String) -> String {
      Archiver.folderName(for: URL(filePath: "/tmp/" + name))
    }
    #expect(folder("猫咪相册.zip") == "猫咪相册")
    #expect(folder("代码.tar.gz") == "代码")
    #expect(folder("代码.tgz") == "代码")
    #expect(folder("资源.7z.001") == "资源")
    #expect(folder("资源.part1.rar") == "资源")
    #expect(folder("a.b.rar") == "a.b")

    #expect(Archiver.isArchive(URL(filePath: "/tmp/a.RAR")))
    #expect(Archiver.isArchive(URL(filePath: "/tmp/a.7z.002")))
    #expect(!Archiver.isArchive(URL(filePath: "/tmp/a.heic")))

    let box = try Sandbox()
    let taken = try box.file("报告.docx")
    #expect(taken.uniqued().lastPathComponent == "报告 2.docx")
    try box.file("报告 2.docx")
    #expect(taken.uniqued().lastPathComponent == "报告 3.docx")
    #expect(box.root.appending(path: "没有").uniqued().lastPathComponent == "没有")
    // 还没建出来、但已经有人要用的名字也跳过（两个直接打包差不多同时挑名字）
    let third = box.root.appending(path: "报告 3.docx").path
    #expect(taken.uniqued(excluding: [third]).lastPathComponent == "报告 4.docx")
    let planned = box.root.appending(path: "计划.zip")
    #expect(planned.uniqued(excluding: [planned.path]).lastPathComponent == "计划 2.zip")
  }
}
