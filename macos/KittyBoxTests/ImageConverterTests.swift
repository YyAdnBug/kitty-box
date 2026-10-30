// ImageConverter：10 种格式各转一遍（类型、尺寸对、JPEG 透明处是白的、图标是正方形）；照片的拍摄信息带过去、
// 旋转方向转正；动图转 GIF 留着每一帧；能读什么；结果的名字。

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import KittyBox

struct ImageConverterTests {
  private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    init() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
  }

  /// width × height，左半红、右半透明
  private func picture(_ width: Int, _ height: Int) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    return context.makeImage()!
  }

  private func write(
    _ images: [CGImage], to url: URL, type: String, properties: [CFString: Any] = [:]
  ) {
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, type as CFString, images.count, nil)!
    for image in images {
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
  }

  /// 图上 (x, y) 处的 RGBA（y 从上往下数）
  private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(
      image,
      in: CGRect(
        x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    return [data[0], data[1], data[2], data[3]]
  }

  @Test(arguments: ImageConverter.Format.allCases)
  func everyFormat(_ format: ImageConverter.Format) async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "图.png")
    write([picture(300, 200)], to: source, type: "public.png")

    let output = try await ImageConverter.convert(source, to: format, quality: 0.8)
    // PNG 转 PNG：原图就叫「图.png」，结果不覆盖它
    #expect(output.lastPathComponent == (format == .png ? "图 2.png" : "图." + format.fileExtension))
    #expect(FileManager.default.fileExists(atPath: output.path))
    guard format != .pdf else { return }  // PDF 能写不能读

    let result = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    #expect(CGImageSourceGetType(result) as String? == format.typeIdentifier)
    let image = try #require(CGImageSourceCreateImageAtIndex(result, 0, nil))
    if format.iconSizes != nil {
      #expect(image.width == image.height)
    } else {
      #expect(image.width == 300 && image.height == 200)
    }
    if format == .jpeg {
      #expect(pixel(image, x: 250, y: 100) == [255, 255, 255, 255])
    }
  }

  /// 竖着拍的照片（方向 6：要顺时针转 90° 才正）：转出来宽高对调、方向标记成 1，拍摄时间留着
  @Test func photoInfoAndOrientation() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "IMG_0001.jpg")
    write(
      [picture(300, 200)], to: source, type: "public.jpeg",
      properties: [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifDateTimeOriginal: "2026:10:30 12:00:00"
        ],
      ])

    for format in [ImageConverter.Format.heic, .png] {
      let output = try await ImageConverter.convert(source, to: format, quality: 0.8)
      let result = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
      let image = try #require(CGImageSourceCreateImageAtIndex(result, 0, nil))
      #expect(image.width == 200 && image.height == 300)
      let properties = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any]
      #expect((properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
      if format == .heic {
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:30 12:00:00")
      }
    }
  }

  @Test func animatedGIFKeepsFrames() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "动图.gif")
    write(
      [picture(40, 40), picture(40, 40), picture(40, 40)], to: source, type: "com.compuserve.gif")

    let gif = try await ImageConverter.convert(source, to: .gif, quality: 1)
    #expect(CGImageSourceCreateWithURL(gif as CFURL, nil).map(CGImageSourceGetCount) == 3)
    let png = try await ImageConverter.convert(source, to: .png, quality: 1)
    #expect(CGImageSourceCreateWithURL(png as CFURL, nil).map(CGImageSourceGetCount) == 1)
    // 同格式再转一次：不覆盖原图
    #expect(gif.lastPathComponent == "动图 2.gif")
  }

  @Test func readsWhatTheSystemReads() {
    for name in [
      "a.heic", "a.HEIC", "a.jpg", "a.webp", "a.avif", "a.jxl", "a.dng", "a.psd", "a.png",
    ] {
      #expect(ImageConverter.canRead(URL(filePath: "/tmp/" + name)), "\(name)")
    }
    for name in ["a.txt", "a.zip", "a.pdf", "a"] {
      #expect(!ImageConverter.canRead(URL(filePath: "/tmp/" + name)), "\(name)")
    }
  }

  @Test func unreadableFile() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "坏的.jpg")
    try Data("not an image".utf8).write(to: source)
    await #expect(throws: ImageConverter.Failure.self) {
      try await ImageConverter.convert(source, to: .png, quality: 1)
    }
    #expect(!FileManager.default.fileExists(atPath: box.root.appending(path: "坏的.png").path))
  }
}
