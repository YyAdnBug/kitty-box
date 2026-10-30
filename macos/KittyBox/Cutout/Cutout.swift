// 去背景（M7，用户要的新功能）：用系统的主体识别（Vision 的前景实例遮罩，同「照片」里的「拷贝主体」，本机跑、不用下模型）
// 把主体抠出来，背景换成透明或白色，可以裁到主体的边上。结果存成 PNG（留得住透明）「原名-去背景.png」放在原图旁边，原图不动。
// 认不出主体（风景、纯色、文字截图）时那一行写「没认出主体」。

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

nonisolated enum Cutout {
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
    case unwritable

    var errorDescription: String? {
      switch self {
      case .unreadable: "读不出这张图。"
      case .noSubject: "没认出主体。"
      case .unwritable: "存不下去背景的结果。"
      }
    }
  }

  @concurrent static func remove(_ source: URL, background: Background, crop: Bool) async throws
    -> URL
  {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = ImageConverter.upright(input, at: 0)
    else { throw Failure.unreadable }
    let subject = try cutout(image, crop: crop)
    var output = CIImage(cgImage: subject)
    if background == .white {
      output = output.composited(over: CIImage(color: .white).cropped(to: output.extent))
    }
    guard
      let result = CIContext().createCGImage(
        output, from: output.extent, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    else { throw Failure.unwritable }
    let target = source.deletingPathExtension().appendingPathExtension("png").adding("-去背景")
      .uniqued()
    guard
      let destination = CGImageDestinationCreateWithURL(
        target as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure.unwritable }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: target)
      throw Failure.unwritable
    }
    return target
  }

  /// 主体抠出来（背景透明）；crop：裁到主体的外接框
  static func cutout(_ image: CGImage, crop: Bool) throws -> CGImage {
    let handler = VNImageRequestHandler(cgImage: image)
    let request = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
      throw Failure.noSubject
    }
    let buffer = try observation.generateMaskedImage(
      ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: crop)
    let masked = CIImage(cvPixelBuffer: buffer)
    guard
      let result = CIContext().createCGImage(
        masked, from: masked.extent, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    else { throw Failure.unwritable }
    return result
  }
}
