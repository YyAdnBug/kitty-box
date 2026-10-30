// 画笔擦除（D2、D3）：拖进一张图，在上面涂住要擦掉的地方（能调笔刷、⌘Z 撤销），点「擦除」交给 Inpainter 补；
// 擦完还能接着涂下一处，撤销也能退回上一次擦除。满意了点「存成」，另存成「原名-去水印」，原图不动。
// 涂的笔画存原图的像素坐标；笔刷大小按屏幕上看着的粗细，落笔时换算成原图像素。
// 补图模型第一次用要先下载（LaMaModel，约 216 MB）：没下时页面顶上一条「下载」，下好之前能涂、不能擦。

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class EraseModel {
  struct Stroke {
    /// 原图像素坐标，左上为原点
    var points: [CGPoint]
    var width: CGFloat
  }

  enum State {
    case idle
    case loading
    case erasing
    case saved(URL)
    case failed(String)
  }

  private(set) var source: URL?
  /// 当前的图（擦过几次就是擦过的结果）
  private(set) var image: CGImage?
  /// 每次擦除前的图，撤销用
  private(set) var history: [CGImage] = []
  var strokes: [Stroke] = []
  private(set) var state = State.idle

  var busy: Bool {
    switch state {
    case .loading, .erasing: true
    default: false
    }
  }

  func load(_ url: URL) {
    source = url
    image = nil
    history = []
    strokes = []
    state = .loading
    Task {
      let loaded = await Self.read(url)
      guard source == url else { return }
      image = loaded
      state = loaded == nil ? .failed("读不出这张图。") : .idle
    }
  }

  func erase() async {
    guard let image, !strokes.isEmpty, !busy else { return }
    state = .erasing
    do {
      let mask = Self.mask(strokes, width: image.width, height: image.height)
      let result = try await Inpainter.shared.erase(image, mask: mask)
      history.append(image)
      self.image = result
      strokes = []
      state = .idle
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// 先撤笔画，没有笔画了再退回上一次擦除
  func undo() {
    if !strokes.isEmpty {
      strokes.removeLast()
    } else if let previous = history.popLast() {
      image = previous
    }
  }

  func save() {
    guard let source, let image, let input = CGImageSourceCreateWithURL(source as CFURL, nil) else {
      return
    }
    let target = source.adding("-去水印").uniqued()
    state =
      ImageConverter.save(image, like: input, to: target) ? .saved(target) : .failed("存不下去。")
  }

  @concurrent nonisolated private static func read(_ url: URL) async -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { ImageConverter.upright($0, at: 0) }
  }

  /// 笔画画成和原图一样大的遮罩：白 = 要补，圆头圆角
  nonisolated static func mask(_ strokes: [Stroke], width: Int, height: Int) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    // 翻成左上原点，和笔画的坐标一致
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setStrokeColor(gray: 1, alpha: 1)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for stroke in strokes {
      context.setLineWidth(stroke.width)
      guard let first = stroke.points.first else { continue }
      context.move(to: first)
      // 只点了一下：画个点
      for point in stroke.points.count == 1 ? [first] : Array(stroke.points.dropFirst()) {
        context.addLine(to: point)
      }
      context.strokePath()
    }
    return context.makeImage()!
  }
}

struct EraseCanvas: View {
  @Bindable var model: EraseModel
  @Bindable private var download = LaMaDownload.shared
  @State private var choosing = false
  /// 笔刷在屏幕上的粗细（点）
  @State private var brush: CGFloat = 28
  @State private var drawing: EraseModel.Stroke?
  @State private var hover: CGPoint?

  var body: some View {
    VStack(spacing: 0) {
      if download.state != .ready {
        modelBanner.padding(.horizontal, 20).padding(.vertical, 10)
        Divider()
      }
      if model.source == nil {
        DropHint(text: "把图片拖到这里，涂住要擦掉的地方", symbol: "paintbrush.pointed") { choosing = true }
          .padding(20)
        Spacer()
      } else if let image = model.image {
        canvas(image).padding(16)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      footer.padding(.horizontal, 20).padding(.vertical, 12)
    }
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) {
      if case .success(let url) = $0 { model.load(url) }
    }
  }

