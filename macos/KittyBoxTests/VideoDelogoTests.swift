// VideoDelogo：补像素的纯函数（纯色底上框里补回底色、框外不动、羽化带在中间）；再真的造一段带白色台标的小视频，
// 框上导出，台标那里变回底色、文件名是「原名-去水印」；带 AAC 音轨的视频导出后音频一包不差（原样搬过去，没重新编码，D6）。
// 竖拍的（转 90°）框在转正后的第一帧上、补的也是那里，HEVC 出 HEVC；开头空着半秒的视频读得出第一帧、导出来第一帧不是黑的；
// 导出能停、不留半个文件；导出时再拖进别的视频不换（不然进度和结果落到新视频上），停下回到能接着框。

import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import KittyBox

/// 造一段 160 × 120（可以给别的大小）、10 帧、1 秒的视频：蓝底，右上角 (120, 8) 起 30 × 16 的白块当台标
/// （截图自检、视频转换也用）
/// firstAt：第一帧放在几秒（有的视频能显示的第一帧不在 0）；transform：播放时怎么转（竖拍的转 90°）
func makeTestVideo(
  at url: URL, width: Int = 160, height: Int = 120, firstAt: Double = 0,
  codec: AVVideoCodecType = .h264, transform: CGAffineTransform = .identity
) async throws {
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height])
  input.transform = transform
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
  writer.add(input)
  #expect(writer.startWriting())
  writer.startSession(atSourceTime: .zero)
  for frame in 0..<10 {
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(
      to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<height {
      for x in 0..<width {
        let logo = (120..<150).contains(x) && (8..<24).contains(y)
        let index = y * rowBytes + x * 4
        (base[index], base[index + 1], base[index + 2], base[index + 3]) =
          logo ? (255, 255, 255, 255) : (200, 120, 40, 255)  // BGRA：蓝底
      }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    #expect(
      adaptor.append(
        pixels,
        withPresentationTime: CMTime(seconds: firstAt + Double(frame) / 10, preferredTimescale: 600)
      ))
  }
  input.markAsFinished()
  await writer.finishWriting()
  #expect(writer.status == .completed)
}

/// 在 makeTestVideo 那段视频上配 1 秒 440 Hz 的 AAC 音轨，合成一个 .mov（音视频都原样拼进去；视频转换也用）
func makeTestVideoWithSound(at url: URL, in root: URL) async throws {
  let picture = root.appending(path: "无声.mov")
  try await makeTestVideo(at: picture)
  let sound = root.appending(path: "声音.m4a")
  do {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let file = try AVAudioFile(
      forWriting: sound,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
      ])
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    let samples = try #require(buffer.floatChannelData)[0]
    for index in 0..<44_100 { samples[index] = sin(Float(index) * 2 * .pi * 440 / 44_100) * 0.3 }
    try file.write(from: buffer)
  }
  let mix = AVMutableComposition()
  let pictureAsset = AVURLAsset(url: picture)
  let soundAsset = AVURLAsset(url: sound)
  let range = CMTimeRange(start: .zero, duration: try await pictureAsset.load(.duration))
  let video = try #require(
    mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
  try video.insertTimeRange(
    range, of: try #require(try await pictureAsset.loadTracks(withMediaType: .video).first),
    at: .zero)
  let audio = try #require(
    mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
  let soundRange = CMTimeRange(
    start: .zero, duration: min(try await soundAsset.load(.duration), range.duration))
  try audio.insertTimeRange(
    soundRange, of: try #require(try await soundAsset.loadTracks(withMediaType: .audio).first),
    at: .zero)
  let session = try #require(
    AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetPassthrough))
  try await session.export(to: url, as: .mov)
}

/// 竖拍（同 iPhone）：编码的帧是横的，播放时顺时针转 90°；height 是编码的帧高
func portrait(height: Int) -> CGAffineTransform {
  CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
}

/// 音轨的编码和全部压缩包的字节数（不解码，原样读）
private func audioPackets(of url: URL) async throws -> (codec: FourCharCode, bytes: Int) {
  let asset = AVURLAsset(url: url)
  let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
  let codec = try #require(
    try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType))
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
  reader.add(output)
  #expect(reader.startReading())
  var bytes = 0
  while let buffer = output.copyNextSampleBuffer() {
    bytes += CMSampleBufferGetTotalSampleSize(buffer)
  }
  return (codec, bytes)
}

