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

  /// 原图旁边、换扩展名，重名加「 2」；挑中就占住（几张一起转时 a.png、a.jpg 都转成 a.heic 也不会互相盖掉）
  static func output(for source: URL, format: Format) throws -> URL {
    try source.deletingPathExtension().appendingPathExtension(format.fileExtension).reserved()
  }

  /// maxSide：长边超过它就等比缩到它（只缩不放；图标格式不管它）；stripLocation：去掉 GPS 定位，别的照片信息照样带
  @concurrent static func convert(
    _ source: URL, to format: Format, quality: Double, maxSide: Int? = nil,
    stripLocation: Bool = false
  ) async throws -> URL {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      CGImageSourceGetCount(input) > 0
    else { throw Failure.unreadable }
    let frames = format.keepsFrames ? CGImageSourceGetCount(input) : 1
    let target = try output(for: source, format: format)
    do {
      guard
        let destination = CGImageDestinationCreateWithURL(
          target as CFURL, format.typeIdentifier as CFString, format.iconSizes?.count ?? frames,
          nil)
      else { throw Failure.unwritable }

      if let sizes = format.iconSizes {
        // 图标最大 1024：不用按原图整张解
        guard let image = upright(input, at: 0, maxSide: sizes.max()) else {
          throw Failure.unreadable
        }
        for side in sizes {
          CGImageDestinationAddImage(destination, square(image, side: side), nil)
        }
      } else {
        // 整个文件的属性（比如动图循环几次）
        if var properties = CGImageSourceCopyProperties(input, nil) as? [CFString: Any] {
          if format == .gif, properties[kCGImagePropertyGIFDictionary] == nil {
            properties[kCGImagePropertyGIFDictionary] = gifTiming(from: properties, frame: false)
          }
          CGImageDestinationSetProperties(destination, properties as CFDictionary)
        }
        for index in 0..<frames {
          guard let image = upright(input, at: index, maxSide: maxSide) else {
            throw Failure.unreadable
          }
          var properties =
            CGImageSourceCopyPropertiesAtIndex(input, index, nil) as? [CFString: Any] ?? [:]
          properties[kCGImagePropertyOrientation] = 1
          if stripLocation { properties[kCGImagePropertyGPSDictionary] = nil }
          // 缩过的话 EXIF 里记的像素尺寸跟着改
          if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
          }
          if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
          }
          if format == .gif, properties[kCGImagePropertyGIFDictionary] == nil {
            properties[kCGImagePropertyGIFDictionary] = gifTiming(from: properties, frame: true)
          }
          if format.hasQuality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
          CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
      }
      guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
      return target
    } catch {
      // 占住的空文件（或写了一半的）删掉：这个名字是这一次占的，不是别人的
      try? FileManager.default.removeItem(at: target)
      throw error
    }
  }

  /// 别的动图格式（WebP、APNG、HEIC 序列）的帧间隔、循环次数放在各自的组里：转 GIF 时换成 GIF 的键，
  /// 不然转出来的 GIF 只放一遍、每帧都按 0.1 秒。frame：一帧的属性（帧间隔）；否则是整个文件的（循环次数）
  private static func gifTiming(from properties: [CFString: Any], frame: Bool) -> [CFString: Any]? {
    let groups = [
      (
        kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime, kCGImagePropertyWebPLoopCount
      ),
      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGLoopCount),
      (
        kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSDelayTime,
        kCGImagePropertyHEICSLoopCount
      ),
    ]
    for (group, delay, loop) in groups {
      guard let info = properties[group] as? [CFString: Any], let value = info[frame ? delay : loop]
      else { continue }
      return [frame ? kCGImagePropertyGIFDelayTime : kCGImagePropertyGIFLoopCount: value]
    }
    return nil
  }

  /// 按「旋转方向」转正的整张图（RAW 也在这里显影）；画笔擦除也用它读图。maxSide：长边最多这么长（只缩不放）
  static func upright(_ source: CGImageSource, at index: Int, maxSide: Int? = nil) -> CGImage? {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(width, height, 1), maxSide ?? .max),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
  }

  /// 去水印的结果另存在 wanted（「原名-去水印.原扩展名」），重名加「 2」、挑中就占住：和原图同格式、带上原图的照片信息
  /// （方向标记改成 1：存的是已经转正的像素），有损格式质量 0.95。系统写不了原图的格式（WebP、RAW、JPEG XL…）时
  /// 存成 PNG（不丢画质、留得住透明），不白做。AI 水印和画笔擦除共用；返回真正存在哪；写不出来时不留半截文件
  static func save(_ image: CGImage, like source: CGImageSource, as wanted: URL) throws -> URL {
    var type = (CGImageSourceGetType(source) as String?) ?? UTType.png.identifier
    var wanted = wanted
    if !writable.contains(type) {
      type = UTType.png.identifier
      wanted = wanted.deletingPathExtension().appendingPathExtension("png")
    }
    let target = try wanted.reserved()
    do {
      guard
        let destination = CGImageDestinationCreateWithURL(
          target as CFURL, type as CFString, 1, nil)
      else { throw Failure.unwritable }
      var properties =
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
      properties[kCGImagePropertyOrientation] = 1
      if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        tiff[kCGImagePropertyTIFFOrientation] = 1
        properties[kCGImagePropertyTIFFDictionary] = tiff
      }
      properties[kCGImageDestinationLossyCompressionQuality] = 0.95
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
      return target
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw error
    }
  }

  /// 画笔擦除还在用的老写法：target 是挑好的名字，存成了就是 true。WebP、RAW 存成了旁边的 PNG 也算存成
  /// （活儿不白做），这时真正的名字只有上面那个 save(_:like:as:) 报得出来
  static func save(_ image: CGImage, like source: CGImageSource, to target: URL) -> Bool {
    (try? save(image, like: source, as: target)) != nil
  }

  /// 系统能写的格式（读得了的比这多：WebP、RAW、JPEG XL 只能读）
  private static let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

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
