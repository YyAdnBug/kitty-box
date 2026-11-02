// 去背景（M7，用户要的新功能）：把主体抠出来，背景换成透明或白色，可以裁到主体的边上。结果存成 PNG（留得住透明）
// 「原名-去背景.png」放在原图旁边，原图不动。两种抠法（M9 起，用户说系统的效果不好、问 GitHub 上有没有好用的）：
// - 精细（默认）：下载的抠图模型 BiRefNet Lite（AIModel.cutout，MIT，约 82 MB，第一次用时下载），什么都能抠、毛边干净。
//   整张拉成 1024 见方、按 ImageNet 的均值方差归一化喂进去，出 1024 见方的前景概率（logits 过 sigmoid），放大回原图当透明度。
//   只用 CPU：一张约 1 秒；用 GPU 第一次要先编译将近 10 秒（模型页也建议只用 CPU，半精度在别的单元上可能出错）。
// - 系统：系统的主体识别（Vision 的前景实例遮罩，同「照片」里的「拷贝主体」），不用下载，人、动物、商品抠得好；
//   风景、海报、纯文字的截图认不出主体。
// 保留文字（2026-11-02，用户拿节目单海报试精细，字只剩碎片：1024 见方里细笔画没了，模型还把字当背景）：两种抠法都加一步，
// 系统文字识别（AIMark.lines）找出每行字，在行框里按颜色把字一笔一笔抠出来（keepingText），和抠出来的主体取不透明的那个。
// 裁到主体时连字一起算（按抠完的透明度找外接框）。哪种都认不出主体、也没留下字时那一格写「没认出主体」。

import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

