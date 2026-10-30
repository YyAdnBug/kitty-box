// Gemini 角标（PLAN §2「Gemini 角标」，D1）：反向 alpha 混合，核心从 GargantuaX/gemini-watermark-remover（MIT，
// commit ddd67a7）移植，许可证在 Resources/gemini-watermark-LICENSE.txt。
// Gemini 加水印：水印图 = α·255 + (1 − α)·原图（白色星标）；反着解：原图 = (水印图 − α·255) / (1 − α)，不靠 AI 猜。
// α 图是上游内嵌的 Float32 原始数据（Resources/gemini-alpha-*.bin，从黑底上截下的星标，α = RGB 最大值 / 255）。
// 位置在右下角，按 (星标边长, 右下边距) 一个个试（上游的 Gemini 尺寸表里收的几种），算那块区域的灰度、Sobel 梯度和 α 图的
// 相关性，过了上游「直接认定」的门槛（灰度 ≥ 0.3 且梯度 ≥ 0.12，或灰度 ≥ 0.295 且梯度 ≥ 0.45）的里头取灰度分最高的。
// 认不出就不动，交给画笔擦除（M4）。
// ponytail: 上游的残影修补、FDnCNN 降噪、深色描边变体、多层叠加、自适应搜位置都没移植；Gemini 出了新版本认不出时，
// 从上游同步 α 图和候选位置（geminiSizeCatalog.js、embeddedAlphaMaps.js）

import CoreGraphics
import Foundation
import ImageIO

