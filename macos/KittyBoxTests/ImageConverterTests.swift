// ImageConverter：10 种格式各转一遍（类型、尺寸对、JPEG 透明处是白的、图标是正方形）；照片的拍摄信息带过去、
// 旋转方向转正；动图转 GIF 留着每一帧（APNG 的帧间隔、循环跟着过去）；能读什么；结果的名字（几张一起转撞了名也各占一个）；
// 缩到长边上限（只缩不放）、去掉定位只去 GPS；文件夹不能写时报没有权限；去水印的结果 WebP 存成 PNG。

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

  @Test func resizesAndStripsLocation() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "旅行.jpg")
    write(
      [picture(3000, 2000)], to: source, type: "public.jpeg",
      properties: [
        kCGImagePropertyGPSDictionary: [
          kCGImagePropertyGPSLatitude: 35.68, kCGImagePropertyGPSLatitudeRef: "N",
        ],
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifDateTimeOriginal: "2026:10:30 12:00:00"
        ],
      ])

    let output = try await ImageConverter.convert(
      source, to: .jpeg, quality: 0.8, maxSide: 800, stripLocation: true)
    let result = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(result, 0, nil))
    #expect(image.width == 800 && image.height == 533)
    let properties = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any]
    #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
    let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:30 12:00:00")

    // 小图不放大；不去定位时 GPS 带过去
    let kept = try await ImageConverter.convert(source, to: .heic, quality: 0.8, maxSide: 8000)
    let keptSource = try #require(CGImageSourceCreateWithURL(kept as CFURL, nil))
    let keptImage = try #require(CGImageSourceCreateImageAtIndex(keptSource, 0, nil))
    #expect(keptImage.width == 3000)
    let keptProperties = CGImageSourceCopyPropertiesAtIndex(keptSource, 0, nil) as? [CFString: Any]
    #expect(keptProperties?[kCGImagePropertyGPSDictionary] != nil)
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

  /// 动图 PNG（APNG）转 GIF：每帧多久、一直循环跟着过去（WebP、HEIC 序列同理），不然只放一遍、每帧 0.1 秒
  @Test func animationTimingToGIF() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "动图.png")
    let destination = try #require(
      CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 3, nil))
    CGImageDestinationSetProperties(
      destination,
      [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
    for _ in 0..<3 {
      CGImageDestinationAddImage(
        destination, picture(40, 40),
        [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.3]] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))

    let gif = try await ImageConverter.convert(source, to: .gif, quality: 1)
    let result = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
    #expect(CGImageSourceGetCount(result) == 3)
    let file = CGImageSourceCopyProperties(result, nil) as? [CFString: Any]
    let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[
      kCGImagePropertyGIFLoopCount]
    #expect(loop as? Int == 0)
    let frame = CGImageSourceCopyPropertiesAtIndex(result, 1, nil) as? [CFString: Any]
    let delay = (frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[
      kCGImagePropertyGIFDelayTime]
    #expect((delay as? Double).map { abs($0 - 0.3) < 0.01 } == true, "\(String(describing: delay))")
  }

  /// 几张一起转、名字撞在一起（a.png 和 a.jpg 都转成 a.heic）：各占一个名字，谁也不盖掉谁
  @Test func sameNameInParallel() async throws {
    let box = try Sandbox()
    let root = box.root
    let types = [
      "a.png": "public.png", "a.jpg": "public.jpeg", "a.tiff": "public.tiff",
      "a.bmp": "com.microsoft.bmp",
    ]
    for (name, type) in types {
      write([picture(300, 200)], to: root.appending(path: name), type: type)
    }
    let outputs = try await withThrowingTaskGroup(of: URL.self) { group in
      for name in types.keys {
        group.addTask {
          try await ImageConverter.convert(root.appending(path: name), to: .heic, quality: 0.8)
        }
      }
      var outputs: [URL] = []
      for try await output in group { outputs.append(output) }
      return outputs
    }
    #expect(
      Set(outputs.map(\.lastPathComponent)) == ["a.heic", "a 2.heic", "a 3.heic", "a 4.heic"])
    for output in outputs {
      let result = CGImageSourceCreateWithURL(output as CFURL, nil)
      #expect(result.flatMap { CGImageSourceGetType($0) } as String? == "public.heic")
    }
  }

  /// 文件夹不能写：报系统的「没有权限」，不说「写不出这种格式」，也不留空文件
  @Test func readOnlyFolder() async throws {
    let box = try Sandbox()
    let folder = box.root.appending(path: "只读")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appending(path: "图.png")
    write([picture(30, 20)], to: source, type: "public.png")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }
    let error = await #expect(throws: CocoaError.self) {
      try await ImageConverter.convert(source, to: .jpeg, quality: 0.8)
    }
    #expect(error?.code == .fileWriteNoPermission)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["图.png"])
  }

  /// 去水印的结果另存：系统写不了的 WebP 存成 PNG（画笔擦除、AI 水印不白做）；写得了的同格式
  @Test func savesUnwritableAsPNG() throws {
    let box = try Sandbox()
    // 1×1 的 WebP（系统写不了 WebP，只能放现成的字节）
    let webp = try #require(
      Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA=="))
    let input = try #require(CGImageSourceCreateWithData(webp as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(input, 0, nil))

    let saved = try ImageConverter.save(
      image, like: input, as: box.root.appending(path: "图-去水印.webp"))
    #expect(saved.lastPathComponent == "图-去水印.png")
    let result = try #require(CGImageSourceCreateWithURL(saved as CFURL, nil))
    #expect(CGImageSourceGetType(result) as String? == "public.png")
    // 再存一次（画笔擦除再擦再存）：不盖掉上一份，报的是真正的名字
    let again = try ImageConverter.save(
      image, like: input, as: box.root.appending(path: "图-去水印.webp"))
    #expect(again.lastPathComponent == "图-去水印 2.png")

    let png = box.root.appending(path: "原图.png")
    write([picture(30, 20)], to: png, type: "public.png")
    let pngInput = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
    let same = try ImageConverter.save(
      picture(30, 20), like: pngInput, as: png.adding("-去水印"))
    #expect(same.lastPathComponent == "原图-去水印.png")
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
