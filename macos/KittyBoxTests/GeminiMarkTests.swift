// GeminiMark：在有纹理的图上照 Gemini 的做法盖上星标（水印 = α·255 + (1 − α)·原图），认出位置、去掉后
// 每个像素和原图差不超过 3（α 不到 3/255 的边缘像素上游当量化噪声不动，那里本来就差 2–3）；几种候选都认得对；
// 没盖的认不出、不出文件；结果另存成「原名-去水印」。候选位置只看边距，所以都用 512 的图。

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import KittyBox

struct GeminiMarkTests {
  /// 有纹理的底图（纯色的话相关性算不出来）
  private func canvas(_ width: Int, _ height: Int) -> GeminiMark.Pixels {
    var data = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let index = (y * width + x) * 4
        data[index] = UInt8(60 + 40 * sin(Double(x) / 13))
        data[index + 1] = UInt8(80 + 30 * cos(Double(y) / 17))
        data[index + 2] = UInt8(100 + 20 * sin(Double(x + y) / 23))
      }
    }
    return GeminiMark.Pixels(width: width, height: height, data: data)
  }

  /// 照 Gemini 的做法盖白色星标
  private func stamp(_ pixels: GeminiMark.Pixels, with candidate: GeminiMark.Candidate)
    throws -> GeminiMark.Pixels
  {
    var marked = pixels
    let alpha = try #require(GeminiMark.alphaMap(candidate))
    let (x0, y0) = (
      pixels.width - candidate.margin - candidate.size,
      pixels.height - candidate.margin - candidate.size
    )
    for row in 0..<candidate.size {
      for column in 0..<candidate.size {
        let a = Double(alpha[row * candidate.size + column])
        let index = ((y0 + row) * pixels.width + x0 + column) * 4
        for channel in 0..<3 {
          let value = a * 255 + (1 - a) * Double(pixels.data[index + channel])
          marked.data[index + channel] = UInt8(value.rounded())
        }
      }
    }
    return marked
  }

  @Test(arguments: [
    (GeminiMark.candidates[0], 512, 512), (GeminiMark.candidates[1], 512, 512),
    (GeminiMark.candidates[2], 512, 512), (GeminiMark.candidates[4], 512, 512),
  ])
  func findsAndRemoves(candidate: GeminiMark.Candidate, width: Int, height: Int) throws {
    let original = canvas(width, height)
    var marked = try stamp(original, with: candidate)
    let match = try #require(GeminiMark.find(in: marked))
    #expect(match.candidate == candidate)

    GeminiMark.remove(match, from: &marked)
    let worst = zip(original.data, marked.data).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(worst <= 3)
  }

  @Test func leavesUnmarkedAlone() {
    #expect(GeminiMark.find(in: canvas(512, 512)) == nil)
  }

  @Test func savesNextToOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func write(_ pixels: GeminiMark.Pixels, to url: URL) throws {
      var data = pixels.data
      let image = try #require(
        data.withUnsafeMutableBytes {
          CGContext(
            data: $0.baseAddress, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
            bytesPerRow: pixels.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        })
      let destination = try #require(
        CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      #expect(CGImageDestinationFinalize(destination))
    }

    let original = canvas(512, 512)
    let source = root.appending(path: "Gemini_Generated_Image.png")
    try write(try stamp(original, with: GeminiMark.candidates[1]), to: source)
    let output = try await GeminiMark.clean(source)
    #expect(output.lastPathComponent == "Gemini_Generated_Image-去水印.png")

    let image = try #require(
      CGImageSourceCreateWithURL(output as CFURL, nil).flatMap {
        CGImageSourceCreateImageAtIndex($0, 0, nil)
      })
    let cleaned = try #require(GeminiMark.pixels(of: image))
    let worst = zip(original.data, cleaned.data).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(worst <= 3)

    // 没盖星标的：认不出，不出文件
    let plain = root.appending(path: "plain.png")
    try write(original, to: plain)
    await #expect(throws: GeminiMark.Failure.self) { try await GeminiMark.clean(plain) }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "plain-去水印.png").path))
  }
}
