// 画笔擦除（D2、D3）：拖进一张图，涂住要擦掉的地方，松手就交给 Inpainter 补（照系统照片的「清理」：一笔一擦，不用再点按钮）；
// ⌘Z 一次退回一笔；满意了点页头「存储」，另存成「原名-去水印」，原图不动。
// 画布能放大（捏合、⌘= / ⌘-，⌘0 回到适合窗口），放大后用触控板 / 滚轮挪；底下浮着一条控制栏：笔刷大小（[ ] 也能调）、撤销、
// 对比（最早的原图和现在的，拖中间的线看）、缩放。涂的笔画存原图的像素坐标；笔刷大小按屏幕上看着的粗细，落笔时换算成原图像素。
// 补图模型第一次用要先下载（LaMaModel，约 216 MB）：没下时页面顶上一条「下载」，下好之前不能涂。

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
  /// 画布上是不是在前后对比（关掉才能接着涂）
  var comparing = false

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
    comparing = false
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
      if history.isEmpty { comparing = false }
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
  /// 笔刷在屏幕上的粗细（点）
  @State private var brush: CGFloat = 32
  @State private var drawing: EraseModel.Stroke?
  @State private var hover: CGPoint?
  /// 放大倍数：1 = 整张放得下
  @State private var zoom: CGFloat = 1
  @State private var pinchStart: CGFloat?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ToolPage(tool: .erase) {
      Button("换一张…", systemImage: "photo.badge.plus") { Navigator.shared.importing = true }
        .help("换一张图（⌘O）")
        .disabled(model.busy)
      Button("存储") { model.save() }
        .buttonStyle(BrandButtonStyle())
        .keyboardShortcut("s")
        .help("另存成「原名-去水印」（⌘S）")
        .disabled(model.busy || model.history.isEmpty)
    } content: {
      VStack(spacing: 0) {
        if download.state != .ready {
          modelBanner.padding(.horizontal, 20).padding(.vertical, 12)
          Hairline()
        }
        if model.source == nil {
          DropZone(
            tool: .erase, title: "拖入一张图",
            detail: "一次一张；能放大了涂细处，⌘Z 一笔一笔退回，结果另存成「原名-去水印」")
        } else if let image = model.image {
          ZStack(alignment: .bottom) {
            if model.comparing, let original = model.history.first {
              CompareSlider(before: original, after: image).padding(20).padding(.bottom, 56)
            } else {
              canvas(image)
            }
            controls.padding(.bottom, 14)
          }
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    } status: {
      status
    }
    .onChange(of: model.source) { zoom = 1 }
  }

  // MARK: 画布

  private func canvas(_ image: CGImage) -> some View {
    GeometryReader { geometry in
      let size = CGSize(width: image.width, height: image.height)
      let fit = min(
        (geometry.size.width - 40) / size.width, (geometry.size.height - 96) / size.height)
      let scale = max(fit, 0.01) * zoom
      ScrollView([.horizontal, .vertical]) {
        paper(image, scale: scale)
          .frame(width: size.width * scale, height: size.height * scale)
          .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 76)
          .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
      }
      .scrollIndicators(zoom > 1 ? .automatic : .never)
      .simultaneousGesture(
        MagnifyGesture()
          .onChanged { value in
            let start = pinchStart ?? zoom
            pinchStart = start
            zoom = min(max(start * value.magnification, 1), 8)
          }
          .onEnded { _ in pinchStart = nil }
      )
    }
  }

  /// 图 + 涂的笔画 + 笔刷圈，坐标是这张图在屏幕上的点（原图像素 × scale）
  private func paper(_ image: CGImage, scale: CGFloat) -> some View {
    let painting = download.state == .ready && !model.busy
    return ZStack(alignment: .topLeading) {
      Image(decorative: image, scale: 1).resizable()
      // 笔画用普通的 Path 叠上去（不用 Canvas：屏外截图自检抓不到 Canvas，整页会画坏，2026-10-30 实测）
      strokes(scale: scale)
        .modifier(Pulsing(active: model.busy && !reduceMotion))
      if let hover, painting {
        Circle().stroke(.white, lineWidth: 1.5)
          .overlay { Circle().stroke(.black.opacity(0.5), lineWidth: 1).padding(-1) }
          .frame(width: brush, height: brush)
          .position(hover)
          .allowsHitTesting(false)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { drag in
          let point = CGPoint(x: drag.location.x / scale, y: drag.location.y / scale)
          if drawing == nil { drawing = .init(points: [], width: brush / scale) }
          drawing?.points.append(point)
          hover = drag.location
        }
        .onEnded { _ in
          if let drawing {
            model.strokes.append(drawing)
            Task { await model.erase() }
          }
          drawing = nil
        }
    )
    .onContinuousHover { phase in
      if case .active(let point) = phase { hover = point } else { hover = nil }
    }
    .allowsHitTesting(painting)
  }

  private func strokes(scale: CGFloat) -> some View {
    ForEach(Array((model.strokes + (drawing.map { [$0] } ?? [])).enumerated()), id: \.offset) {
      _, stroke in
      Path { path in
        let points = stroke.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        path.addLines(points.count == 1 ? [points[0], points[0]] : points)
      }
      .stroke(
        Color.accentColor.opacity(0.55),
        style: StrokeStyle(lineWidth: stroke.width * scale, lineCap: .round, lineJoin: .round)
      )
      .allowsHitTesting(false)
    }
  }

  // MARK: 浮着的控制栏

  private var controls: some View {
    HStack(spacing: 12) {
      Button("笔刷小一点", systemImage: "minus") { brush = max(8, brush - 8) }
        .keyboardShortcut("[", modifiers: [])
        .help("笔刷小一点（[）")
      Slider(value: $brush, in: 8...120).frame(width: 110)
        .help("笔刷大小")
      Button("笔刷大一点", systemImage: "plus") { brush = min(120, brush + 8) }
        .keyboardShortcut("]", modifiers: [])
        .help("笔刷大一点（]）")
      Divider().frame(height: 18)
      Button("撤销", systemImage: "arrow.uturn.backward") { model.undo() }
        .keyboardShortcut("z")
        .help("撤销（⌘Z）")
        .disabled(model.busy || (model.strokes.isEmpty && model.history.isEmpty))
      Toggle("对比原图", systemImage: "rectangle.split.2x1", isOn: $model.comparing)
        .toggleStyle(.button)
        .help("拖中间的线对比原图")
        .disabled(model.history.isEmpty)
      Divider().frame(height: 18)
      Button("缩小", systemImage: "minus.magnifyingglass") { zoom = max(1, zoom / 1.5) }
        .keyboardShortcut("-")
        .help("缩小（⌘-）")
        .disabled(zoom <= 1 || model.comparing)
      Button(
        zoom == 1 ? "适合" : "\(Double(zoom).formatted(.number.precision(.fractionLength(0...1))))×"
      ) {
        zoom = 1
      }
      .labelStyle(.titleOnly)
      .monospacedDigit()
      .frame(minWidth: 34)
      .keyboardShortcut("0")
      .help("适合窗口（⌘0）")
      .disabled(model.comparing)
      Button("放大", systemImage: "plus.magnifyingglass") { zoom = min(8, zoom * 1.5) }
        .keyboardShortcut("=")
        .help("放大（⌘=）")
        .disabled(zoom >= 8 || model.comparing)
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .controlSize(.small)
    .floatingBar()
  }

  @ViewBuilder private var status: some View {
    switch model.state {
    case .saved(let url):
      DoneLine(text: "存成「\(url.lastPathComponent)」", url: url)
    case .failed(let reason):
      FailLine(reason: reason)
    case .erasing:
      Text("正在补，一处大约一秒…")
    case .idle, .loading:
      Text(
        [
          model.source?.lastPathComponent,
          model.history.isEmpty ? nil : "擦了 \(model.history.count) 处",
          "涂住要擦掉的地方，松手自动补；⌘Z 撤销，[ ] 调笔刷，捏合放大",
        ].compactMap(\.self).joined(separator: " · "))
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
        Button("下载") { Task { await download.start() } }.buttonStyle(BrandButtonStyle())
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

}

/// 补的时候笔画一明一暗地闪（减弱动态效果时不闪）
private struct Pulsing: ViewModifier {
  let active: Bool

  func body(content: Content) -> some View {
    if active {
      content.phaseAnimator([1, 0.35]) { view, phase in
        view.opacity(phase)
      } animation: { _ in
        .easeInOut(duration: 0.6)
      }
    } else {
      content
    }
  }
}
