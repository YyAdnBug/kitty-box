// Inpainter / EraseModel：裁哪一块（留上下文、尽量正方形、不出图）、笔画画成的遮罩和它的外接框；
// 再真的跑一次 LaMa（模型已经下载过才跑，见 LaMaModelTests）：平滑底色上一个红方块，涂住补掉，红没了、像底色，
// 涂的范围外一个像素都不动；撤销先撤笔画再撤擦除。

import CoreGraphics
import Foundation
import Testing

@testable import KittyBox

struct InpainterTests {
  @Test func cropRect() {
    let size = CGSize(width: 1000, height: 700)
    // 小框：至少 256，框在正中
    let small = Inpainter.cropRect(around: CGRect(x: 600, y: 300, width: 60, height: 60), in: size)
    #expect(small == CGRect(x: 502, y: 202, width: 256, height: 256))
    // 贴着右下角：整块挪回图里
    let corner = Inpainter.cropRect(around: CGRect(x: 980, y: 680, width: 20, height: 20), in: size)
    #expect(corner == CGRect(x: 744, y: 444, width: 256, height: 256))
    // 大框：裁到整张图为止
    let big = Inpainter.cropRect(around: CGRect(x: 0, y: 0, width: 900, height: 650), in: size)
    #expect(big == CGRect(origin: .zero, size: size))
  }

  @Test func maskAndBounds() throws {
    let mask = EraseModel.mask(
      [.init(points: [CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 50)], width: 20)], width: 400,
      height: 300)
    let box = try #require(Inpainter.bounds(of: mask))
    // 圆头：左右各多出半个笔宽；坐标是左上原点
    #expect(abs(box.minX - 90) <= 1 && abs(box.maxX - 210) <= 1)
    #expect(abs(box.minY - 40) <= 1 && abs(box.maxY - 60) <= 1)
    #expect(Inpainter.bounds(of: EraseModel.mask([], width: 10, height: 10)) == nil)
  }

  @Test(.enabled(if: LaMaModel.isInstalled)) func erasesRedSquare() async throws {
    let (width, height) = (1000, 700)
    var data = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let red = (600..<660).contains(x) && (300..<360).contains(y)
        let index = (y * width + x) * 4
        (data[index], data[index + 1], data[index + 2]) =
          red ? (255, 0, 0) : (UInt8(x / 4), 120, UInt8(y / 3))
      }
    }
    let image = try #require(
      data.withUnsafeMutableBytes {
        CGContext(
          data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage()
      })
    let mask = EraseModel.mask(
      [.init(points: [CGPoint(x: 590, y: 330), CGPoint(x: 670, y: 330)], width: 80)], width: width,
      height: height)

    let result = try await Inpainter.shared.erase(image, mask: mask)
    let pixels = try #require(GeminiMark.pixels(of: result))
    func rgb(_ x: Int, _ y: Int) -> [Int] {
      let index = (y * width + x) * 4
      return [Int(pixels.data[index]), Int(pixels.data[index + 1]), Int(pixels.data[index + 2])]
    }
    let middle = rgb(630, 330)
    #expect(abs(middle[0] - 157) < 40 && abs(middle[1] - 120) < 40, "\(middle)")
    #expect(rgb(100, 100) == [25, 120, 33])
    #expect(rgb(630, 200) == [157, 120, 66])
  }

  @Test func undoOrder() {
    let model = EraseModel()
    model.strokes = [.init(points: [.zero], width: 4), .init(points: [.zero], width: 4)]
    model.undo()
    #expect(model.strokes.count == 1)
    model.undo()
    #expect(model.strokes.isEmpty)
    model.undo()  // 没有擦过：什么都不做
    #expect(model.history.isEmpty)
  }
}
