// VideoConverter：测试视频转成 H.264 的 MP4（能读出画面）、缩到 480p 时按短边缩且宽高是偶数、转 GIF 有一串帧且一直循环、
// 只要声音时出 M4A 只有音轨、没声音的视频转 M4A 说一声；剪一段（0.3–0.8 秒）只转这一段，GIF 也只取这一段；缩小尺寸的纯函数；
// 竖拍的缩到 480p 是转正后的 480 × 854、画面方向对；GIF 转到一半停下旁边什么都不留。

import AVFoundation
import Foundation
import ImageIO
import Testing

@testable import KittyBox

struct VideoConverterTests {
  private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    init() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
  }

  @Test func scaledSize() {
    #expect(
      VideoConverter.scaled(CGSize(width: 1920, height: 1080), shortSide: 720)
        == CGSize(width: 1280, height: 720))
    #expect(
      VideoConverter.scaled(CGSize(width: 1080, height: 1920), shortSide: 480)
        == CGSize(width: 480, height: 854))
    #expect(VideoConverter.scaled(CGSize(width: 640, height: 360), shortSide: 720) == nil)
  }

  @Test func toMP4AndSmaller() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "录屏.mov")
    try await makeTestVideo(at: source, width: 1280, height: 720)

    let mp4 = try await VideoConverter.convert(source, to: .h264, size: .original) { _ in }
    #expect(mp4.lastPathComponent == "录屏.mp4")
    #expect(try await VideoDelogo.firstFrame(of: mp4).width == 1280)

    let small = try await VideoConverter.convert(source, to: .h264, size: .p480) { _ in }
    #expect(small.lastPathComponent == "录屏 2.mp4")
    let frame = try await VideoDelogo.firstFrame(of: small)
    #expect(frame.width == 854 && frame.height == 480)
  }

  /// 竖拍（编码 1280 × 720、播放时转 90°）缩到 480p：按转正后的短边（宽）缩成 480 × 854，台标在转正后的右上
  @Test func portraitSmaller() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "竖拍.mov")
    try await makeTestVideo(at: source, width: 1280, height: 720, transform: portrait(height: 720))
    let small = try await VideoConverter.convert(source, to: .h264, size: .p480) { _ in }
    let frame = try await VideoDelogo.firstFrame(of: small)
    #expect(frame.width == 480 && frame.height == 854)
    // 编码的帧上 (120, 8) 起 30 × 16 的白块：转正后在 (696, 120) 起 16 × 30，缩 2/3
    let context = try #require(
      CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.draw(frame, in: CGRect(x: -469, y: 90 - 854 + 1, width: 480, height: 854))
    let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    #expect((0..<3).allSatisfy { pixel[$0] > 220 }, "\((0..<3).map { pixel[$0] })")
  }

  /// 转 GIF 到一半停下：报的是停下，旁边什么都不留（原来系统会留一个藏起来的「.猫.gif-xxxx」）
  @Test func stopLeavesNothing() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "猫.mov")
    try await makeTestVideo(at: source)
    // 取出第一帧、报第一次进度时停下（GIF 的进度就在转换的任务里报）
    let converting = Task {
      try await VideoConverter.convert(source, to: .gif, size: .original) { _ in
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    await #expect(throws: CancellationError.self) { try await converting.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path) == ["猫.mov"])
  }

  @Test func toGIF() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "猫.mov")
    try await makeTestVideo(at: source)
    let gif = try await VideoConverter.convert(source, to: .gif, size: .original) { _ in }
    let image = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
    #expect(CGImageSourceGetCount(image) >= 8)
    let properties = CGImageSourceCopyProperties(image, nil) as? [CFString: Any]
    let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    #expect(gifProperties?[kCGImagePropertyGIFLoopCount] as? Int == 0)
  }

  @Test func audioOnly() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "带声音.mov")
    try await makeTestVideoWithSound(at: source, in: box.root)
    let m4a = try await VideoConverter.convert(source, to: .audio, size: .original) { _ in }
    #expect(m4a.pathExtension == "m4a")
    let asset = AVURLAsset(url: m4a)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)

    let silent = box.root.appending(path: "无声的.mov")
    try await makeTestVideo(at: silent)
    await #expect(throws: VideoConverter.Failure.self) {
      try await VideoConverter.convert(silent, to: .audio, size: .original) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: box.root.appending(path: "无声的.m4a").path))
  }

  @Test func onlyTheTrimmedPart() async throws {
    let box = try Sandbox()
    let source = box.root.appending(path: "片段.mov")
    try await makeTestVideo(at: source)
    let mp4 = try await VideoConverter.convert(source, to: .h264, size: .original, range: 0.3...0.8)
    { _ in }
    let length = try await AVURLAsset(url: mp4).load(.duration).seconds
    #expect(abs(length - 0.5) < 0.15, "\(length)")

    let gif = try await VideoConverter.convert(source, to: .gif, size: .original, range: 0.3...0.8)
    { _ in }
    let frames = CGImageSourceGetCount(try #require(CGImageSourceCreateWithURL(gif as CFURL, nil)))
    #expect(frames == 5)
  }
}