nonisolated enum GeminiMark {
  struct Candidate: Equatable {
    var size: Int
    var margin: Int
    /// α 图的名字（Resources/gemini-alpha-<名字>.bin）；边长和它不一样时从它双线性缩放
    var alpha: String
  }

  /// 上游 geminiSizeCatalog.js 里的几种：0.5k 的 48/32、1k–4k 的 96/64、2026-05 起 2k 的 96/192（新 α 图）、
  /// 3.x 当前 1k 的 48/96、v2 小号 36/96（新 α 图），和两个按尺寸固定的 48/89（2752×1536）、46/32（1408×768）
  static let candidates = [
    Candidate(size: 48, margin: 32, alpha: "48"),
    Candidate(size: 96, margin: 64, alpha: "96"),
    Candidate(size: 96, margin: 192, alpha: "96-20260520"),
    Candidate(size: 48, margin: 96, alpha: "48"),
    Candidate(size: 36, margin: 96, alpha: "36v2"),
    Candidate(size: 48, margin: 89, alpha: "48"),
    Candidate(size: 46, margin: 32, alpha: "96"),
  ]

  struct Match {
    var candidate: Candidate
    /// 星标左上角（像素，左上为原点）
    var x: Int
    var y: Int
    var spatial: Double
    var gradient: Double
  }

  /// RGBA 8 位像素（A 不用），左上为原点
  struct Pixels {
    var width: Int
    var height: Int
    var data: [UInt8]
  }

  enum Failure: LocalizedError {
    case unreadable
    case notFound
    case unwritable

    var errorDescription: String? {
      switch self {
      case .unreadable: "读不出这张图。"
      case .notFound: "没认出 Gemini 角标。"
      case .unwritable: "存不下去水印的结果。"
      }
    }
  }

  // MARK: 找和去（纯函数）

  static func find(in pixels: Pixels) -> Match? {
    var best: Match?
    for candidate in candidates {
      let x = pixels.width - candidate.margin - candidate.size
      let y = pixels.height - candidate.margin - candidate.size
      guard x >= 0, y >= 0, let alpha = alphaMap(candidate) else { continue }
      let patch = gray(pixels, x: x, y: y, size: candidate.size)
      let spatial = correlation(patch, alpha)
      let gradient = correlation(
        sobel(patch, size: candidate.size), sobel(alpha, size: candidate.size))
      let direct = (spatial >= 0.3 && gradient >= 0.12) || (spatial >= 0.295 && gradient >= 0.45)
      if direct, spatial > best?.spatial ?? -1 {
        best = Match(candidate: candidate, x: x, y: y, spatial: spatial, gradient: gradient)
      }
    }
    return best
  }

  /// 上游 blendModes.js 的 removeWatermark：α 先减掉 3/255 的量化噪底，剩下不到 0.002 的不动；反解用原 α，最大 0.99
  static func remove(_ match: Match, from pixels: inout Pixels) {
    guard let alpha = alphaMap(match.candidate) else { return }
    let size = match.candidate.size
    for row in 0..<size {
      for column in 0..<size {
        let a = Double(alpha[row * size + column])
        guard max(0, a - 3.0 / 255) >= 0.002 else { continue }
        let opacity = min(a, 0.99)
        let index = ((match.y + row) * pixels.width + match.x + column) * 4
        for channel in 0..<3 {
          let marked = Double(pixels.data[index + channel])
          let original = (marked - opacity * 255) / (1 - opacity)
          pixels.data[index + channel] = UInt8(max(0, min(255, original.rounded())))
        }
      }
    }
  }

  // MARK: 文件

  /// 去掉角标的图另存在原图旁边：「原名-去水印」、同格式，重名加「 2」；照片信息带过去
  @concurrent static func clean(_ source: URL) async throws -> URL {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let type = CGImageSourceGetType(input),
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
      var pixels = pixels(of: image)
    else { throw Failure.unreadable }
    guard let match = find(in: pixels) else { throw Failure.notFound }
    remove(match, from: &pixels)

    let colorSpace = colorSpace(of: image)
    guard
      let result = pixels.data.withUnsafeMutableBytes({ buffer in
        CGContext(
          data: buffer.baseAddress, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
          bytesPerRow: pixels.width * 4, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
      })
    else { throw Failure.unwritable }
    let target = source.adding("-去水印").uniqued()
    guard let destination = CGImageDestinationCreateWithURL(target as CFURL, type, 1, nil) else {
      throw Failure.unwritable
    }
    var properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
    properties[kCGImageDestinationLossyCompressionQuality] = 0.95
    CGImageDestinationAddImage(destination, result, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: target)
      throw Failure.unwritable
    }
    return target
  }

  /// 按图本身的色彩空间展开成 RGBA，不做色彩转换（换了空间，反解的数就不对了）
  static func pixels(of image: CGImage) -> Pixels? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = data.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: colorSpace(of: image),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    return drawn ? Pixels(width: image.width, height: image.height, data: data) : nil
  }

  private static func colorSpace(of image: CGImage) -> CGColorSpace {
    image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(
      name: CGColorSpace.sRGB)!
  }

  // MARK: α 图和相关性

  private static let rawMaps: [String: [Float]] = {
    var maps: [String: [Float]] = [:]
    for name in ["48", "96", "96-20260520", "36v2"] {
      guard let url = Bundle.main.url(forResource: "gemini-alpha-\(name)", withExtension: "bin"),
        let data = try? Data(contentsOf: url)
      else { continue }
      maps[name] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    return maps
  }()

  static func alphaMap(_ candidate: Candidate) -> [Float]? {
    guard let raw = rawMaps[candidate.alpha] else { return nil }
    let native = Int(Double(raw.count).squareRoot())
    return native == candidate.size ? raw : resize(raw, from: native, to: candidate.size)
  }

  /// 上游 interpolateAlphaMap：双线性，四角对齐
  private static func resize(_ source: [Float], from: Int, to: Int) -> [Float] {
    let scale = Float(from - 1) / Float(max(1, to - 1))
    var out = [Float](repeating: 0, count: to * to)
    for y in 0..<to {
      let sy = Float(y) * scale
      let (y0, fy) = (Int(sy), sy - Float(Int(sy)))
      let y1 = min(from - 1, y0 + 1)
      for x in 0..<to {
        let sx = Float(x) * scale
        let (x0, fx) = (Int(sx), sx - Float(Int(sx)))
        let x1 = min(from - 1, x0 + 1)
        let top = source[y0 * from + x0] * (1 - fx) + source[y0 * from + x1] * fx
        let bottom = source[y1 * from + x0] * (1 - fx) + source[y1 * from + x1] * fx
        out[y * to + x] = top * (1 - fy) + bottom * fy
      }
    }
    return out
  }

  /// 那块区域的亮度（Rec. 709 系数，同上游），0–1
  private static func gray(_ pixels: Pixels, x: Int, y: Int, size: Int) -> [Float] {
    var out = [Float](repeating: 0, count: size * size)
    for row in 0..<size {
      for column in 0..<size {
        let index = ((y + row) * pixels.width + x + column) * 4
        out[row * size + column] =
          (0.2126 * Float(pixels.data[index]) + 0.7152 * Float(pixels.data[index + 1]) + 0.0722
            * Float(pixels.data[index + 2])) / 255
      }
    }
    return out
  }

  /// Sobel 梯度幅值，最外一圈记 0
  private static func sobel(_ values: [Float], size: Int) -> [Float] {
    var out = [Float](repeating: 0, count: values.count)
    guard size > 2 else { return out }
    for y in 1..<size - 1 {
      for x in 1..<size - 1 {
        func at(_ dx: Int, _ dy: Int) -> Float { values[(y + dy) * size + x + dx] }
        let gx = at(1, -1) + 2 * at(1, 0) + at(1, 1) - at(-1, -1) - 2 * at(-1, 0) - at(-1, 1)
        let gy = at(-1, 1) + 2 * at(0, 1) + at(1, 1) - at(-1, -1) - 2 * at(0, -1) - at(1, -1)
        out[y * size + x] = (gx * gx + gy * gy).squareRoot()
      }
    }
    return out
  }

  /// 归一化互相关，−1…1；有一边是平的（方差为 0）时 0
  private static func correlation(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    let n = Double(a.count)
    let meanA = a.reduce(0) { $0 + Double($1) } / n
    let meanB = b.reduce(0) { $0 + Double($1) } / n
    var (product, varianceA, varianceB) = (0.0, 0.0, 0.0)
    for index in a.indices {
      let (da, db) = (Double(a[index]) - meanA, Double(b[index]) - meanB)
      product += da * db
      varianceA += da * da
      varianceB += db * db
    }
    let denominator = (varianceA * varianceB).squareRoot()
    return denominator < 1e-12 ? 0 : product / denominator
  }
}