  private func canvas(_ image: CGImage) -> some View {
    GeometryReader { geometry in
      let size = CGSize(width: image.width, height: image.height)
      let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
      let origin = CGPoint(
        x: (geometry.size.width - size.width * scale) / 2,
        y: (geometry.size.height - size.height * scale) / 2)
      let toImage = { (point: CGPoint) in
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
      }
      ZStack(alignment: .topLeading) {
        Image(decorative: image, scale: 1)
          .resizable()
          .frame(width: size.width * scale, height: size.height * scale)
          .offset(x: origin.x, y: origin.y)
        // 笔画用普通的 Path 叠上去（不用 Canvas：屏外截图自检抓不到 Canvas，整页会画坏，2026-10-30 实测）
        ForEach(Array((model.strokes + (drawing.map { [$0] } ?? [])).enumerated()), id: \.offset) {
          _, stroke in
          Path { path in
            let points = stroke.points.map {
              CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale)
            }
            path.addLines(points.count == 1 ? [points[0], points[0]] : points)
          }
          .stroke(
            Color.accentColor.opacity(0.5),
            style: StrokeStyle(lineWidth: stroke.width * scale, lineCap: .round, lineJoin: .round)
          )
          .allowsHitTesting(false)
        }
        if let hover {
          Circle().stroke(.white, lineWidth: 1.5)
            .overlay { Circle().stroke(.black.opacity(0.5), lineWidth: 1).padding(-1) }
            .frame(width: brush, height: brush)
            .position(hover)
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in
            let point = toImage(drag.location)
            if drawing == nil { drawing = .init(points: [], width: brush / scale) }
            drawing?.points.append(point)
            hover = drag.location
          }
          .onEnded { _ in
            if let drawing { model.strokes.append(drawing) }
            drawing = nil
          }
      )
      .onContinuousHover { phase in
        if case .active(let point) = phase { hover = point } else { hover = nil }
      }
      .disabled(model.busy)
    }
  }

  /// 模型还没下好时顶上的一条
  @ViewBuilder private var modelBanner: some View {
    switch download.state {
    case .ready:
      EmptyView()
    case .missing:
      HStack(spacing: 10) {
        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        Text(
          "画笔擦除要用一个补图模型（约 \(LaMaModel.downloadSize.formatted(.byteCount(style: .file)))），第一次用先下载，之后不用联网。"
        )
        .font(.callout)
        Spacer()
        Button("下载") { Task { await download.start() } }.buttonStyle(.borderedProminent)
      }
    case .downloading(let fraction):
      ProgressView(value: fraction) {
        Text("正在下载补图模型 · \(Int((fraction * 100).rounded()))%（下完还要编译几秒）").font(.caption)
      }
    case .failed(let reason):
      HStack(spacing: 10) {
        Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
          .font(.callout).lineLimit(2)
        Spacer()
        Button("重试") { Task { await download.start() } }
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Text("笔刷")
        Slider(value: $brush, in: 8...96).frame(width: 140)
        Button("撤销") { model.undo() }
          .keyboardShortcut("z", modifiers: .command)
          .disabled(model.busy || (model.strokes.isEmpty && model.history.isEmpty))
        Spacer()
        if model.source != nil { Button("换一张…") { choosing = true }.disabled(model.busy) }
        Button("存成「-去水印」") { model.save() }.disabled(model.busy || model.history.isEmpty)
        if model.busy { ProgressView().controlSize(.small) }
        Button("擦除") { Task { await model.erase() } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(model.strokes.isEmpty || model.busy || download.state != .ready)
      }
      switch model.state {
      case .saved(let url):
        HStack {
          Label("存成「\(url.lastPathComponent)」", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .buttonStyle(.link)
        }
        .font(.caption)
      case .failed(let reason):
        Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption)
          .foregroundStyle(.red)
      case .erasing:
        Text("正在补，一处大约一秒…").font(.caption).foregroundStyle(.secondary)
      case .idle, .loading:
        Text(
          model.history.isEmpty
            ? "涂住要擦掉的地方（涂得比水印宽一点），点「擦除」；不满意就撤销，接着涂。"
            : "擦了 \(model.history.count) 次。还能接着涂；满意了点「存成」，原图不动。"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
