// AI 水印（M7，原来的「Gemini 角标」改成通用的；用户说不只 Gemini，别家生成的图也有水印）：一张图按两条路认——
// 1. Gemini 的星标：按原理反解（GeminiMark），一点不猜；
// 2. 「AI生成」这类文字水印（国内的豆包、即梦、通义、文心、可灵、海螺、Kimi…按规定都在角上标「AI生成」，国外有「Made with AI」等）：
//    用系统的文字识别（Vision，本机）整张认一遍、四个角再各认一遍（大图上角里的小字整张认会认错），在上下两条边里找带这些字
//    （或者贴边的短短一行「…生成」）的那一行，往外扩一圈（左边多扩一点，盖住字旁边的小图标），
//    一块一块交给补图模型补（Inpainter，设置里选的那个；没下好就说一声）。
// 3. 用户自己加的字（M9，用户问「不是 AI 生成的字怎么去除」）：右边「也去掉这些字」填的词（署名、网址、「样张」…），
//    整张图里找，带这些词的那一行整行补掉（单张图上点哪行擦哪行用画笔擦除的「选文字」）。
// 都没认出：那一格写「没认出 AI 水印」，能改用画笔擦除。结果是「原名-去水印」放在原图旁边，原图不动。
// ponytail: 只认文字；纯图标、没有字的水印（比如有的只有一个 logo）认不出，用画笔擦除

import CoreGraphics
import Foundation
import ImageIO
import Vision

nonisolated enum AIMark {
  enum Failure: LocalizedError {
    case unreadable
    case notFound
    case needsModel(AIModel)

    var errorDescription: String? {
      switch self {
      case .unreadable: "读不出这张图。"
      case .notFound: "没认出 AI 水印。"
      case .needsModel(let model): "找到了文字水印，要先下载补图模型「\(model.title)」。"
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
    let folded = fold(text)
    return keywords.contains { folded.contains($0) }
  }

  /// 比较前统一：小写、去掉空格和连字符
  static func fold(_ text: String) -> String {
    text.lowercased().filter { !$0.isWhitespace && $0 != "-" }
  }

  /// 「也去掉这些字」填的一串（逗号、顿号、分号、换行隔开；空格不算，「Made with AI」是一个词）→ 一个个词
  static func words(_ text: String) -> [String] {
    text.split { ",，、;；\n".contains($0) }.map { fold(String($0)) }.filter { !$0.isEmpty }
  }

  /// words：用户自己加的词（已经 fold 过），整张图里找
  @concurrent static func clean(_ source: URL, using model: AIModel, words: [String] = [])
    async throws -> URL
  {
    // 只解一次：先认 Gemini 的星标，不是的话接着找文字水印
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      var image = ImageConverter.upright(input, at: 0)
    else { throw Failure.unreadable }
    if let cleaned = try GeminiMark.removed(from: image) {
      return try GeminiMark.save(cleaned, like: input, source: source)
    }
    let boxes = try locate(in: image, words: words)
    guard !boxes.isEmpty else { throw Failure.notFound }
    guard model.isInstalled else { throw Failure.needsModel(model) }
    // 一块一块补：几块分在不同角上时一起补，裁出来的就是整张图，缩到模型边长会糊
    for box in boxes {
      // 整批停下了：还没补的不补了
      try Task.checkCancellation()
      image = try await Inpainter.shared.erase(
        image, mask: mask([box], width: image.width, height: image.height), using: model)
    }
    return try GeminiMark.save(image, like: input, source: source)
  }

  /// 图里要去掉的字在哪：左上为原点的像素框，已经往外扩过一圈，叠在一起的并成一个。AI 水印的词只看上下各 30% 的边
  /// （水印都贴边），用户加的词整张图都算。
  /// 整张认一遍，四个角再各认一遍：大图整张认时系统会先缩小，角上又小又半透明的水印字就认错了（2026-11-02 用户的
  /// 1672×2508 海报，右下角的「豆包AI生成」整张认成「昱包TAT」，只认右下角那一块就认对了；放大角块反而更差，实测）
  static func locate(in image: CGImage, words: [String] = []) throws -> [CGRect] {
    let height = CGFloat(image.height)
    let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: height)
    let found = try (lines(in: image) + corners(of: image)).compactMap { line -> CGRect? in
      let edge = line.rect.minY < height * 0.3 || line.rect.maxY > height * 0.7
      let folded = fold(line.text)
      guard
        (edge && (isWatermark(line.text) || isAILabel(folded)))
          || words.contains(where: folded.contains)
      else { return nil }
      return expanded(line.rect).intersection(bounds).integral
    }
    // 同一行整张和角上都认到了：并成一块，只补一次
    var merged: [CGRect] = []
    for box in found {
      if let index = merged.firstIndex(where: { $0.intersects(box) }) {
        merged[index] = merged[index].union(box)
      } else {
        merged.append(box)
      }
    }
    return merged
  }

  /// 贴边的短短一行、以「生成」结尾：角上半透明的「AI生成」常被认错前面几个字（「三包A生成」「虹生成」，实测）。
  /// ponytail: 角上真有一句很短的「…生成」正文也会被当成水印补掉；遇到了再收紧（比如要求前面带 a / 包）
  static func isAILabel(_ folded: String) -> Bool {
    folded.contains("生成") && folded.count <= 8
  }

  /// 四个角各一块（宽一半、高四分之一，不放大）认出来的字，框换算回整张图的坐标
  private static func corners(of image: CGImage) throws -> [(text: String, rect: CGRect)] {
    let (width, height) = (image.width / 2, image.height / 4)
    guard width > 0, height > 0 else { return [] }
    var found: [(text: String, rect: CGRect)] = []
    for x in [0, image.width - width] {
      for y in [0, image.height - height] {
        // CGImage 裁切的坐标是左上为原点的像素，和 lines 给的框一样
        guard let corner = image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
        else { continue }
        found += try lines(in: corner).map {
          ($0.text, $0.rect.offsetBy(dx: CGFloat(x), dy: CGFloat(y)))
        }
      }
    }
    return found
  }

  /// 系统文字识别（本机）认出来的每一行字和它的框（左上为原点的像素框，没扩过）；画笔擦除的「选文字」也用
  static func lines(in image: CGImage) throws -> [(text: String, rect: CGRect)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let (width, height) = (CGFloat(image.width), CGFloat(image.height))
    return (request.results ?? []).compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      // Vision 的框：0–1、左下为原点 → 像素、左上为原点
      let box = observation.boundingBox
      return (
        text,
        CGRect(
          x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width,
          height: box.height * height)
      )
    }
  }

  /// 往外扩：四周各 0.2 个行高，左边再多 0.8 个（字左边常有个小图标）。系统给的行框本来就比字高出一截
  /// （海报上字约 47 像素、框 65），原来四周各扩半个行高、左边再一个半，连旁边的亭子底座、岸线都一起补糊了（2026-11-02 实测）
  static func expanded(_ rect: CGRect) -> CGRect {
    let pad = rect.height * 0.2
    return CGRect(
      x: rect.minX - pad - rect.height * 0.8, y: rect.minY - pad,
      width: rect.width + pad * 2 + rect.height * 0.8, height: rect.height + pad * 2)
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
