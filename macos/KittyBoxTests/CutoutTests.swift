// Cutout：系统自带的鹦鹉头像（/Library/User Pictures/Animals/Parrot.heic，先拷到临时目录，结果写在它旁边）去背景，
// 系统、精细两种抠法各一遍：透明的存成 PNG、四角是透明的、中间（鹦鹉）不透明；白底的四角是白的；裁到主体时比原图小；
// 开着保留文字也一样（照片上没有字）。保留文字：米黄纸上三行黑字（CoreText 画的），开着时笔画不透明还是黑的、
// 纸全透明、字边去掉预乘后不带纸色，裁到主体只剩字那块；关着时字留不全（或认不出主体）。
// 精细要抠图模型：下载过才跑；TEST_RUNNER_KITTY_LIVE_MODEL=1 时没下过就先真下一次（约 82 MB）。

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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

    // 保留文字开着，照片上没有字：和关着一样抠
    let kept = try image(
      at: try await Cutout.remove(
        source, background: .transparent, crop: false, engine: engine, keepText: true))
    #expect(pixel(kept, x: 2, y: 2)[3] == 0)
    #expect(pixel(kept, x: kept.width / 2, y: kept.height / 2)[3] == 255)
  }

  /// 整张图的 RGBA（预乘，第一行在上）
  private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  /// 米黄纸上三行黑字（CoreText 画，同海报、截图），存成 PNG
  private func writePoster(to url: URL) throws {
    let (width, height) = (900, 520)
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: 240 / 255, green: 225 / 255, blue: 190 / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("PingFang SC" as CFString, 44, nil)
    for (row, text) in ["01  小合唱《往日时光》", "02  相声《四十年再聚》", "表演者：李茂旺、左湘江"].enumerated() {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: text,
          attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
              gray: 0, alpha: 1),
          ]))
      context.textPosition = CGPoint(x: 60, y: CGFloat(height - 120 - row * 150))
      CTLineDraw(line, context)
    }
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  @Test(arguments: [Cutout.Engine.system, .model])
  func keepsText(_ engine: Cutout.Engine) async throws {
    if engine == .model, !AIModel.cutout.isInstalled { return }
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "节目单.png")
    try writePoster(to: source)
    let original = try image(at: source)
    let before = rgba(original)

    let result = try image(
      at: try await Cutout.remove(
        source, background: .transparent, crop: false, engine: engine, keepText: true))
    #expect(result.width == original.width && result.height == original.height)
    let after = rgba(result)
    var (ink, paper, lostInk, keptPaper, fringe) = (0, 0, 0, 0, 0)
    for index in stride(from: 0, to: before.count, by: 4) {
      let color = Array(before[index..<index + 3])
      if color == [0, 0, 0] {
        // 笔画中间：不透明、还是黑的
        ink += 1
        if after[index + 3] < 250 || after[index] > 40 { lostInk += 1 }
      } else if color == [240, 225, 190] {
        // 纸（行与行之间、字与字之间）：透明
        paper += 1
        if after[index + 3] > 8 { keptPaper += 1 }
      }
      // 留下的像素（字边的半透明也算）去掉预乘后还是黑的：没带一圈纸色
      let alpha = Int(after[index + 3])
      if alpha >= 32, (0..<3).contains(where: { Int(after[index + $0]) * 255 / alpha > 60 }) {
        fringe += 1
      }
    }
    #expect(ink > 1000 && paper > 100_000)
    #expect(lostInk == 0)
    #expect(keptPaper == 0)
    #expect(fringe == 0)

    // 裁到主体：只剩字那块
    let cropped = try image(
      at: try await Cutout.remove(
        source, background: .transparent, crop: true, engine: engine, keepText: true))
    #expect(cropped.width < original.width && cropped.height < original.height)

    // 关着：字留不全（系统认不出主体，模型把字当背景）
    do {
      let plain = rgba(
        try image(
          at: try await Cutout.remove(
            source, background: .transparent, crop: false, engine: engine)))
      let opaque = stride(from: 0, to: before.count, by: 4).count {
        before[$0] == 0 && before[$0 + 1] == 0 && before[$0 + 2] == 0 && plain[$0 + 3] >= 250
      }
      #expect(opaque < ink)
    } catch Cutout.Failure.noSubject {}
  }
}
