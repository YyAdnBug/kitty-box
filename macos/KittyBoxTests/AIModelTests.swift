// AIModel：用本地 file:// 地址模拟下载——按 SHA256 校验、照原来的目录结构放好、进度一路报到 1；对不上就报错不放；
// 第一个地址下不了就换下一个（Hugging Face 连不上时换镜像）。
// zip 包用系统 tar 解开、找出 .mlpackage。
// 真从 Hugging Face 下一遍（标准约 216 MB；快速、高清另一个测试，下载 → 校验 →（解开）→ 编译 → 放进 Application Support 再补一次）
// 平时跳过，要验时：
// TEST_RUNNER_KITTY_LIVE_MODEL=1 xcodebuild -project macos/KittyBox.xcodeproj -scheme KittyBox \
//   test -only-testing:KittyBoxTests/AIModelTests

import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import KittyBox

struct AIModelTests {
  private func sandbox() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// 「服务器」上的两个文件，返回它们的描述（路径、SHA256、大小）
  private func serve(in root: URL) throws -> [AIModel.File] {
    let contents = [
      "Manifest.json": "{}", "Data/weights/weight.bin": String(repeating: "喵", count: 5000),
    ]
    return try contents.sorted(by: { $0.key < $1.key }).map { path, text in
      let url = root.appending(path: "server/" + path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
      return AIModel.File(
        path: path, sha256: try AIModel.sha256(of: url), size: Int64(Data(text.utf8).count))
    }
  }

  @Test func fetchesAndVerifies() async throws {
    let root = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try serve(in: root)
    let package = root.appending(path: "LaMa.mlpackage")
    let last = Mutex(0.0)
    try await AIModel.fetch(files, from: root.appending(path: "server/"), into: package) {
      fraction in
      last.withLock { $0 = fraction }
    }
    for file in files {
      #expect(try AIModel.sha256(of: package.appending(path: file.path)) == file.sha256)
    }
    #expect(last.withLock { $0 } == 1)
  }

  @Test func rejectsWrongChecksum() async throws {
    let root = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    var files = try serve(in: root)
    files[1] = AIModel.File(
      path: files[1].path, sha256: String(repeating: "0", count: 64), size: files[1].size)
    let package = root.appending(path: "LaMa.mlpackage")
    await #expect(throws: AIModel.Failure.self) {
      try await AIModel.fetch(files, from: root.appending(path: "server/"), into: package) {
        _ in
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
    try await AIModel.fetch(
      files, fromFirstOf: [root.appending(path: "nowhere/"), root.appending(path: "server/")],
      into: package
    ) { _ in }
    for file in files {
      #expect(try AIModel.sha256(of: package.appending(path: file.path)) == file.sha256)
    }
    // 都不行：报错
    await #expect(throws: (any Error).self) {
      try await AIModel.fetch(
        files, fromFirstOf: [root.appending(path: "nowhere/")], into: root.appending(path: "x")
      ) { _ in }
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_MODEL"] != nil))
  func installsRealModel() async throws {
    let seen = Mutex(0.0)
    try await AIModel.standard.install { fraction in seen.withLock { $0 = max($0, fraction) } }
    #expect(AIModel.standard.isInstalled)
    #expect(seen.withLock { $0 } == 1)
  }

  /// 下来的 zip 用系统 tar 解开，找出里面的 .mlpackage（略过 __MACOSX）
  @Test func unzipsPackage() async throws {
    let root = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appending(path: "src/Model.mlpackage/Data")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: package.appending(path: "weight.bin"))
    let zip = root.appending(path: "Model.mlpackage.zip")
    let made = try await Subprocess.run(
      "/usr/bin/tar",
      ["-a", "-cf", zip.path, "-C", root.appending(path: "src").path, "Model.mlpackage"])
    #expect(made.status == 0)
    let found = try await AIModel.unzipPackage(zip, into: root)
    #expect(found.lastPathComponent == "Model.mlpackage")
    #expect(FileManager.default.fileExists(atPath: found.appending(path: "Data/weight.bin").path))
  }

  /// 真下快速、高清两个模型（约 25 MB、190 MB）并各补一次：平时跳过，TEST_RUNNER_KITTY_LIVE_MODEL=1 时才跑
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_MODEL"] != nil),
    arguments: [AIModel.fast, .hd])
  func installsAndRuns(_ model: AIModel) async throws {
    if !model.isInstalled { try await model.install { _ in } }
    #expect(model.isInstalled)
    let (width, height) = (900, 600)
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 400, y: 250, width: 60, height: 60))
    let image = try #require(context.makeImage())
    let mask = EraseModel.mask(
      [.init(points: [CGPoint(x: 400, y: 320), CGPoint(x: 470, y: 320)], width: 90)], width: width,
      height: height)
    let result = try await Inpainter.shared.erase(image, mask: mask, using: model)
    #expect(result.width == width && result.height == height)
  }
}
