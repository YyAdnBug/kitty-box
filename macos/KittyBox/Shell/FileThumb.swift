// 文件在列表 / 表格里显示的几样：小图（图片用 ImageIO 出缩略图、按方向转正，别的用访达的图标）、种类、大小、图片的像素尺寸、
// 处理前后大小差多少。每一格自己在后台读（只读文件头和属性，很快），不另建缓存。去水印的预览和对比图也用 Thumbnail.load。

import AppKit
import ImageIO
import SwiftUI

enum Thumbnail {
  /// 长边不超过 maxPixel 的图，按方向转正；读不了是 nil
  @concurrent nonisolated static func load(_ url: URL, maxPixel: Int) async -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

enum FileFacts {
  /// 文件大小；文件夹、读不到是 nil（同访达，文件夹不算大小）
  @concurrent nonisolated static func bytes(_ url: URL) async -> Int64? {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
    guard values?.isDirectory != true, let size = values?.fileSize else { return nil }
    return Int64(size)
  }

  /// 种类（「PNG 图像」「文件夹」），同访达的「种类」
  @concurrent nonisolated static func kind(_ url: URL) async -> String? {
    try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
  }

  /// 图片的像素宽高（转正后的方向）
  @concurrent nonisolated static func pixels(_ url: URL) async -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return orientation >= 5 ? (height, width) : (width, height)
  }
}

/// 一行前面的小图：图片是圆角缩略图，别的是访达图标
struct FileThumb: View {
  let url: URL
  var size: CGFloat = 36
  @State private var image: CGImage?
  @Environment(\.displayScale) private var scale

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.tile(size) / 2, style: .continuous)
    Group {
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: size, height: size)
          .clipShape(shape)
          .overlay { shape.hairlineBorder() }
      } else {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
          .resizable()
          .frame(width: size, height: size)
      }
    }
    .accessibilityHidden(true)
    .task(id: url) {
      guard ImageConverter.canRead(url) else { return }
      image = await Thumbnail.load(url, maxPixel: Int(size * scale))
    }
  }
}

/// 表格里的「大小」：12.3 MB；文件夹是「--」
struct FileSizeText: View {
  let url: URL
  @State private var bytes: Int64?

  var body: some View {
    Text(bytes.map { $0.formatted(.byteCount(style: .file)) } ?? "--")
      .monospacedDigit()
      .task(id: url) { bytes = await FileFacts.bytes(url) }
  }
}

/// 表格里的「种类」
struct FileKindText: View {
  let url: URL
  @State private var kind: String?

  var body: some View {
    Text(kind ?? "")
      .task(id: url) { kind = await FileFacts.kind(url) }
  }
}

/// 表格里的「尺寸」：4032 × 3024
struct PixelSizeText: View {
  let url: URL
  @State private var pixels: (width: Int, height: Int)?

  var body: some View {
    Text(pixels.map { "\($0.width) × \($0.height)" } ?? "--")
      .monospacedDigit()
      .task(id: url) { pixels = await FileFacts.pixels(url) }
  }
}

/// 处理后的大小和差多少：「1.2 MB  −72%」，小了染绿、大了不染
struct SizeChangeText: View {
  let source: URL
  let result: URL
  @State private var sizes: (before: Int64, after: Int64)?

  var body: some View {
    HStack(spacing: 6) {
      if let sizes {
        Text(sizes.after.formatted(.byteCount(style: .file))).monospacedDigit()
        let change = Double(sizes.after - sizes.before) / Double(max(sizes.before, 1))
        Text(change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())))
          .monospacedDigit()
          .foregroundStyle(change < 0 ? Color.green : Color.secondary)
      }
    }
    .task(id: [source, result]) {
      guard let before = await FileFacts.bytes(source), let after = await FileFacts.bytes(result)
      else { return }
      sizes = (before, after)
    }
  }
}
