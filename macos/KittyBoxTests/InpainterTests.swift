// Inpainter / EraseModel：裁哪一块（留上下文、尽量正方形、不出图）、笔画画成的遮罩和它的外接框；
// 再真的跑一次 LaMa（模型已经下载过才跑，见 AIModelTests）：平滑底色上一个红方块，涂住补掉，红没了、像底色，
// 涂的范围外一个像素都不动；撤销先撤笔画再撤擦除。
// 撤销只记补过的那一块：按笔画算的外接框盖得住画出来的遮罩、只画那一块的遮罩和整张裁出来的一样、贴回去像素一个不差；
// 真擦两笔（快速模型下载过才跑）：撤销、重做后的像素对得上、全撤完就是原图、记下的只有几块小图；补的时候换了图，结果不落到新图上；
// 存过之后不算「没存」，原图不在了说清楚。

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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

  @Test(.enabled(if: AIModel.standard.isInstalled)) func erasesRedSquare() async throws {
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

  /// 按笔画算的外接框盖得住真画出来的遮罩；只画 crop 那一块的遮罩和整张画了再裁一样
  @Test func maskInCrop() throws {
    let strokes: [EraseModel.Stroke] = [
      .init(points: [CGPoint(x: 120, y: 80), CGPoint(x: 260, y: 140)], width: 36),
      .init(points: [CGPoint(x: 300, y: 60)], width: 12),
    ]
    let full = EraseModel.mask(strokes, width: 500, height: 300)
    let drawn = try #require(Inpainter.bounds(of: full))
    let box = EraseModel.bounds(of: strokes)
    #expect(box.contains(drawn), "\(box) \(drawn)")
    #expect(box.insetBy(dx: 2, dy: 2).width <= drawn.width)
    let crop = Inpainter.cropRect(around: box, in: CGSize(width: 500, height: 300))
    let part = EraseModel.mask(strokes, in: crop)
    #expect(part.width == Int(crop.width) && part.height == Int(crop.height))
    #expect(gray(part) == gray(try #require(full.cropping(to: crop))))
  }

  /// 撤销贴回去的那一块：换掉（透明的也还原），块外一个像素都不动
  @Test func patchRoundTrip() throws {
    let before = try #require(Self.photo(width: 300, height: 200))
    let rect = CGRect(x: 40, y: 30, width: 100, height: 80)
    let patch = EraseModel.Patch(rect: rect, pixels: EraseModel.copy(before, rect))
    // 块里涂成半透明的绿
    let context = Inpainter.canvas(like: before, width: 300, height: 200)
    context.draw(before, in: CGRect(x: 0, y: 0, width: 300, height: 200))
    context.setBlendMode(.copy)
    context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.5))
    context.fill(CGRect(x: 40, y: 200 - 110, width: 100, height: 80))
    let changed = try #require(context.makeImage())
    #expect(rgba(changed) != rgba(before))
    #expect(rgba(EraseModel.paste(patch, over: changed)) == rgba(before))
  }

  /// 真擦两笔：撤销、重做的像素对得上，全撤完就是载入时那张，历史里只是几块小图
  @Test(.enabled(if: AIModel.fast.isInstalled)) func undoRedoPixels() async throws {
    let root = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "图.png")
    try Self.write(try #require(Self.photo(width: 2000, height: 1500)), to: url, type: .png)
    let model = EraseModel()
    try await load(url, into: model)
    let original = try #require(model.image)
    model.strokes = [.init(points: [CGPoint(x: 300, y: 300)], width: 60)]
    await model.erase(using: .fast)
    let first = rgba(try #require(model.image))
    model.strokes = [.init(points: [CGPoint(x: 1500, y: 1100)], width: 60)]
    await model.erase(using: .fast)
    let second = rgba(try #require(model.image))
    #expect(model.history.count == 2 && first != second)
    // 记的是两块小图，不是两张整图（原来 2000×1500 一笔 12 MB）
    let kept = model.history.reduce(0) { $0 + $1.pixels.bytesPerRow * $1.pixels.height }
    #expect(kept < 1_000_000, "\(kept)")

    model.undo()
    #expect(rgba(try #require(model.image)) == first)
    model.undo()
    #expect(model.image === original)
    #expect(!model.unsaved)
    model.redo()
    #expect(rgba(try #require(model.image)) == first)
    model.redo()
    #expect(rgba(try #require(model.image)) == second)
    #expect(model.unsaved)
  }

  /// 补的时候换了一张：这一笔的结果不落到新图上（原来新图底下垫了旧图、「存储」存出旧图的像素）
  @Test(.enabled(if: AIModel.fast.isInstalled)) func loadWhileErasing() async throws {
    let root = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, b) = (root.appending(path: "a.png"), root.appending(path: "b.png"))
    for url in [a, b] {
      try Self.write(try #require(Self.photo(width: 900, height: 600)), to: url, type: .png)
    }
    let model = EraseModel()
    try await load(a, into: model)
    model.strokes = [.init(points: [CGPoint(x: 450, y: 300)], width: 80)]
    let erasing = Task { await model.erase(using: .fast) }
    await Task.yield()
    #expect(model.busy)
    model.load(b)  // 还没擦完，没有要存的：不问
    await erasing.value
    try await load(b, into: model, again: false)
    #expect(model.source == b)
    #expect(model.history.isEmpty && !model.unsaved)
    #expect(model.image === model.original)
  }

  /// 存过之后不算没存（「存储」灰掉、换图不问）；原图不在了，状态栏说清楚
  @Test(.enabled(if: AIModel.fast.isInstalled)) func saveState() async throws {
    let root = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "照片.jpg")
    try Self.write(try #require(Self.photo(width: 800, height: 600)), to: url, type: .jpeg)
    let model = EraseModel()
    try await load(url, into: model)
    model.strokes = [.init(points: [CGPoint(x: 400, y: 300)], width: 50)]
    await model.erase(using: .fast)
    #expect(model.unsaved)
    model.save()
    guard case .saved(let saved) = model.state else {
      Issue.record("\(model.state)")
      return
    }
    #expect(saved.lastPathComponent == "照片-去水印.jpg")
    #expect(!model.unsaved)
    #expect(model.mayDiscard())
    // 存过再撤销、重做看一眼：回到存的那步，还是不算没存（撤销、重做每次都出一张新图）
    model.undo()
    model.redo()
    #expect(!model.unsaved)
    // 撤销到存之前、另擦一笔：存的那步回不去了，算没存（步数一样也算）
    model.undo()
    model.strokes = [.init(points: [CGPoint(x: 600, y: 150)], width: 50)]
    await model.erase(using: .fast)
    #expect(model.history.count == 1 && model.unsaved)

    model.strokes = [.init(points: [CGPoint(x: 100, y: 100)], width: 50)]
    await model.erase(using: .fast)
    try FileManager.default.removeItem(at: url)
    model.save()
    guard case .failed(let reason) = model.state else {
      Issue.record("\(model.state)")
      return
    }
    #expect(reason.contains("照片.jpg"))
    #expect(model.unsaved)
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

  // MARK: 帮手

  private func sandbox() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// load 是异步读图的：等它读完（again: false 是已经调过 load、只等）
  private func load(_ url: URL, into model: EraseModel, again: Bool = true) async throws {
    if again { model.load(url) }
    for _ in 0..<200 {
      guard case .loading = model.state else { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.image != nil)
  }

  /// 有纹理的图（竖条纹 + 渐变）
  private static func photo(width: Int, height: Int) -> CGImage? {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    for x in stride(from: 0, to: width, by: 10) {
      context?.setFillColor(
        CGColor(
          red: CGFloat(x % 70) / 70, green: CGFloat(x % 50) / 50, blue: 0.4, alpha: 1))
      context?.fill(CGRect(x: x, y: 0, width: 10, height: height))
    }
    return context?.makeImage()
  }

  private static func write(_ image: CGImage, to url: URL, type: UTType) throws {
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  /// 画成 sRGB 8 位 RGBA 的字节，比像素用
  private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes {
      CGContext(
        data: $0.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  private func gray(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height)
    bytes.withUnsafeMutableBytes {
      CGContext(
        data: $0.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }
}
