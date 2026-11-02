// 补图（D2、D3，画笔擦除和 AI 水印共用）：用设置里选的模型（AIModel：快速 MI-GAN 512 / 标准 LaMa 800 / 高清 Big LaMa 2048，
// 不随包，用时下载到 Application Support）。输入模型边长见方的图和 8 位灰度遮罩（白 = 要补），出同样大的图；遮罩外的像素它原样带过。
// 大图不缩整张：在遮罩外接框四周留一圈上下文裁一块（尽量正方形），缩到模型的边长推理，再放大回那块的尺寸，只按遮罩把补好的贴回原图，
// 原图分辨率不变。贴回用的遮罩边缘羽化一下（按缩放比例模糊几个像素）：大块区域缩过再放大，补出来的颜色会差一两个色阶，
// 硬边贴回去能看出一圈轮廓（M4 在真照片上看到的）。
// 模型看的那块至少是模型的边长（图够大时往外多给些原图），不把小块放大了喂给它：高清把 840 的一块放大到 2048 补出来发灰一片
// （2026-11-02 在系统壁纸上实测；按原像素给就干净）。改的还是只在裁的那块里。
// 交给模型的遮罩往外扩两个羽化的 σ：快速（MI-GAN）补出来的边上有一圈亮线，扩出去之后落在羽化的外沿、贴回去看不见（同一次实测）。
// ponytail: 涂得很大（裁出来的块超过 800、要缩小）时，补出来的地方少了原图的细颗粒，仔细看还有一圈很淡的轮廓；
// 去水印一般只涂一两百像素，块不超过模型边长就不缩。要更好再加颗粒匹配（或选「高清」）
// 计算单元只用 CPU + GPU：M4 实测一次 0.7 s；加上神经网络引擎反而 3–4 s，第一次还要先编译将近两分钟。
// 模型第一次用时加载（约 1 s），之后留在这个 actor 里（只留正在用的那一个：三个都留着要占四百多 MB；设置里删了就丢掉）。

import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

