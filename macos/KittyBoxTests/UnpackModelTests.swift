// UnpackModel：一队压缩包怎么走——跳过一个的密码框后面的照样问、密码不对再问、重试只动没解成的、
// 没解成的再拖进来就是重试、分卷包一整套只解一次。真调 7zz 和 tar，在临时目录里；偏好用临时域（不看用户的「解完移到废纸篓」）。

import Foundation
import Testing

@testable import KittyBox

struct UnpackModelTests {
  private let root = FileManager.default.temporaryDirectory.appending(
    path: "kittybox-tests-\(UUID())")
  private let defaults = UserDefaults(suiteName: "kittybox-tests-\(UUID())")!

  /// 一个带密码的 7z（连文件名加密）或不带密码的 zip，放在 root/包/ 下
  private func archive(_ name: String, password: String = "") async throws -> URL {
    let source = root.appending(path: "源/" + name)
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(name.utf8).write(to: source)
    let plan = await Archiver.plan([source], rules: IgnoreRules([]))
    let made = try await Archiver.pack(
      plan, options: .init(format: password.isEmpty ? .zip : .sevenZip, password: password))
    let folder = root.appending(path: "包")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let moved = folder.appending(path: made.lastPathComponent)
    try FileManager.default.moveItem(at: made, to: moved)
    return moved
  }

  /// 等队里的都停下来（解完、没解成或等密码）
  private func settled(_ model: UnpackModel) async throws {
    for _ in 0..<200 {
      let busy = model.jobs.contains {
        switch $0.state {
        case .waiting, .running: true
        default: false
        }
      }
      if !busy { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("等太久了")
  }

  @Test func passwordPromptsKeepComing() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await archive("甲.txt", password: "一")
    let second = try await archive("乙.txt", password: "二")
    let plain = try await archive("丙.txt")
    let model = UnpackModel(defaults: defaults)
    model.add([first, second, plain])
    try await settled(model)
    #expect(model.jobs.count == 3)
    #expect(model.jobs[2].result != nil)
    #expect(model.askingID == model.jobs[0].id)

    // 跳过第一个：接着问第二个（以前弹框就此不再出来）
    model.skip(model.jobs[0].id)
    #expect(model.askingID == model.jobs[1].id)

    // 第一个点「输入密码…」给了错的：密码不对，再问它
    model.jobs[0].password = "错"
    model.retry(model.jobs[0].id)
    try await settled(model)
    guard case .needsPassword(again: true) = model.jobs[0].state else {
      Issue.record("密码不对时应该再问：\(model.jobs[0].state)")
      return
    }
    #expect(model.askingID == model.jobs[0].id)
    model.jobs[0].password = "一"
    model.retry(model.jobs[0].id)
    try await settled(model)
    #expect(model.jobs[0].result.map { try? String(contentsOf: $0, encoding: .utf8) } == "甲.txt")

    // 解好的那一行「重试」不动它（以前会再解一份「丙 2」）
    let done = model.jobs[2].result
    model.retry(model.jobs[2].id)
    try await settled(model)
    #expect(model.jobs[2].result == done)
    #expect(model.jobs.count == 3)
  }

  @Test func addingAFailedArchiveAgainRetriesIt() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let good = try await archive("坏.txt")
    let broken = good.deletingLastPathComponent().appending(path: "坏.zip")
    try Data("不是压缩包".utf8).write(to: broken)
    let model = UnpackModel(defaults: defaults)
    model.add([broken])
    try await settled(model)
    #expect(model.jobs.count == 1)
    #expect(model.jobs[0].canRetry)

    // 换成真的包再拖进来：还是那一行，这次解开了
    try FileManager.default.removeItem(at: broken)
    try FileManager.default.copyItem(at: good, to: broken)
    model.add([broken])
    try await settled(model)
    #expect(model.jobs.count == 1)
    #expect(model.jobs[0].result != nil)
    // 解完没挪到废纸篓（临时偏好里没开）
    #expect(FileManager.default.fileExists(atPath: broken.path))
  }

  @Test func wholeVolumeSetUnpacksOnce() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "源")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let noise = try #require(FileHandle(forReadingAtPath: "/dev/urandom"))
    try noise.readData(ofLength: 250_000).write(to: source.appending(path: "data.bin"))
    let sevenZip = try #require(Bundle.main.url(forAuxiliaryExecutable: "7zz"))
    _ = try await Subprocess.run(
      sevenZip.path, ["a", "-t7z", "-v100k", "-mx0", "../资源.7z", "data.bin"], directory: source)
    let volumes = ["001", "002", "003"].map { root.appending(path: "资源.7z." + $0) }
    let model = UnpackModel(defaults: defaults)
    model.add(volumes)
    try await settled(model)
    #expect(model.jobs.count == 1)
    #expect(model.jobs.first?.archive.lastPathComponent == "资源.7z.001")
    #expect(model.jobs.first?.result != nil)
  }
}
