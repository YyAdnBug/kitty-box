// 文件的小图：图片用 ImageIO 出缩略图（按方向转正），别的用访达的图标。列表的一行、去水印的预览和对比图共用 Thumbnail.load。

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

/// 一行前面的小图：图片是圆角缩略图，别的是访达图标
struct FileThumb: View {
  let url: URL
  var size: CGFloat = 36
  @State private var image: CGImage?
  @Environment(\.displayScale) private var scale

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
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
