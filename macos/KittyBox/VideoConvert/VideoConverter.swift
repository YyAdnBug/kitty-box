// 视频转换（M6）：一段视频转成 MP4（H.264）、MP4（HEVC）、动图 GIF，或只要声音（M4A）；能缩到 1080p / 720p / 480p
// （按短边算，只缩不放）。结果放在原视频旁边、换扩展名，重名加「 2」，原视频不动。
// - MP4：系统的导出会话（最高质量预设，H.264 或 HEVC），要缩小时加一个视频合成按比例缩每一帧；声音一起转。
// - GIF：每秒 10 帧、长边最多 480、最多取前 15 秒（ponytail: GIF 没有帧间压缩，再长再大文件就上百 MB；要更长换 MP4），
//   一直循环。
// - M4A：系统的「Apple M4A」预设，只留声音；没有声音的视频说一声。
// 进度在后台线程上报 0–1；任务被取消时停下、删掉写了一半的文件。

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum VideoConverter {
  enum Target: String, CaseIterable {
    case h264, hevc, gif, audio

    var title: String {
      switch self {
      case .h264: "MP4（H.264）"
      case .hevc: "MP4（HEVC）"
      case .gif: "动图 GIF"
      case .audio: "只要声音（M4A）"
      }
    }

    var fileExtension: String {
      switch self {
      case .h264, .hevc: "mp4"
      case .gif: "gif"
      case .audio: "m4a"
      }
    }
  }

  /// 缩到多大：按短边（横屏 1080p = 高 1080）；original 不缩
  enum Size: Int, CaseIterable {
    case original = 0
    case p1080 = 1080
    case p720 = 720
    case p480 = 480

    var title: String { self == .original ? "原尺寸" : "\(rawValue)p" }
  }

  enum Failure: LocalizedError {
    case noVideo
    case noAudio
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .noVideo: "这个文件里没有视频画面。"
      case .noAudio: "这段视频没有声音。"
      case .failed(let reason): "转换没成功：" + reason
      }
    }
  }

  /// GIF：每秒几帧、长边最多多少、最多取前几秒
  static let gifFrameRate = 10.0
  static let gifMaxSide = 480.0
  static let gifMaxSeconds = 15.0

  /// 原视频旁边、换扩展名，重名加「 2」
  static func output(for source: URL, target: Target) -> URL {
    source.deletingPathExtension().appendingPathExtension(target.fileExtension).uniqued()
  }

  @concurrent static func convert(
    _ source: URL, to target: Target, size: Size,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    let asset = AVURLAsset(url: source)
    let output = output(for: source, target: target)
    do {
      switch target {
      case .gif: try await gif(asset, to: output, progress: progress)
      case .h264, .hevc, .audio:
        try await export(asset, target: target, size: size, to: output, progress: progress)
      }
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw error
    }
    return output
  }

  /// 缩小后的尺寸：短边缩到 limit（只缩不放），宽高取偶数（编码器要）
  static func scaled(_ size: CGSize, shortSide limit: Int) -> CGSize? {
    let short = min(size.width, size.height)
    guard limit > 0, short > CGFloat(limit) else { return nil }
    let ratio = CGFloat(limit) / short
    func even(_ value: CGFloat) -> CGFloat { (value * ratio / 2).rounded() * 2 }
    return CGSize(width: even(size.width), height: even(size.height))
  }

  // MARK: MP4、M4A

  private static func export(
    _ asset: AVURLAsset, target: Target, size: Size, to output: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let preset: String
    switch target {
    case .hevc: preset = AVAssetExportPresetHEVCHighestQuality
    case .audio: preset = AVAssetExportPresetAppleM4A
    default: preset = AVAssetExportPresetHighestQuality
    }
    if target == .audio {
      guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
        throw Failure.noAudio
      }
    } else {
      guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
        throw Failure.noVideo
      }
    }
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw Failure.failed("不支持这个视频。")
    }
    if target != .audio, size != .original,
      let track = try await asset.loadTracks(withMediaType: .video).first
    {
      // 转正之后的画面大小（竖拍的宽高对调）
      let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
      let oriented = natural.applying(transform)
      let shown = CGSize(width: abs(oriented.width), height: abs(oriented.height))
      if let smaller = scaled(shown, shortSide: size.rawValue) {
        let ratio = smaller.width / shown.width
        let scaling = try await AVMutableVideoComposition.videoComposition(with: asset) {
          request in
          request.finish(
            with: request.sourceImage.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio)),
            context: nil)
        }
        scaling.renderSize = smaller
        session.videoComposition = scaling
      }
    }
    // 只把进度的序列带进任务：会话本身不是 Sendable
    let updates = session.states(updateInterval: 0.2)
    let watcher = Task {
      for await state in updates {
        if case .exporting(let step) = state { progress(step.fractionCompleted) }
      }
    }
    defer { watcher.cancel() }
    do {
      try await session.export(to: output, as: target == .audio ? .m4a : .mp4)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      throw Failure.failed(error.localizedDescription)
    }
  }

  // MARK: GIF

  private static func gif(
    _ asset: AVURLAsset, to output: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw Failure.noVideo }
    let seconds = min(try await asset.load(.duration).seconds, gifMaxSeconds)
    let count = max(Int(seconds * gifFrameRate), 1)
    let times = (0..<count).map {
      CMTime(seconds: Double($0) / gifFrameRate, preferredTimescale: 600)
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: gifMaxSide, height: gifMaxSide)
    let tolerance = CMTime(seconds: 0.5 / gifFrameRate, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance

    guard
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.gif.identifier as CFString, count, nil)
    else { throw Failure.failed("写不了 GIF。") }
    let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
    CGImageDestinationSetProperties(destination, loop as CFDictionary)
    let frame = [
      kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / gifFrameRate]
    ]
    var done = 0
    for await result in generator.images(for: times) {
      try Task.checkCancellation()
      guard let image = try? result.image else { continue }
      CGImageDestinationAddImage(destination, image, frame as CFDictionary)
      done += 1
      progress(Double(done) / Double(count))
    }
    try Task.checkCancellation()
    guard done > 0, CGImageDestinationFinalize(destination) else {
      throw Failure.failed("一帧都没取出来。")
    }
  }
}
