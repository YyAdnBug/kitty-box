// 画笔擦除的补图（D2、D3）：LaMa 的 Core ML 版（mlboydaisuke/LaMa-CoreML，FP32，Apache-2.0，fetch-vendor.sh 拉、构建时拷进
// Resources/LaMa.mlmodelc）。输入 800×800 的图和 8 位灰度遮罩（白 = 要补），出 800×800 的图；遮罩外的像素它原样带过。
// 大图不缩整张：在遮罩外接框四周留一圈上下文裁一块（尽量正方形），缩到 800 推理，再放大回那块的尺寸，只按遮罩把补好的贴回原图，
// 原图分辨率不变。贴回用的遮罩边缘羽化一下（按缩放比例模糊几个像素）：大块区域缩过再放大，补出来的颜色会差一两个色阶，
// 硬边贴回去能看出一圈轮廓（M4 在真照片上看到的）。
// ponytail: 涂得很大（裁出来的块超过 800、要缩小）时，补出来的地方少了原图的细颗粒，仔细看还有一圈很淡的轮廓；
// 去水印一般只涂一两百像素，块不超过 800 就不缩。要更好再加颗粒匹配
// 计算单元只用 CPU + GPU：M4 实测一次 0.7 s；加上神经网络引擎反而 3–4 s，第一次还要先编译将近两分钟。
// 模型第一次用时加载（约 1 s），之后留在这个 actor 里。

import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

actor Inpainter {
  static let shared = Inpainter()
  static let side = 800

  enum Failure: LocalizedError {
    case noModel
    case failed

    var errorDescription: String? {
      switch self {
      case .noModel: "补图的模型没装进 App。"
      case .failed: "补图没成功。"
      }
    }
  }

  private var model: MLModel?

  /// 把 image 里 mask 白的地方补掉；mask 和 image 一样大、8 位灰度。没涂的话原样返回
  func erase(_ image: CGImage, mask: CGImage) throws -> CGImage {
    guard let box = Self.bounds(of: mask) else { return image }
    let crop = Self.cropRect(around: box, in: CGSize(width: image.width, height: image.height))
    guard let part = image.cropping(to: crop), let partMask = mask.cropping(to: crop) else {
      throw Failure.failed
    }
    let model = try loadModel()
    let inputs = model.modelDescription.inputDescriptionsByName
    guard let imageShape = inputs["image"]?.imageConstraint,
      let maskShape = inputs["mask"]?.imageConstraint
    else { throw Failure.noModel }
    let result = try model.prediction(
      from: MLDictionaryFeatureProvider(dictionary: [
        "image": try MLFeatureValue(
          cgImage: Self.resized(part, gray: false), constraint: imageShape, options: nil),
        "mask": try MLFeatureValue(
          cgImage: Self.resized(partMask, gray: true), constraint: maskShape, options: nil),
      ]))
    guard let buffer = result.featureValue(for: "output")?.imageBufferValue,
      let filled = Self.image(from: buffer)
    else { throw Failure.failed }

    // 先画原图，再只在遮罩里把补好的那块画上去（CG 的坐标原点在左下，cropping 的在左上）
    let space =
      image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(
        name: CGColorSpace.sRGB)!
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure.failed }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let place = CGRect(
      x: crop.minX, y: CGFloat(image.height) - crop.maxY, width: crop.width, height: crop.height)
    context.clip(
      to: place,
      mask: Self.feathered(partMask, radius: max(1.5, crop.width / CGFloat(Self.side) * 3)))
    context.interpolationQuality = .high
    context.draw(filled, in: place)
    guard let output = context.makeImage() else { throw Failure.failed }
    return output
  }

  private func loadModel() throws -> MLModel {
    if let model { return model }
    guard let url = Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc") else {
      throw Failure.noModel
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndGPU
    let loaded = try MLModel(contentsOf: url, configuration: configuration)
    model = loaded
    return loaded
  }

  // MARK: 纯函数

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

  /// 拉成模型要的 800×800
  private static func resized(_ image: CGImage, gray: Bool) -> CGImage {
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
