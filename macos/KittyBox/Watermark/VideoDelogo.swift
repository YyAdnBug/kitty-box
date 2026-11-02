// 视频固定台标（D4–D6）：在画面上框出台标（可以框几处；拖进度条选哪一帧都行，台标不动、框在哪一帧上都一样），
// AVFoundation 逐帧交给 Core Image；每一帧只把框外一圈的小块读回来，
// 框里的每个像素按到框外左右上下四条边的距离、对边上紧挨着的像素加权补上（越近越重，思路同 ffmpeg 的 delogo，代码自己写），
// 框外再留一圈羽化带慢慢过渡，贴回画面。结果「原名-去水印」放在原视频旁边。
// 导出（D6）：AVAssetReader 按视频合成读出补好的帧、AVAssetWriter 重新编码，编码跟原视频走（HEVC 出 HEVC，其余 H.264），
// 码率按原视频的 1.25 倍（再编一次会丢一点细节，多给一点码率补回来，体积和原来差不多）；音频一包一包原样搬过去、不重新编码
// （容器装不下原来的音频格式时才转成 AAC）；视频的元数据（拍摄时间、地点…）带过去。不用导出会话：它没法只重编视频、音频原样带。
// 不用 Metal 写 Core Image 核：Xcode 26 起 Metal 工具链要单独下载，每台编译的机器都得装（2026-10-30 实测）；只补一小块，CPU 够快。

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

  /// 第一帧（已经按视频的方向转正），框台标用。往后放宽一秒：不少视频能显示的第一帧不在 0（比如 0.033 秒），
  /// 卡死在 0 上系统回「无法打开」（-11832，2026-10-30 用户的 tonight.mp4）
  static func firstFrame(of url: URL) async throws -> CGImage {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw Failure.noVideo
    }
    return try await generator.image(at: firstShown(track)).image
  }

  /// 画面从几秒开始有：开头空着一段（剪过的视频，播放器那段是黑的）时是空段之后。
  /// 空段里放宽多少都取不出帧（2026-11-02 实测空 0.5 秒照样「无法打开」）
  static func firstShown(_ track: AVAssetTrack) async throws -> CMTime {
    try await track.load(.segments).first { !$0.isEmpty }?.timeMapping.target.start ?? .zero
  }

  /// 进度条拖得到的一段（秒）：从第一段有画面的地方（firstShown）到片尾
  static func span(of url: URL) async throws -> ClosedRange<Double> {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw Failure.noVideo
    }
    let start = try await firstShown(track).seconds
    return start...max(start, try await asset.load(.duration).seconds)
  }

  /// 进度条拖到的那一刻的画面（同 firstFrame 按视频的方向转正）：片头黑着、台标还没出来的视频往后拖一点再框。
  /// 前后各放宽 0.1 秒：附近有关键帧就用它、少解几帧，拖得跟手；片尾那一刻没有帧也取得到。
  /// 放得更宽会跳到一秒外的关键帧、和进度条对不上（2026-11-02 实测）
  static func frame(of url: URL, at seconds: Double) async throws -> CGImage {
    // 每次新开一个 asset（同 firstFrame）：传进来的 asset 不能交给生成器的 @concurrent 取图（Swift 6 报数据竞争）
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
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
        // 到左右上下四条边的距离的倒数当权重（每帧每个像素都跑：只用局部变量，不建数组）
        let (toLeft, toRight) = (1 / Double(x - left + 1), 1 / Double(right - x + 1))
        let (toTop, toBottom) = (1 / Double(y - top + 1), 1 / Double(bottom - y + 1))
        let total = toLeft + toRight + toTop + toBottom
        // 框里全换；羽化带里按离框的距离从「全换」过渡到「不换」
        let outside = max(max(x0 - x, x - x1, 0), max(y0 - y, y - y1, 0))
        let keep = band > 0 ? max(0, 1 - Double(outside) / Double(band)) : 1
        for channel in 0..<3 {
          let filled =
            (toLeft * at(left - 1, y, channel) + toRight * at(right + 1, y, channel)
              + toTop * at(x, top - 1, channel) + toBottom * at(x, bottom + 1, channel)) / total
          let value = at(x, y, channel) * (1 - keep) + filled * keep
          pixels[(y * width + x) * 4 + channel] = UInt8(max(0, min(255, value.rounded())))
        }
      }
    }
  }

  // MARK: 导出

  /// rects：在转正后的画面上的像素坐标（每一帧一样大），左上角为原点。progress 在后台线程上报 0–1
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

    let ext = source.pathExtension.lowercased()
    let type: AVFileType = ext == "mp4" ? .mp4 : ext == "m4v" ? .m4v : .mov
    let target = source.deletingPathExtension()
      .appendingPathExtension(type == .mov ? "mov" : ext).adding("-去水印").uniqued()
    do {
      try await write(asset, video: track, composition: composition, to: target, as: type) {
        progress($0)
      }
    } catch {
      try? FileManager.default.removeItem(at: target)
      // 停下的不算失败
      if error is CancellationError { throw error }
      throw Failure.exportFailed(error.localizedDescription)
    }
    return target
  }

  /// 读出补好的帧重新编码，音频原样搬；一边搬一边报进度（按视频帧的时间）
  private static func write(
    _ asset: AVURLAsset, video track: AVAssetTrack, composition: AVVideoComposition,
    to target: URL, as type: AVFileType, progress: (Double) -> Void
  ) async throws {
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: target, fileType: type)
    writer.metadata = (try? await asset.load(.metadata)) ?? []

    let frames = AVAssetReaderVideoCompositionOutput(
      videoTracks: [track],
      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    frames.videoComposition = composition
    reader.add(frames)
    let codec = try await track.load(.formatDescriptions).first.map(
      CMFormatDescriptionGetMediaSubType)
    // ponytail: 码率按原视频的 1.25 倍估；要逐帧保真再换成按质量编码
    let rate = try await track.load(.estimatedDataRate)
    let picture = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: codec == kCMVideoCodecType_HEVC
          ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
        AVVideoWidthKey: Int(composition.renderSize.width),
        AVVideoHeightKey: Int(composition.renderSize.height),
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: max(Int(Double(rate) * 1.25), 2_000_000)
        ],
      ])
    picture.expectsMediaDataInRealTime = false
    writer.add(picture)
    var pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)] = [(frames, picture)]

    for audio in try await asset.loadTracks(withMediaType: .audio) {
      let packets = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
      let hint = try await audio.load(.formatDescriptions).first
      var sound = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
      if !writer.canAdd(sound) {
        // 容器装不下原来的音频格式（比如 mp4 里放不了某些 PCM）：解出来转成 AAC
        let decoded = AVAssetReaderTrackOutput(
          track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        sound = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
          ])
        guard reader.canAdd(decoded), writer.canAdd(sound) else { continue }
        reader.add(decoded)
        writer.add(sound)
        pairs.append((decoded, sound))
        continue
      }
      guard reader.canAdd(packets) else { continue }
      reader.add(packets)
      writer.add(sound)
      pairs.append((packets, sound))
    }

    // 开头空着的那一段（firstShown）视频合成照样出帧、是黑的：不要，结果开头同原视频一样空着，第一帧不是黑的
    let shown = try await firstShown(track)
    guard reader.startReading() else { throw reader.error ?? Failure.exportFailed("读不了这段视频。") }
    guard writer.startWriting() else { throw writer.error ?? Failure.exportFailed("写不了结果。") }
    writer.startSession(atSourceTime: .zero)
    let duration = try await asset.load(.duration).seconds
    var percent = -1

    // 停下或出错：两头都收掉，写了一半的文件 AVAssetWriter 自己删
    var finished = false
    defer {
      if !finished {
        reader.cancelReading()
        writer.cancelWriting()
      }
    }

    // 轮流往各条轨道里搬：哪条能收就搬一包，搬完了就收尾；都收不下时等一下（写入的一方在编码）
    while !pairs.isEmpty {
      try Task.checkCancellation()
      var moved = false
      for index in pairs.indices.reversed() where pairs[index].input.isReadyForMoreMediaData {
        let (output, input) = pairs[index]
        moved = true
        guard let buffer = output.copyNextSampleBuffer() else {
          input.markAsFinished()
          pairs.remove(at: index)
          continue
        }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if input === picture, time < shown { continue }
        guard input.append(buffer) else { throw writer.error ?? Failure.exportFailed("写不进去。") }
        // 按整百分比报（一共最多 100 次，不是每帧都往界面丢一次）
        if input === picture, duration > 0 {
          let done = Int(min(time.seconds / duration, 1) * 100)
          if done > percent {
            percent = done
            progress(Double(done) / 100)
          }
        }
      }
      if !moved { try await Task.sleep(for: .milliseconds(2)) }
    }
    if reader.status == .failed { throw reader.error ?? Failure.exportFailed("读到一半出错了。") }
    finished = true
    await writer.finishWriting()
    if writer.status != .completed {
      throw writer.error ?? Failure.exportFailed("写到一半出错了。")
    }
  }
}
