// LaMaModel：用本地 file:// 地址模拟下载——按 SHA256 校验、照原来的目录结构放好、进度一路报到 1；对不上就报错不放；
// 第一个地址下不了就换下一个（Hugging Face 连不上时换镜像）。
// 真从 Hugging Face 下一遍（约 216 MB，下载 → 校验 → 编译 → 放进 Application Support）平时跳过，要验时：
// TEST_RUNNER_KITTY_LIVE_MODEL=1 xcodebuild -project macos/KittyBox.xcodeproj -scheme KittyBox \
//   test -only-testing:KittyBoxTests/LaMaModelTests

import Foundation
import Synchronization
import Testing

@testable import KittyBox

struct LaMaModelTests {
  private func sandbox() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// 「服务器」上的两个文件，返回它们的描述（路径、SHA256、大小）
  private func serve(in root: URL) throws -> [LaMaModel.File] {
    let contents = [
      "Manifest.json": "{}", "Data/weights/weight.bin": String(repeating: "喵", count: 5000),
    ]
    return try contents.sorted(by: { $0.key < $1.key }).map { path, text in
      let url = root.appending(path: "server/" + path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
      return LaMaModel.File(
        path: path, sha256: try LaMaModel.sha256(of: url), size: Int64(Data(text.utf8).count))
    }
  }

  @Test func fetchesAndVerifies() async throws {
    let root = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try serve(in: root)
    let package = root.appending(path: "LaMa.mlpackage")
    let last = Mutex(0.0)
    try await LaMaModel.fetch(files, from: root.appending(path: "server/"), into: package) {
      fraction in
      last.withLock { $0 = fraction }
    }
    for file in files {
      #expect(try LaMaModel.sha256(of: package.appending(path: file.path)) == file.sha256)
    }
    #expect(last.withLock { $0 } == 1)
  }

  @Test func rejectsWrongChecksum() async throws {
    let root = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    var files = try serve(in: root)
    files[1] = LaMaModel.File(
      path: files[1].path, sha256: String(repeating: "0", count: 64), size: files[1].size)
    let package = root.appending(path: "LaMa.mlpackage")
    await #expect(throws: LaMaModel.Failure.self) {
      try await LaMaModel.fetch(files, from: root.appending(path: "server/"), into: package) { _ in
      }
    }
    #expect(!FileManager.default.fileExists(atPath: package.appending(path: files[1].path).path))
  }

  @Test func fallsBackToNextSource() async throws {
    let root = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try serve(in: root)
    let package = root.appending(path: "LaMa.mlpackage")
    // 第一个地址什么都没有（像连不上的本站），第二个才有
    try await LaMaModel.fetch(
      files, fromFirstOf: [root.appending(path: "nowhere/"), root.appending(path: "server/")],
      into: package
    ) { _ in }
    for file in files {
      #expect(try LaMaModel.sha256(of: package.appending(path: file.path)) == file.sha256)
    }
    // 都不行：报错
    await #expect(throws: (any Error).self) {
      try await LaMaModel.fetch(
        files, fromFirstOf: [root.appending(path: "nowhere/")], into: root.appending(path: "x")
      ) { _ in }
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_MODEL"] != nil))
  func installsRealModel() async throws {
    let seen = Mutex(0.0)
    try await LaMaModel.install { fraction in seen.withLock { $0 = max($0, fraction) } }
    #expect(LaMaModel.isInstalled)
    #expect(seen.withLock { $0 } == 1)
  }
}
