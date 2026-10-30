// Cutout：系统自带的鹦鹉头像（/Library/User Pictures/Animals/Parrot.heic，先拷到临时目录，结果写在它旁边）去背景，
// 系统、精细两种抠法各一遍：透明的存成 PNG、四角是透明的、中间（鹦鹉）不透明；白底的四角是白的；裁到主体时比原图小。
// 精细要抠图模型：下载过才跑；TEST_RUNNER_KITTY_LIVE_MODEL=1 时没下过就先真下一次（约 82 MB）。

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import KittyBox

nonisolated private let parrot = URL(filePath: "/Library/User Pictures/Animals/Parrot.heic")

struct CutoutTests {
  /// (x, y) 处的 RGBA（y 从上往下数）
  private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(
      image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    return [data[0], data[1], data[2], data[3]]
  }

  private func image(at url: URL) throws -> CGImage {
    try #require(
      CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
        CGImageSourceCreateImageAtIndex($0, 0, nil)
      })
  }

  @Test(
    .enabled(if: FileManager.default.fileExists(atPath: parrot.path)),
    arguments: [Cutout.Engine.system, .model])
  func removesBackground(_ engine: Cutout.Engine) async throws {
    if engine == .model, !AIModel.cutout.isInstalled {
      guard ProcessInfo.processInfo.environment["KITTY_LIVE_MODEL"] != nil else { return }
      try await AIModel.cutout.install { _ in }
    }
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "鹦鹉.heic")
    // 系统那几张是相对路径的替身，拷替身过来会断：拷它指着的那张
    try FileManager.default.copyItem(at: parrot.resolvingSymlinksInPath(), to: source)
    let original = try image(at: source)

    let clear = try await Cutout.remove(
      source, background: .transparent, crop: false, engine: engine)
    #expect(clear.lastPathComponent == "鹦鹉-去背景.png")
    let cut = try image(at: clear)
    #expect(cut.width == original.width && cut.height == original.height)
    #expect(pixel(cut, x: 2, y: 2)[3] == 0)
    #expect(pixel(cut, x: cut.width / 2, y: cut.height / 2)[3] == 255)

    let white = try image(
      at: try await Cutout.remove(source, background: .white, crop: false, engine: engine))
    #expect(pixel(white, x: 2, y: 2) == [255, 255, 255, 255])

    let cropped = try image(
      at: try await Cutout.remove(source, background: .transparent, crop: true, engine: engine))
    #expect(cropped.width * cropped.height < original.width * original.height)
  }
}
