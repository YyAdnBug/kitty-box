// Archiver：真的调包里的 7zz 和系统 tar，在临时目录里各跑一遍往返——zip / 7z、带密码和不带、ZipCrypto、
// GBK 名字的 zip、忽略清单和空文件夹、解压时去掉杂文件、只有一样东西时不多套一层、隔离标记跟着走；外加名字的纯函数。

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

    await #expect(throws: Archiver.Failure.needsPassword) { try await Archiver.unpack(moved) }
    await #expect(throws: Archiver.Failure.wrongPassword) {
      try await Archiver.unpack(moved, password: "不对")
    }
    let result = try await Archiver.unpack(moved, password: password)
    #expect(try String(contentsOf: result, encoding: .utf8) == "secret")
    #expect(result.lastPathComponent == "机密.txt")
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
    #expect(Archiver.uniqueURL(taken).lastPathComponent == "报告 2.docx")
    try box.file("报告 2.docx")
    #expect(Archiver.uniqueURL(taken).lastPathComponent == "报告 3.docx")
    #expect(Archiver.uniqueURL(box.root.appending(path: "没有")).lastPathComponent == "没有")
  }
}
