// 图片转换（PLAN §2「图片转换」，C1–C3）：只用 ImageIO。系统能读的都能进（HEIC、WebP、AVIF、JXL、RAW、PSD…），能写 10 种。
// 结果放在原图旁边、换扩展名，重名加「 2」；照片里的信息（拍摄时间、相机、定位）原样带过去（C3）。
// 照片的「旋转方向」标记 PNG、GIF、BMP 这些格式不认，所以一律按方向转正了再写，标记改成 1。
// 2026-10-30 实测（macOS 27）：JPEG 自己会把透明处垫成白色；ICO 只收边长 ≤ 256 的正方形、ICNS 只收标准尺寸的正方形，
// 所以这两种先等比放进透明的正方形画布、出几种尺寸；PDF 能写不能读。
// ponytail: 解码走缩略图接口（为了转正方向），16 位、HDR 的图会变成 8 位；要保住再换成自己按方向画

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageConverter {
  enum Format: String, CaseIterable {
    case jpeg, png, heic, avif, tiff, gif, bmp, ico, icns, pdf

    var title: String { rawValue.uppercased() }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

    var typeIdentifier: String {
      switch self {
      case .jpeg: "public.jpeg"
      case .png: "public.png"
      case .heic: "public.heic"
      case .avif: "public.avif"
      case .tiff: "public.tiff"
      case .gif: "com.compuserve.gif"
      case .bmp: "com.microsoft.bmp"
      case .ico: "com.microsoft.ico"
      case .icns: "com.apple.icns"
      case .pdf: "com.adobe.pdf"
      }
    }

    /// 有损的才有质量
    var hasQuality: Bool { self == .jpeg || self == .heic || self == .avif }

    /// 能放多帧的：动图、多页
    var keepsFrames: Bool { self == .gif || self == .tiff || self == .pdf }

    /// 图标格式出的几种尺寸（正方形边长）
    var iconSizes: [Int]? {
      switch self {
      case .ico: [16, 32, 48, 256]
      case .icns: [16, 32, 128, 256, 512, 1024]
      default: nil
      }
    }
  }

  enum Failure: LocalizedError {
    case unreadable
    case unwritable

    var errorDescription: String? {
      switch self {
      case .unreadable: "读不出这张图。"
      case .unwritable: "写不出这种格式。"
      }
    }
  }

  /// 按扩展名看系统能不能读（拖进来的东西里挑出图片）
  static func canRead(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return readable.contains { type.conforms(to: $0) }
  }

  private static let readable = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    .compactMap { UTType($0) }

  /// 原图旁边、换扩展名，重名加「 2」
  static func output(for source: URL, format: Format) -> URL {
    source.deletingPathExtension().appendingPathExtension(format.fileExtension).uniqued()
  }

  @concurrent static func convert(_ source: URL, to format: Format, quality: Double) async throws
    -> URL
  {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      CGImageSourceGetCount(input) > 0
    else { throw Failure.unreadable }
    let frames = format.keepsFrames ? CGImageSourceGetCount(input) : 1
    let target = output(for: source, format: format)
    guard
      let destination = CGImageDestinationCreateWithURL(
        target as CFURL, format.typeIdentifier as CFString, format.iconSizes?.count ?? frames, nil)
    else { throw Failure.unwritable }

    if let sizes = format.iconSizes {
      guard let image = upright(input, at: 0) else { throw Failure.unreadable }
      for side in sizes { CGImageDestinationAddImage(destination, square(image, side: side), nil) }
    } else {
      // 整个文件的属性（比如动图循环几次）
      if let properties = CGImageSourceCopyProperties(input, nil) {
        CGImageDestinationSetProperties(destination, properties)
      }
      for index in 0..<frames {
        guard let image = upright(input, at: index) else { throw Failure.unreadable }
        var properties =
          CGImageSourceCopyPropertiesAtIndex(input, index, nil) as? [CFString: Any] ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
          tiff[kCGImagePropertyTIFFOrientation] = 1
          properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if format.hasQuality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      }
    }
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: target)
      throw Failure.unwritable
    }
    return target
  }

  /// 按「旋转方向」转正的整张图（RAW 也在这里显影）；画笔擦除也用它读图
  static func upright(_ source: CGImageSource, at index: Int) -> CGImage? {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
  }

  /// 去水印的结果另存：和原图同格式、带上原图的照片信息（方向标记改成 1：存的是已经转正的像素），有损格式质量 0.95。
  /// Gemini 角标和画笔擦除共用；写不出来时不留半截文件
  static func save(_ image: CGImage, like source: CGImageSource, to target: URL) -> Bool {
    guard let type = CGImageSourceGetType(source),
      let destination = CGImageDestinationCreateWithURL(target as CFURL, type, 1, nil)
    else { return false }
    var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    properties[kCGImagePropertyOrientation] = 1
    if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
      tiff[kCGImagePropertyTIFFOrientation] = 1
      properties[kCGImagePropertyTIFFDictionary] = tiff
    }
    properties[kCGImageDestinationLossyCompressionQuality] = 0.95
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: target)
      return false
    }
    return true
  }

  /// 等比放进透明的正方形画布（图标格式用）
  private static func square(_ image: CGImage, side: Int) -> CGImage {
    let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    context.draw(
      image,
      in: CGRect(
        x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
        width: size.width, height: size.height))
    return context.makeImage()!
  }
}
