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
    // 字写在左下原点的 (950, 30) 起，左上原点下大约是 y 730–775；框要把它整个盖住
    let text = CGRect(x: 955, y: 730, width: 180, height: 40)
    #expect(boxes.first.map { $0.contains(text) } == true, "\(boxes)")
    #expect(try AIMark.locate(in: picture(label: nil)).isEmpty)
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