nonisolated enum Cutout {
  enum Engine: String, CaseIterable {
    case model, system

    var title: String {
      switch self {
      case .model: "精细"
      case .system: "系统"
      }
    }
  }

  enum Background: String, CaseIterable {
    case transparent, white

    var title: String {
      switch self {
      case .transparent: "透明"
      case .white: "白色"
      }
    }
  }

  enum Failure: LocalizedError {
    case unreadable
    case noSubject
    case needsModel
    case unwritable

    var errorDescription: String? {
      switch self {
      case .unreadable: "读不出这张图。"
      case .noSubject: "没认出主体。"
      case .needsModel: "要先下载抠图模型「精细」。"
      case .unwritable: "存不下去背景的结果。"
      }
    }
  }

  @concurrent static func remove(
    _ source: URL, background: Background, crop: Bool, engine: Engine = .system,
    keepText: Bool = false
  ) async throws -> URL {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = ImageConverter.upright(input, at: 0)
    else { throw Failure.unreadable }
    // ponytail: 整张图认一遍字，节目单海报（1672×2508）上的小字都认得出；特别大的长图上的小字可能漏，到时再分块认
    let lines = keepText ? try AIMark.lines(in: image).map(\.rect) : []
    try Task.checkCancellation()
    var subject = true
    var output: CIImage
    do {
      output =
        switch engine {
        case .model: apply(try await Matting.shared.mask(for: image), to: image)
        case .system: try lifted(image)
        }
    } catch Failure.noSubject where !lines.isEmpty {
      // 海报、截图常常认不出主体：只留字
      subject = false
      output = CIImage(color: .clear).cropped(
        to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    if let kept = lines.isEmpty ? nil : try keepingText(lines, of: image, in: output) {
      output = kept
    } else if !subject {
      throw Failure.noSubject
    }
    if crop {
      guard let box = opaqueExtent(of: output) else { throw Failure.noSubject }
      output = output.cropped(to: box)
    }
    if background == .white {
      output = output.composited(over: CIImage(color: .white).cropped(to: output.extent))
    }
    // 抠、换底合在一起只渲一次（原图大小渲一遍就是一张几百 MB 的中间图）
    guard
      let result = context.createCGImage(
        output, from: output.extent, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    else { throw Failure.unwritable }
    let target = try source.deletingPathExtension().appendingPathExtension("png")
      .adding("-去背景").reserved()
    do {
      guard
        let destination = CGImageDestinationCreateWithURL(
          target as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { throw Failure.unwritable }
      CGImageDestinationAddImage(destination, result, nil)
      guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
      return target
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw error
    }
  }

  /// 几张一起抠时共用（每张新建一个也要几十毫秒）
  private static let context = CIContext()

  /// 系统的主体识别抠出来（背景透明，和原图一样大）
  static func lifted(_ image: CGImage) throws -> CIImage {
    let handler = VNImageRequestHandler(cgImage: image)
    let request = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
      throw Failure.noSubject
    }
    let buffer = try observation.generateMaskedImage(
      ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
    return CIImage(cvPixelBuffer: buffer)
  }

  /// 原图按遮罩（8 位灰度，白 = 留下，可以比原图小）抠出来，和原图一样大
  static func apply(_ mask: CGImage, to image: CGImage) -> CIImage {
    let input = CIImage(cgImage: image)
    let scaled = CIImage(cgImage: mask).transformed(
      by: CGAffineTransform(
        scaleX: CGFloat(image.width) / CGFloat(mask.width),
        y: CGFloat(image.height) / CGFloat(mask.height)))
    return input.applyingFilter(
      "CIBlendWithMask",
      parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: scaled]
    ).cropped(to: input.extent)
  }

  /// 抠完的图里留下的（透明度 > 8）那块的外接框（CI 坐标，左下为原点）；全透明是 nil
  static func opaqueExtent(of image: CIImage) -> CGRect? {
    let extent = image.extent
    let (width, height) = (Int(extent.width), Int(extent.height))
    var alpha = [UInt8](repeating: 0, count: width * height)
    context.render(
      image, toBitmap: &alpha, rowBytes: width, bounds: extent, format: .A8, colorSpace: nil)
    var (minX, minY, maxX, maxY) = (width, height, -1, -1)
    for y in 0..<height {
      for x in 0..<width where alpha[y * width + x] > 8 {
        (minX, minY) = (min(minX, x), min(minY, y))
        (maxX, maxY) = (max(maxX, x), max(maxY, y))
      }
    }
    guard maxX >= 0 else { return nil }
    // 位图第一行是最上面那行
    return CGRect(
      x: extent.minX + CGFloat(minX), y: extent.maxY - CGFloat(maxY + 1),
      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
  }

  /// 保留文字：lines 是每行字的框（左上为原点的像素框，AIMark.lines），各自往外扩四分之一字高，一个一个按颜色
  /// 把字抠出来（matteText）放回 cut；一个字都没留下是 nil。框叠在一起也不并：并起来海报标题的框会吞掉下面横幅的框，
  /// 横幅就被当成纸了。所有框外接的那块渲一次（原图、抠好的各一份），在上面挨个改
  static func keepingText(_ lines: [CGRect], of image: CGImage, in cut: CIImage) throws -> CIImage?
  {
    let input = CIImage(cgImage: image)
    let bounds = input.extent
    let boxes = lines.map {
      (
        rect: $0.insetBy(dx: -$0.height / 4, dy: -$0.height / 4).integral.intersection(bounds),
        lineHeight: $0.height
      )
    }.filter { $0.rect.width >= 8 && $0.rect.height >= 8 }
    guard let area = boxes.map(\.rect).reduce(nil, { $0?.union($1) ?? $1 }) else { return nil }
    // 左上为原点 → CI 的左下为原点
    let rect = CGRect(
      x: area.minX, y: bounds.height - area.maxY, width: area.width, height: area.height)
    let (width, height) = (Int(area.width), Int(area.height))
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var layer = pixels
    context.render(
      input, toBitmap: &pixels, rowBytes: width * 4, bounds: rect, format: .RGBA8, colorSpace: sRGB)
    context.render(
      cut, toBitmap: &layer, rowBytes: width * 4, bounds: rect, format: .RGBA8, colorSpace: sRGB)
    var kept = false
    for box in boxes {
      try Task.checkCancellation()
      let (x, y) = (Int(box.rect.minX - area.minX), Int(box.rect.minY - area.minY))
      let (columns, rows) = (Int(box.rect.width), Int(box.rect.height))
      let spans = (0..<rows).map {
        ((y + $0) * width + x) * 4..<((y + $0) * width + x + columns) * 4
      }
      var boxLayer = spans.flatMap { layer[$0] }
      guard
        matteText(
          pixels: spans.flatMap { pixels[$0] }, layer: &boxLayer, width: columns, height: rows,
          lineHeight: box.lineHeight)
      else { continue }
      kept = true
      for (row, span) in spans.enumerated() {
        layer.replaceSubrange(span, with: boxLayer[row * columns * 4..<(row + 1) * columns * 4])
      }
    }
    guard kept else { return nil }
    let patch = CIImage(
      bitmapData: Data(layer), bytesPerRow: width * 4, size: rect.size, format: .RGBA8,
      colorSpace: sRGB
    ).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    // 这块换成改过的，块外还是 cut
    return patch.applyingFilter(
      "CIBlendWithMask",
      parameters: [
        kCIInputBackgroundImageKey: cut,
        kCIInputMaskImageKey: CIImage(color: .white).cropped(to: rect),
      ])
  }

  /// 一个框里把字一笔一笔抠出来。pixels 是原图这块（RGBA，第一行在上），layer 是抠好的这块（预乘 RGBA，就地改），
  /// lineHeight 是字高。底色 = 框边上两圈像素各通道的中位数；离底色不比框边上的起伏（90% 分位）远的算底，
  /// 和最深的笔画（95% 分位）一样远的算字，中间线性过渡（字边的半透明照原样留着，下面反混色才准）；
  /// 颜色还原成 底色 + (像素 − 底色) / 透明度，深色底上字边不带一圈纸色。
  /// 框里的底模型留下了（横幅、牌子上的字）：透明度取模型和字大的那个。底是模型扔掉的（纸上的字）：模型在字边上
  /// 常留一圈半透明的纸，所以离笔画近、颜色在「底色—字色」这条线上的像素只听字的；别的（压着字的主体、彩色花边）
  /// 还是取大的。返回这一块有没有留下字
  static func matteText(
    pixels: [UInt8], layer: inout [UInt8], width: Int, height: Int, lineHeight: CGFloat
  ) -> Bool {
    let count = width * height
    func color(_ index: Int) -> SIMD3<Float> {
      SIMD3(Float(pixels[index * 4]), Float(pixels[index * 4 + 1]), Float(pixels[index * 4 + 2]))
    }
    let ring = (0..<count).filter {
      let (x, y) = ($0 % width, $0 / width)
      return x < 2 || y < 2 || x >= width - 2 || y >= height - 2
    }
    let base = SIMD3((0..<3).map { channel in quantile(ring.map { color($0)[channel] }, 0.5) })
    let distances = (0..<count).map {
      let offset = color($0) - base
      return (offset * offset).sum().squareRoot()
    }
    let low = max(16, quantile(ring.map { distances[$0] }, 0.9))
    let high = max(low + 24, quantile(distances, 0.95))
    // 字色（相对底色）：离底色最远的那些像素的平均；底：像底的像素一半以上模型留下了
    var (ink, deepest, paper, keptPaper) = (SIMD3<Float>.zero, 0, 0, 0)
    for index in 0..<count {
      if distances[index] >= high * 0.9 {
        (ink, deepest) = (ink + color(index) - base, deepest + 1)
      }
      if distances[index] <= low {
        (paper, keptPaper) = (paper + 1, keptPaper + (layer[index * 4 + 3] >= 128 ? 1 : 0))
      }
    }
    ink /= Float(max(deepest, 1))
    let inkPower = (ink * ink).sum()
    guard inkPower > 0 else { return false }
    let tolerance = max(low, 0.1 * inkPower.squareRoot())
    let onSubject = keptPaper * 2 > paper
    let near = dilated(
      distances.map { $0 >= (low + high) / 2 }, width: width, height: height,
      radius: max(2, Int((lineHeight * 0.12).rounded())))
    var kept = false
    for index in 0..<count {
      let alpha = min(max((distances[index] - low) / (high - low), 0), 1)
      let offset = color(index) - base
      let residual = offset - (offset * ink).sum() / inkPower * ink
      let textOnly =
        !onSubject && near[index] && (residual * residual).sum() <= tolerance * tolerance
      guard textOnly || alpha * 255 > Float(layer[index * 4 + 3]) else { continue }
      kept = kept || alpha > 8 / 255
      let unmixed =
        alpha > 0
        ? (base + offset / alpha).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))
        : .zero
      for channel in 0..<3 {
        layer[index * 4 + channel] = UInt8((unmixed[channel] * alpha).rounded())
      }
      layer[index * 4 + 3] = UInt8((alpha * 255).rounded())
    }
    return kept
  }

  /// 方形膨胀：radius 以内有一个是 true 就是 true（先横后竖，各用前缀和数）
  private static func dilated(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
    func pass(_ input: [Bool], lines: Int, length: Int, at index: (Int, Int) -> Int) -> [Bool] {
      var output = input
      var prefix = [Int](repeating: 0, count: length + 1)
      for line in 0..<lines {
        for step in 0..<length {
          prefix[step + 1] = prefix[step] + (input[index(line, step)] ? 1 : 0)
        }
        for step in 0..<length {
          output[index(line, step)] =
            prefix[min(length, step + radius + 1)] > prefix[max(0, step - radius)]
        }
      }
      return output
    }
    let rows = pass(mask, lines: height, length: width) { $0 * width + $1 }
    return pass(rows, lines: width, length: height) { $1 * width + $0 }
  }

  /// 第 q 分位（0–1）；空的是 0
  private static func quantile(_ values: [Float], _ q: Float) -> Float {
    guard !values.isEmpty else { return 0 }
    return values.sorted()[Int(Float(values.count - 1) * q)]
  }
}

/// 精细抠图的模型（AIModel.cutout）：第一次用时加载（约 3 秒），之后留着；一次抠一张（一批几张排着来）
actor Matting {
  static let shared = Matting()
  private var model: MLModel?
  private static let side = 1024

  /// 前景遮罩：1024 见方的 8 位灰度（白 = 前景）；几乎全黑（没有前景）就报没认出主体
  func mask(for image: CGImage) throws -> CGImage {
    // 一次抠一张，几张在这里排着：整批停下了，排着的不再抠（一张要好几秒），那一行写「已停止」
    try Task.checkCancellation()
    let input = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float32)
    guard Self.fill(input, with: image) else { throw Cutout.Failure.unreadable }
    let output = try load().prediction(
      from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
    guard let logits = output.featureValue(for: "mask_logits")?.multiArrayValue,
      logits.dataType == .float32, logits.count == Self.side * Self.side
    else { throw Cutout.Failure.unwritable }
    var alpha = [UInt8](repeating: 0, count: logits.count)
    logits.withUnsafeBufferPointer(ofType: Float.self) { values in
      for index in values.indices {
        alpha[index] = UInt8((255 / (1 + exp(-values[index]))).rounded())
      }
    }
    guard alpha.contains(where: { $0 > 127 }) else { throw Cutout.Failure.noSubject }
    return try Self.gray(alpha, side: Self.side)
  }

  /// 设置里删了模型：丢掉加载好的那份
  func forget() { model = nil }

  private func load() throws -> MLModel {
    if let model { return model }
    guard AIModel.cutout.isInstalled else { throw Cutout.Failure.needsModel }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly
    let loaded = try MLModel(contentsOf: AIModel.cutout.installed, configuration: configuration)
    model = loaded
    return loaded
  }

  /// 拉成 1024 见方（不留边，同 BiRefNet 训练时）、RGB 各自减均值除方差，排成 [1, 3, H, W]
  private static func fill(_ array: MLMultiArray, with image: CGImage) -> Bool {
    let plane = side * side
    var pixels = [UInt8](repeating: 0, count: plane * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return false }
    let (mean, deviation): ([Float], [Float]) = ([0.485, 0.456, 0.406], [0.229, 0.224, 0.225])
    array.withUnsafeMutableBufferPointer(ofType: Float.self) { values, _ in
      for index in 0..<plane {
        for channel in 0..<3 {
          values[channel * plane + index] =
            (Float(pixels[index * 4 + channel]) / 255 - mean[channel]) / deviation[channel]
        }
      }
    }
    return true
  }

  private static func gray(_ bytes: [UInt8], side: Int) throws -> CGImage {
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let image = CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { throw Cutout.Failure.unwritable }
    return image
  }
}
