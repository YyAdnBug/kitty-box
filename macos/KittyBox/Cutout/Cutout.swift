// 去背景（M7，用户要的新功能）：把主体抠出来，背景换成透明或白色，可以裁到主体的边上。结果存成 PNG（留得住透明）
// 「原名-去背景.png」放在原图旁边，原图不动。两种抠法（M9 起，用户说系统的效果不好、问 GitHub 上有没有好用的）：
// - 精细（默认）：下载的抠图模型 BiRefNet Lite（AIModel.cutout，MIT，约 82 MB，第一次用时下载），什么都能抠、毛边干净。
//   整张拉成 1024 见方、按 ImageNet 的均值方差归一化喂进去，出 1024 见方的前景概率（logits 过 sigmoid），放大回原图当透明度。
//   只用 CPU：一张约 1 秒；用 GPU 第一次要先编译将近 10 秒（模型页也建议只用 CPU，半精度在别的单元上可能出错）。
// - 系统：系统的主体识别（Vision 的前景实例遮罩，同「照片」里的「拷贝主体」），不用下载，人、动物、商品抠得好；
//   风景、海报、纯文字的截图认不出主体。
// 哪种都认不出主体时那一格写「没认出主体」。

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
    _ source: URL, background: Background, crop: Bool, engine: Engine = .system
  ) async throws -> URL {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = ImageConverter.upright(input, at: 0)
    else { throw Failure.unreadable }
    var output =
      switch engine {
      case .model: apply(try await Matting.shared.mask(for: image), to: image, crop: crop)
      case .system: try lifted(image, crop: crop)
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

  /// 系统的主体识别抠出来（背景透明）；crop：裁到主体的外接框
  static func lifted(_ image: CGImage, crop: Bool) throws -> CIImage {
    let handler = VNImageRequestHandler(cgImage: image)
    let request = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
      throw Failure.noSubject
    }
    let buffer = try observation.generateMaskedImage(
      ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: crop)
    return CIImage(cvPixelBuffer: buffer)
  }

  /// 原图按遮罩（8 位灰度，白 = 留下，可以比原图小）抠出来；crop：裁到遮罩里留下那块的外接框
  static func apply(_ mask: CGImage, to image: CGImage, crop: Bool) -> CIImage {
    let input = CIImage(cgImage: image)
    let scaled = CIImage(cgImage: mask).transformed(
      by: CGAffineTransform(
        scaleX: CGFloat(image.width) / CGFloat(mask.width),
        y: CGFloat(image.height) / CGFloat(mask.height)))
    let cut = input.applyingFilter(
      "CIBlendWithMask",
      parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: scaled])
    var extent = input.extent
    if crop, let box = Inpainter.bounds(of: mask) {
      // 遮罩的框：左上为原点 → CI 的左下为原点，再放大到原图
      let (sx, sy) = (extent.width / CGFloat(mask.width), extent.height / CGFloat(mask.height))
      extent = CGRect(
        x: box.minX * sx, y: (CGFloat(mask.height) - box.maxY) * sy, width: box.width * sx,
        height: box.height * sy
      ).integral.intersection(extent)
    }
    return cut.cropped(to: extent)
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
