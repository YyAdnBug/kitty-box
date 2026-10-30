// 视频固定台标（D4–D6）：在第一帧上框出台标（可以框几处），AVFoundation 逐帧交给 Core Image；每一帧只把框外一圈的小块读回来，
// 框里的每个像素按到框外左右上下四条边的距离、对边上紧挨着的像素加权补上（越近越重，思路同 ffmpeg 的 delogo，代码自己写），
// 框外再留一圈羽化带慢慢过渡，贴回画面。导出编码跟原视频走（HEVC 出 HEVC，其余 H.264），结果「原名-去水印」放在原视频旁边。
// 不用 Metal 写 Core Image 核：Xcode 26 起 Metal 工具链要单独下载，每台编译的机器都得装（2026-10-30 实测）；只补一小块，CPU 够快。
// ponytail: 导出会话会把音频也重新编码成 AAC（高质量，听不出来）；要原样带过音频，得换成 AVAssetReader / Writer 自己搬

import AVFoundation
import CoreImage
import Foundation
import UniformTypeIdentifiers

nonisolated enum VideoDelogo {
  enum Failure: LocalizedError {
    case noVideo
    case exportFailed(String)

    var errorDescription: String? {
      switch self {
      case .noVideo: "这个文件里没有视频画面。"
      case .exportFailed(let reason): "导出没成功：" + reason
      }
    }
  }

  /// 羽化带宽度（像素）
  static let band = 4

  /// 拖进来的东西里哪些是视频（按扩展名）
  static func isVideo(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
  }

  /// 第一帧（已经按视频的方向转正），框台标用
  static func firstFrame(of url: URL) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: .zero).image
  }

  // MARK: 补像素（纯函数）

  /// pixels：RGBA 8 位、第 0 行在最上面的一小块；rect：要补的框（在这一小块里的坐标）。
  /// 框外要留至少 band + 1 圈，边上的像素从那里取；块碰到画面边时取不到的就用最近的
  static func fill(_ pixels: inout [UInt8], width: Int, height: Int, rect: CGRect, band: Int) {
    let (x0, y0) = (Int(rect.minX), Int(rect.minY))
    let (x1, y1) = (Int(rect.maxX) - 1, Int(rect.maxY) - 1)
    let (left, right) = (max(x0 - band, 0), min(x1 + band, width - 1))
    let (top, bottom) = (max(y0 - band, 0), min(y1 + band, height - 1))
    guard left <= right, top <= bottom else { return }
    let source = pixels
    func at(_ x: Int, _ y: Int, _ channel: Int) -> Double {
      Double(source[(min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4 + channel])
    }
    for y in top...bottom {
      for x in left...right {
        let weights = [
          1 / Double(x - left + 1), 1 / Double(right - x + 1), 1 / Double(y - top + 1),
          1 / Double(bottom - y + 1),
        ]
        let edges = [(left - 1, y), (right + 1, y), (x, top - 1), (x, bottom + 1)]
        // 框里全换；羽化带里按离框的距离从「全换」过渡到「不换」
        let outside = max(max(x0 - x, x - x1, 0), max(y0 - y, y - y1, 0))
        let keep = band > 0 ? max(0, 1 - Double(outside) / Double(band)) : 1
        for channel in 0..<3 {
          let filled =
            zip(weights, edges).map { $0 * at($1.0, $1.1, channel) }.reduce(0, +)
            / weights.reduce(0, +)
          let value = at(x, y, channel) * (1 - keep) + filled * keep
          pixels[(y * width + x) * 4 + channel] = UInt8(max(0, min(255, value.rounded())))
        }
      }
    }
  }

  // MARK: 导出

  /// rects：在第一帧上的像素坐标，左上角为原点。progress 在后台线程上报 0–1
  @concurrent static func export(
    _ source: URL, rects: [CGRect], progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw Failure.noVideo
    }
    let context = CIContext()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
      let frame = request.sourceImage
      var output = frame
      for rect in rects {
        // 左上原点 → Core Image 的左下原点；读回框外 band + 1 圈
        let box = CGRect(
          x: rect.minX, y: frame.extent.height - rect.maxY, width: rect.width, height: rect.height
        ).integral
        let area = box.insetBy(dx: -CGFloat(band + 1), dy: -CGFloat(band + 1))
          .intersection(frame.extent).integral
        guard area.width > 0, area.height > 0 else { continue }
        let (width, height) = (Int(area.width), Int(area.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
          frame, toBitmap: &pixels, rowBytes: width * 4, bounds: area, format: .RGBA8,
          colorSpace: space)
        // 读回来的第 0 行是这块的最上面
        let inside = CGRect(
          x: box.minX - area.minX, y: area.maxY - box.maxY, width: box.width, height: box.height)
        fill(&pixels, width: width, height: height, rect: inside, band: band)
        let patch = CIImage(
          bitmapData: Data(pixels), bytesPerRow: width * 4, size: area.size, format: .RGBA8,
          colorSpace: space
        ).transformed(by: CGAffineTransform(translationX: area.minX, y: area.minY))
        output = patch.composited(over: output)
      }
      request.finish(with: output.cropped(to: frame.extent), context: context)
    }

    let codec = try await track.load(.formatDescriptions).first.map(
      CMFormatDescriptionGetMediaSubType)
    let preset =
      codec == kCMVideoCodecType_HEVC
      ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw Failure.exportFailed("不支持这个视频。")
    }
    session.videoComposition = composition
    let ext = source.pathExtension.lowercased()
    let type: AVFileType = ext == "mp4" ? .mp4 : ext == "m4v" ? .m4v : .mov
    let target = source.deletingPathExtension()
      .appendingPathExtension(type == .mov ? "mov" : ext).adding("-去水印").uniqued()

    // 只把进度的序列带进任务：会话本身不是 Sendable
    let updates = session.states(updateInterval: 0.2)
    let watcher = Task {
      for await state in updates {
        if case .exporting(let step) = state { progress(step.fractionCompleted) }
      }
    }
    defer { watcher.cancel() }
    do {
      try await session.export(to: target, as: type)
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw Failure.exportFailed(error.localizedDescription)
    }
    return target
  }
}
