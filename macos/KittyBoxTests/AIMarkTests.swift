// AIMark：哪些字算 AI 水印；在一张有纹理的图右下角写上「豆包AI生成」，认得出位置（框盖住那几个字）；干净的图认不出；
// 用户自己加的词整张图里找；画笔擦除「选文字」那一笔盖得住字框；补图模型下载过的话真去一次：结果里再也认不出水印字。

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import KittyBox

struct AIMarkTests {
  /// 1200 × 800 的渐变 + 斜纹；label 不为 nil 时写一行白字（默认在右下角，像「AI生成」角标；at 是左下为原点的起点）
  private func picture(label: String?, at origin: NSPoint = NSPoint(x: 950, y: 30)) -> CGImage {
    let (width, height) = (1200, 800)
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in stride(from: 0, to: width, by: 8) {
      context.setFillColor(
        CGColor(red: 0.2 + Double(x) / Double(width) * 0.5, green: 0.35, blue: 0.55, alpha: 1))
      context.fill(CGRect(x: x, y: 0, width: 8, height: height))
    }
    if let label {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      (label as NSString).draw(
        at: origin,
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 34, weight: .medium),
          .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ])
      NSGraphicsContext.restoreGraphicsState()
    }
    return context.makeImage()!
  }

  @Test func keywords() {
    #expect(AIMark.isWatermark("豆包AI生成"))
    #expect(AIMark.isWatermark("AI 生成"))
    #expect(AIMark.isWatermark("Made with AI"))
    #expect(AIMark.isWatermark("即梦 AI"))
    #expect(!AIMark.isWatermark("2026 年 10 月 30 日"))
  }

  @Test func findsTextWatermark() throws {
    let boxes = try AIMark.locate(in: picture(label: "豆包AI生成"))
    #expect(boxes.count == 1)
    // 字的墨迹（CTLineGetImageBounds 量的）在左上原点下 x 951–1118、y 736–767；框要把它整个盖住、四周再留 2 像素
    let text = CGRect(x: 949, y: 734, width: 171, height: 35)
    #expect(boxes.first.map { $0.contains(text) } == true, "\(boxes)")
    #expect(try AIMark.locate(in: picture(label: nil)).isEmpty)
  }

  /// 大图角上又小又半透明的水印（2026-11-02 用户的海报，整张认不出）：1672×2508、水面一样的亮暗横纹，右下角半透明白字带灰边。
  /// 整张认一个字都认不到，四个角各认一遍才认得到（常认错成「每包AI生成」「長包图生成」，贴边的短「…生成」也算）
  /// ink：字的墨迹（左上原点，CTLineGetImageBounds 量的，四周再放 2 像素）
  @Test(arguments: [
    (30.0, 0.7, CGRect(x: 1389, y: 2448, width: 153, height: 31)),
    (22.0, 0.55, CGRect(x: 1388, y: 2456, width: 114, height: 24)),
  ])
  func findsFaintCornerWatermark(size: CGFloat, alpha: CGFloat, ink: CGRect) throws {
    let (width, height) = (1672, 2508)
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.78, green: 0.84, blue: 0.82, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // 确定的伪随机，每次画出来一样
    var seed: UInt64 = 42
    func next() -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(seed >> 33) / Double(1 << 31)
    }
    for _ in 0..<9000 {
      let rect = CGRect(
        x: next() * Double(width), y: next() * Double(height), width: 20 + next() * 160,
        height: 1 + next() * 4)
      let value = 0.55 + next() * 0.45
      context.setFillColor(CGColor(red: value * 0.9, green: value, blue: value * 0.97, alpha: 0.8))
      context.fill(rect)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    ("豆包AI生成" as NSString).draw(
      at: NSPoint(x: 1390, y: 28),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .strokeColor: NSColor(white: 0.45, alpha: 0.5), .strokeWidth: -2.0,
      ])
    NSGraphicsContext.restoreGraphicsState()
    let boxes = try AIMark.locate(in: context.makeImage()!)
    #expect(boxes.count == 1, "\(boxes)")
    #expect(boxes.first.map { $0.contains(ink) } == true, "\(boxes)")
  }

  @Test func shortGeneratedLabel() {
    #expect(AIMark.isAILabel(AIMark.fold("虹生成")))
    #expect(AIMark.isAILabel(AIMark.fold("三包A生成")))
    #expect(!AIMark.isAILabel(AIMark.fold("本页内容由系统自动生成，仅供参考")))
    #expect(!AIMark.isAILabel(AIMark.fold("2026 年 10 月")))
  }

  /// 用户加的词：分隔符认中英文逗号、顿号、换行，空格留在词里；整张图里找（字在正中间），不加就不认
  @Test func findsUserWords() throws {
    #expect(AIMark.words(" 样张，@Some One、Made with AI\n,") == ["样张", "@someone", "madewithai"])
    let image = picture(label: "样张 仅供参考", at: NSPoint(x: 450, y: 380))
    #expect(try AIMark.locate(in: image).isEmpty)
    let boxes = try AIMark.locate(in: image, words: AIMark.words("样张"))
    #expect(boxes.count == 1)
    // 字在左上原点下大约 y 380–425、x 450 起
    #expect(boxes.first.map { $0.contains(CGRect(x: 455, y: 382, width: 150, height: 36)) } == true)
  }

  /// 画笔擦除「选文字」：盖住一行的那一笔画成遮罩，字框四个角和中间都是白的（要补）
  @Test func textStrokeCoversBox() {
    let box = CGRect(x: 100, y: 60, width: 300, height: 40)
    let mask = EraseModel.mask([EraseModel.stroke(covering: box)], width: 600, height: 200)
    let context = CGContext(
      data: nil, width: 600, height: 200, bitsPerComponent: 8, bytesPerRow: 600,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.draw(mask, in: CGRect(x: 0, y: 0, width: 600, height: 200))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    // 位图的行从上往下排，和框的左上原点一致
    for point in [(100, 60), (399, 60), (100, 99), (399, 99), (250, 80)] {
      #expect(bytes[point.1 * 600 + point.0] > 200, "\(point)")
    }
    #expect(bytes[5 * 600 + 5] == 0)
  }

  @Test(.enabled(if: AIModel.standard.isInstalled)) func removesTextWatermark() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "海报.png")
    let destination = try #require(
      CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, picture(label: "豆包AI生成"), nil)
    #expect(CGImageDestinationFinalize(destination))

    let output = try await AIMark.clean(source, using: .standard)
    #expect(output.lastPathComponent == "海报-去水印.png")
    let result = try #require(
      CGImageSourceCreateWithURL(output as CFURL, nil).flatMap {
        CGImageSourceCreateImageAtIndex($0, 0, nil)
      })
    #expect(try AIMark.locate(in: result).isEmpty)

    let clean = root.appending(path: "干净.png")
    let plain = try #require(
      CGImageDestinationCreateWithURL(clean as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(plain, picture(label: nil), nil)
    #expect(CGImageDestinationFinalize(plain))
    await #expect(throws: AIMark.Failure.self) { try await AIMark.clean(clean, using: .standard) }
  }
}
