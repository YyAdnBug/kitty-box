// VideoDelogo：补像素的纯函数（纯色底上框里补回底色、框外不动、羽化带在中间）；再真的造一段带白色台标的小视频，
// 框上导出，台标那里变回底色、文件名是「原名-去水印」。

import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import KittyBox

/// 造一段 160 × 120、10 帧的视频：蓝底，右上角 (120, 8) 起 30 × 16 的白块当台标（截图自检也用）
func makeTestVideo(at url: URL) async throws {
  let (width, height) = (160, 120)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
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
      adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
  }
  input.markAsFinished()
  await writer.finishWriting()
  #expect(writer.status == .completed)
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
}
