// AI 水印（M7，原来的「Gemini 角标」改成通用的；用户说不只 Gemini，别家生成的图也有水印）：一张图按两条路认——
// 1. Gemini 的星标：按原理反解（GeminiMark），一点不猜；
// 2. 「AI生成」这类文字水印（国内的豆包、即梦、通义、文心、可灵、海螺、Kimi…按规定都在角上标「AI生成」，国外有「Made with AI」等）：
//    用系统的文字识别（Vision，本机）在上下两条边里找带这些字的那一行，往外扩一圈（左边多扩一点，盖住字旁边的小图标），
//    一块一块交给补图模型补（Inpainter，设置里选的那个；没下好就说一声）。
// 两条都没认出：那一行写「没认出 AI 水印」，能改用画笔擦除。结果是「原名-去水印」放在原图旁边，原图不动。
// ponytail: 只认文字；纯图标、没有字的水印（比如有的只有一个 logo）认不出，用画笔擦除

import CoreGraphics
import Foundation
import ImageIO
import Vision

nonisolated enum AIMark {
  enum Failure: LocalizedError {
    case unreadable
    case notFound
    case needsModel(InpaintModel)
    case unwritable

    var errorDescription: String? {
      switch self {
      case .unreadable: "读不出这张图。"
      case .notFound: "没认出 AI 水印。"
      case .needsModel(let model): "找到了文字水印，要先下载补图模型「\(model.title)」。"
      case .unwritable: "存不下去水印的结果。"
      }
    }
  }

  /// 水印文字里会有的词（比较时都小写、去掉空格和连字符）
  static let keywords = [
    "ai生成", "人工智能生成", "ai合成", "ai创作", "豆包", "即梦", "通义", "万相", "文心", "一格", "可灵", "海螺",
    "kimi", "元宝", "混元", "智谱", "清言", "星火", "天工", "doubao", "jimeng", "generatedbyai",
    "aigenerated", "imaginedwithai", "madewithai", "createdwithai", "metaai",
  ]

  static func isWatermark(_ text: String) -> Bool {
    let folded = text.lowercased().filter { !$0.isWhitespace && $0 != "-" }
    return keywords.contains { folded.contains($0) }
  }

  @concurrent static func clean(_ source: URL, using model: InpaintModel) async throws -> URL {
    do {
      return try await GeminiMark.clean(source)
    } catch GeminiMark.Failure.notFound {
      // 不是 Gemini 的星标：接着找文字水印
    }
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      var image = ImageConverter.upright(input, at: 0)
    else { throw Failure.unreadable }
    let boxes = try locate(in: image)
    guard !boxes.isEmpty else { throw Failure.notFound }
    guard model.isInstalled else { throw Failure.needsModel(model) }
    // 一块一块补：几块分在不同角上时一起补，裁出来的就是整张图，缩到模型边长会糊
    for box in boxes {
      image = try await Inpainter.shared.erase(
        image, mask: mask([box], width: image.width, height: image.height), using: model)
    }
    let target = source.adding("-去水印").uniqued()
    guard ImageConverter.save(image, like: input, to: target) else { throw Failure.unwritable }
    return target
  }

  /// 图里像 AI 水印的文字在哪：左上为原点的像素框，已经往外扩过一圈；只看上下各 30% 的边（水印都贴边）
  static func locate(in image: CGImage) throws -> [CGRect] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let (width, height) = (CGFloat(image.width), CGFloat(image.height))
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    return (request.results ?? []).compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string, isWatermark(text) else {
        return nil
      }
      let box = observation.boundingBox
      guard box.minY < 0.3 || box.maxY > 0.7 else { return nil }
      // Vision 的框：0–1、左下为原点 → 像素、左上为原点
      let rect = CGRect(
        x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width,
        height: box.height * height)
      return expanded(rect).intersection(bounds).integral
    }
  }

  /// 往外扩：四周各半个字高，左边再多一个半字高（字左边常有个小图标）
  static func expanded(_ rect: CGRect) -> CGRect {
    let pad = rect.height * 0.5
    return CGRect(
      x: rect.minX - pad - rect.height * 1.5, y: rect.minY - pad,
      width: rect.width + pad * 2 + rect.height * 1.5, height: rect.height + pad * 2)
  }

  /// 框画成和图一样大的遮罩：白 = 要补
  static func mask(_ boxes: [CGRect], width: Int, height: Int) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    // 翻成左上原点，和框的坐标一致
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(gray: 1, alpha: 1)
    for box in boxes {
      context.addPath(
        CGPath(
          roundedRect: box, cornerWidth: min(box.height / 4, 12),
          cornerHeight: min(box.height / 4, 12), transform: nil))
    }
    context.fillPath()
    return context.makeImage()!
  }
}