struct VideoDelogoTests {
  @Test func fillMatchesSurroundings() {
    let (width, height) = (40, 30)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      pixels[index] = 30
      pixels[index + 1] = 90
      pixels[index + 2] = 160
      pixels[index + 3] = 255
    }
    // 白色台标 (15, 10) 起 10 × 6
    for y in 10..<16 {
      for x in 15..<25 { for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 255 } }
    }
    let before = pixels
    VideoDelogo.fill(
      &pixels, width: width, height: height, rect: CGRect(x: 15, y: 10, width: 10, height: 6),
      band: 3)

    func rgb(_ x: Int, _ y: Int) -> [UInt8] {
      Array(pixels[(y * width + x) * 4..<(y * width + x) * 4 + 3])
    }
    #expect(rgb(20, 12) == [30, 90, 160])
    #expect(rgb(15, 10) == [30, 90, 160])
    // 框外 band 之外不动
    #expect(rgb(5, 5) == Array(before[(5 * width + 5) * 4..<(5 * width + 5) * 4 + 3]))
    #expect(rgb(11, 12) == [30, 90, 160])
  }

  /// 图上 (x, y) 处的 RGB（y 从上往下数）
  private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(
      image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    return [Int(data[0]), Int(data[1]), Int(data[2])]
  }

  @Test func exportRemovesLogo() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "录屏.mov")
    try await makeTestVideo(at: source)

    let before = try await VideoDelogo.firstFrame(of: source)
    #expect(rgb(before, 135, 15).allSatisfy { $0 > 230 })

    let output = try await VideoDelogo.export(
      source, rects: [CGRect(x: 118, y: 6, width: 34, height: 20)], progress: { _ in })
    #expect(output.lastPathComponent == "录屏-去水印.mov")
    let after = try await VideoDelogo.firstFrame(of: output)
    let background = rgb(after, 60, 80)
    let logo = rgb(after, 135, 15)
    // 有损编码：和底色差不多就算补上了
    #expect(zip(logo, background).allSatisfy { abs($0 - $1) < 24 }, "\(logo) vs \(background)")
  }

  @Test func audioIsCopiedAsIs() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "带声音.mov")
    try await makeTestVideoWithSound(at: source, in: root)

    let output = try await VideoDelogo.export(
      source, rects: [CGRect(x: 118, y: 6, width: 34, height: 20)], progress: { _ in })
    let before = try await audioPackets(of: source)
    let after = try await audioPackets(of: output)
    #expect(before.codec == kAudioFormatMPEG4AAC)
    #expect(after.codec == before.codec)
    // 重新编码过的话字节数几乎不可能一样
    #expect(after.bytes == before.bytes)
  }

  /// 能显示的第一帧在 0.033 秒（用户的 tonight.mp4 就是这样）：照样读得出第一帧（原来卡死在 0 上读不出、一直转圈）；
  /// 开头空着半秒的（放宽一秒也读不出）同样读得出，导出来的第一帧是画面、不是视频合成给空段垫的黑帧
  @Test(arguments: [0.033, 0.5]) func firstFrameNotAtZero(_ firstAt: Double) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "晚一点.mp4")
    try await makeTestVideo(at: source, firstAt: firstAt)
    let frame = try await VideoDelogo.firstFrame(of: source)
    #expect(frame.width == 160 && frame.height == 120)
    // 视频转换表格里那一行的小图也取得出（原来在 0 秒取，空着的那半秒取不出、小图是空的）
    #expect(await Thumbnail.firstFrame(source, maxPixel: 64) != nil)

    let output = try await VideoDelogo.export(
      source, rects: [CGRect(x: 118, y: 6, width: 34, height: 20)], progress: { _ in })
    let after = rgb(try await VideoDelogo.firstFrame(of: output), 60, 80)
    #expect(zip(after, rgb(frame, 60, 80)).allSatisfy { abs($0 - $1) < 24 }, "\(after)")
  }

  /// 竖拍的：第一帧转正了（120 × 160），框在转正后的画面上，导出来补的也是那一处；HEVC 的导出来还是 HEVC
  @Test func portraitHEVC() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "竖拍.mov")
    try await makeTestVideo(at: source, codec: .hevc, transform: portrait(height: 120))

    let before = try await VideoDelogo.firstFrame(of: source)
    #expect(before.width == 120 && before.height == 160)
    // 编码的帧上 (120, 8) 起 30 × 16 的白块，转 90° 后在 (96, 120) 起 16 × 30
    #expect(rgb(before, 104, 135).allSatisfy { $0 > 230 })
    let output = try await VideoDelogo.export(
      source, rects: [CGRect(x: 94, y: 118, width: 20, height: 34)], progress: { _ in })
    let after = try await VideoDelogo.firstFrame(of: output)
    #expect(after.width == 120 && after.height == 160)
    let (logo, background) = (rgb(after, 104, 135), rgb(after, 40, 40))
    #expect(zip(logo, background).allSatisfy { abs($0 - $1) < 24 }, "\(logo) vs \(background)")
    let track = try #require(
      try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
    let codec = try await track.load(.formatDescriptions).first.map(
      CMFormatDescriptionGetMediaSubType)
    #expect(codec == kCMVideoCodecType_HEVC)
  }

  /// 导出到一半停下：报的是停下（不是「导出没成功」），旁边不留导了一半的文件
  @Test func stopLeavesNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "录屏.mov")
    try await makeTestVideo(at: source)
    // 写进第一帧、报第一次进度时停下（进度就在导出的任务里报）
    let exporting = Task {
      try await VideoDelogo.export(source, rects: [CGRect(x: 118, y: 6, width: 34, height: 20)]) {
        _ in withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    await #expect(throws: CancellationError.self) { try await exporting.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["录屏.mov"])
  }

  /// 页面的模型：导出时再拖进别的视频不换（不然导出的进度、结果落到新视频上）；「停止」后回到能接着框，不留文件
  @MainActor @Test func modelStopsAndKeepsItsVideo() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (first, second) = (root.appending(path: "一.mov"), root.appending(path: "二.mov"))
    try await makeTestVideo(at: first)
    try await makeTestVideo(at: second)
    let model = VideoMarkModel()
    model.load(first)
    while model.busy { try await Task.sleep(for: .milliseconds(10)) }
    try #require(model.frame != nil)
    model.rects = [CGRect(x: 118, y: 6, width: 34, height: 20)]

    model.export()
    #expect(model.busy)
    model.load(second)
    #expect(model.source == first && model.frame != nil && model.rects.count == 1)
    model.stop()
    while model.busy { try await Task.sleep(for: .milliseconds(10)) }
    guard case .idle = model.state else {
      Issue.record("停下后是 \(model.state)")
      return
    }
    #expect(model.rects.count == 1)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["一.mov", "二.mov"])
  }
}