actor Inpainter {
  static let shared = Inpainter()

  enum Failure: LocalizedError {
    case noModel
    case failed

    var errorDescription: String? {
      switch self {
      case .noModel: "补图模型还没下载。"
      case .failed: "补图没成功。"
      }
    }
  }

  private var loaded: [AIModel: MLModel] = [:]

  /// 把 image 里 mask 白的地方补掉；mask 和 image 一样大、8 位灰度。没涂的话原样返回
  func erase(_ image: CGImage, mask: CGImage, using choice: AIModel = .standard) throws
    -> CGImage
  {
    guard let box = Self.bounds(of: mask) else { return image }
    let crop = Self.cropRect(around: box, in: CGSize(width: image.width, height: image.height))
    guard let partMask = mask.cropping(to: crop) else { throw Failure.failed }
    return try erase(image, in: crop, mask: partMask, using: choice)
  }

  /// 只补 crop（左上为原点，cropRect 算的）那一块：partMask 和 crop 一样大。改动只在 crop 里（画笔擦除的撤销只记这一块）
  func erase(_ image: CGImage, in crop: CGRect, mask partMask: CGImage, using choice: AIModel)
    throws -> CGImage
  {
    // 排在这个 actor 上等着的（AI 水印几路一起补）：整批停下了就不补，不然「停止」还要等它们一个个补完
    try Task.checkCancellation()
    let model = try load(choice)
    let inputs = model.modelDescription.inputDescriptionsByName
    guard let imageShape = inputs["image"]?.imageConstraint,
      let maskShape = inputs["mask"]?.imageConstraint
    else { throw Failure.noModel }
    let side = imageShape.pixelsWide
    let size = CGSize(width: image.width, height: image.height)
    // 模型看的那块（包着 crop）和它的遮罩
    let seen = Self.seenRect(around: crop, side: CGFloat(side), in: size)
    guard let part = image.cropping(to: seen) else { throw Failure.failed }
    // 贴回时羽化的 σ（原图像素）
    let feather = max(1.5, seen.width / CGFloat(side) * 3)
    let seenMask = Self.dilated(Self.placed(partMask, at: crop, in: seen), by: feather * 2)
    let result = try model.prediction(
      from: MLDictionaryFeatureProvider(dictionary: [
        "image": try MLFeatureValue(
          cgImage: Self.resized(part, side: side, gray: false), constraint: imageShape,
          options: nil),
        "mask": try MLFeatureValue(
          cgImage: Self.resized(seenMask, side: side, gray: true), constraint: maskShape,
          options: nil),
      ]))
    guard let buffer = result.featureValue(for: "output")?.imageBufferValue,
      let filled = Self.image(from: buffer)
    else { throw Failure.failed }

    // 先画原图，再只在 crop 里、按羽化的遮罩把补好的画上去（CG 的坐标原点在左下，cropping 的在左上）
    let context = Self.canvas(like: image, width: image.width, height: image.height)
    context.draw(image, in: CGRect(origin: .zero, size: size))
    func place(_ rect: CGRect) -> CGRect {
      CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }
    context.clip(to: place(crop), mask: Self.feathered(partMask, radius: feather))
    context.interpolationQuality = .high
    context.draw(filled, in: place(seen))
    guard let output = context.makeImage() else { throw Failure.failed }
    return output
  }

  private func load(_ choice: AIModel) throws -> MLModel {
    if let model = loaded[choice] { return model }
    guard choice.isInstalled else { throw Failure.noModel }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndGPU
    let model = try MLModel(contentsOf: choice.installed, configuration: configuration)
    loaded = [choice: model]
    return model
  }

  /// 设置里删了这个模型：丢掉加载好的那份
  func forget(_ choice: AIModel) { loaded[choice] = nil }

  // MARK: 纯函数

  /// 补好的图画在哪：和 image 一样的 RGB 色彩空间（不是 RGB 的用 sRGB）、8 位 RGBA。画笔擦除撤销时贴回去也用它，像素格式一致
  static func canvas(like image: CGImage, width: Int, height: Int) -> CGContext {
    let space =
      image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(
        name: CGColorSpace.sRGB)!
    return CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  }

  /// 要裁的那块（左上为原点）：框四周留一圈上下文（至少 32，多则框边长的一半），尽量正方形、至少 256，不出图
  static func cropRect(around box: CGRect, in size: CGSize) -> CGRect {
    let margin = max(32, max(box.width, box.height) / 2)
    let side = max(max(box.width, box.height) + 2 * margin, 256)
    let width = max(min(side, size.width), box.width)
    let height = max(min(side, size.height), box.height)
    let x = min(max(box.midX - width / 2, 0), size.width - width)
    let y = min(max(box.midY - height / 2, 0), size.height - height)
    return CGRect(x: x, y: y, width: width, height: height).integral
      .intersection(CGRect(origin: .zero, size: size))
  }

  /// 模型看的那块（左上为原点）：包着 crop，边长至少 side（图没那么大就到图为止），以 crop 为中心、不出图
  static func seenRect(around crop: CGRect, side: CGFloat, in size: CGSize) -> CGRect {
    let width = min(max(crop.width, side), size.width)
    let height = min(max(crop.height, side), size.height)
    let x = min(max(crop.midX - width / 2, 0), size.width - width)
    let y = min(max(crop.midY - height / 2, 0), size.height - height)
    return CGRect(x: x, y: y, width: width, height: height).integral
      .intersection(CGRect(origin: .zero, size: size))
  }

  /// 遮罩里不是黑的那些像素的外接框（左上为原点）；全黑是 nil
  static func bounds(of mask: CGImage) -> CGRect? {
    let (width, height) = (mask.width, mask.height)
    var bytes = [UInt8](repeating: 0, count: width * height)
    let drawn = bytes.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    var (minX, minY, maxX, maxY) = (width, height, -1, -1)
    for y in 0..<height {
      for x in 0..<width where bytes[y * width + x] > 8 {
        (minX, minY) = (min(minX, x), min(minY, y))
        (maxX, maxY) = (max(maxX, x), max(maxY, y))
      }
    }
    return maxX < 0
      ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
  }

  /// 遮罩边缘模糊一下（radius：高斯的 σ，像素），还是 8 位灰度、同样大
  private static func feathered(_ mask: CGImage, radius: CGFloat) -> CGImage {
    let input = CIImage(cgImage: mask)
    let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(
      to: input.extent)
    return CIContext().createCGImage(
      blurred, from: input.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) ?? mask
  }

  /// crop 那块的遮罩放进 seen 那么大的黑底里（两个都是左上为原点的原图像素）
  private static func placed(_ mask: CGImage, at crop: CGRect, in seen: CGRect) -> CGImage {
    let context = CGContext(
      data: nil, width: Int(seen.width), height: Int(seen.height), bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.draw(
      mask,
      in: CGRect(
        x: crop.minX - seen.minX, y: seen.maxY - crop.maxY, width: crop.width, height: crop.height))
    return context.makeImage()!
  }

  /// 遮罩往外扩 radius 像素，还是 8 位灰度、同样大
  private static func dilated(_ mask: CGImage, by radius: CGFloat) -> CGImage {
    let input = CIImage(cgImage: mask)
    let grown = input.applyingFilter(
      "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius]
    ).cropped(to: input.extent)
    return CIContext().createCGImage(
      grown, from: input.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) ?? mask
  }

  /// 拉成模型要的边长见方
  private static func resized(_ image: CGImage, side: Int, gray: Bool) -> CGImage {
    let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()!
  }

  /// 模型出的 BGRA 像素 → CGImage
  private static func image(from buffer: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let context = CGContext(
      data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
    return context?.makeImage()
  }
}
