// 画笔擦除（D2、D3）：拖进一张图，涂住要擦掉的地方，松手就交给 Inpainter 补（照系统照片的「清理」：一笔一擦，不用再点按钮）；
// ⌘Z 一次退回一笔、⇧⌘Z 重做；满意了点页头「存储」，另存成「原名-去水印」，原图不动。
// 画布能放大（捏合、⌘= / ⌘-，⌘0 回到适合窗口），放大后用触控板 / 滚轮挪；底下浮着一条控制栏：笔刷大小（[ ] 也能调）、撤销、
// 对比（最早的原图和现在的，拖中间的线看）、缩放。涂的笔画存原图的像素坐标；笔刷大小按屏幕上看着的粗细，落笔时换算成原图像素。
// 补图用设置 › 模型里选的那个（AIModel）；第一次用要先下载：没下时页面顶上一条「下载」「换一个模型」，下好之前不能涂。
// 「选文字」（M9，用户问「不是 AI 生成的字怎么去除」）：用系统的文字识别（AIMark.lines）把图上的字一行一行框出来，点哪行擦哪行
// （盖住那一行的一笔，走同一条补图的路，⌘Z 照样退回）；再点一下按钮回到涂抹。
// 撤销只记补过的那一块原来的像素（Patch），不记整张：原来每笔存一整张，24 MP 的图擦 20 笔常驻约 2 GB（实测）。
// 擦过还没存时换图（拖进来、⌘O、⌘V、改用画笔擦除）先问一声；补的时候换了图，这一笔作废，不落到新图上。

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

  /// 撤销、重做的一步：rect（原图像素、左上为原点）那一块换上去之前的像素
  struct Patch {
    let rect: CGRect
    let pixels: CGImage
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
  /// 载入时的那张：「对比原图」、全撤销掉时原样还回去
  private(set) var original: CGImage?
  /// 每次擦除前那一块，撤销用
  private(set) var history: [Patch] = []
  /// 撤销掉的擦除，重做用（再擦一笔就清空）
  private(set) var undone: [Patch] = []
  /// 存的时候擦到了第几步：回到这一步（撤销再重做也算）就是没改，「存储」灰掉，换图不问。
  /// 不比是不是同一张图：撤销、重做每次都出一张新的，存过再 ⌘Z、⇧⌘Z 看一眼就又算没存了
  private var savedDepth: Int?
  var strokes: [Stroke] = []
  private(set) var state = State.idle
  /// 画布上是不是在前后对比（关掉才能接着涂）
  var comparing = false
  /// 「选文字」找到的各行字（原图像素、左上为原点）；nil 是没在选文字
  private(set) var texts: [CGRect]?
  private(set) var findingText = false

  var busy: Bool {
    switch state {
    case .loading, .erasing: true
    default: false
    }
  }

  /// 擦过、还没存
  var unsaved: Bool { !history.isEmpty && history.count != savedDepth }

  /// 关掉这一张（读不出时回到空着的样子）
  func clear() {
    texts = nil
    source = nil
    image = nil
    original = nil
    savedDepth = nil
    history = []
    undone = []
    strokes = []
    comparing = false
    state = .idle
  }

  /// 换一张（所有来路都经过这里）；擦过还没存时先问，选了「取消」就不换
  func load(_ url: URL) {
    guard mayDiscard() else { return }
    clear()
    source = url
    state = .loading
    Task {
      let loaded = await Self.read(url)
      guard source == url else { return }
      image = loaded
      original = loaded
      state = loaded == nil ? .failed("读不出这张图。") : .idle
    }
  }

  /// 擦过还没存：换图前问一声（同系统的「要存储修改吗」）；true = 可以丢掉
  func mayDiscard() -> Bool {
    guard unsaved, let name = source?.lastPathComponent else { return true }
    let alert = NSAlert()
    alert.messageText = "要存储对「\(name)」的修改吗？"
    alert.informativeText = "不存储的话，擦过的地方都会还原。"
    alert.addButton(withTitle: "存储")
    alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
    let discard = alert.addButton(withTitle: "不存储")
    discard.keyEquivalent = "d"
    discard.keyEquivalentModifierMask = .command
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      save()
      return !unsaved  // 存不下去就不换
    case .alertThirdButtonReturn: return true
    default: return false
    }
  }

  func erase(using choice: AIModel = .standard) async {
    guard let image, !strokes.isEmpty, !busy else { return }
    let size = CGSize(width: image.width, height: image.height)
    let box = Self.bounds(of: strokes).intersection(CGRect(origin: .zero, size: size))
    // 整笔涂在图外面：没什么可补
    guard !box.isEmpty else {
      strokes = []
      return
    }
    // 只画要补的那一块的遮罩（原来画整张再逐像素找外接框，36 MP 的图 Debug 下一笔要多等 4 秒）
    let crop = Inpainter.cropRect(around: box, in: size)
    state = .erasing
    do {
      let result = try await Inpainter.shared.erase(
        image, in: crop, mask: Self.mask(strokes, in: crop), using: choice)
      // 补的时候换了一张（拖进来、⌘V、改用画笔擦除）：这一笔作废，不落到新图上
      guard self.image === image else { return }
      // 存的那步在重做里（撤销到存之前又擦了一笔）：重做清掉了，那步回不去了
      if (savedDepth ?? 0) > history.count { savedDepth = nil }
      history.append(Patch(rect: crop, pixels: Self.copy(image, crop)))
      undone = []
      self.image = result
      strokes = []
      state = .idle
    } catch {
      guard self.image === image else { return }
      state = .failed(error.localizedDescription)
    }
  }

  /// 「选文字」：找出图上的字
  func findText() async {
    guard let image else { return }
    texts = []
    findingText = true
    let found = await Self.lines(in: image)
    findingText = false
    // 找的时候换了图：框是旧图上的，不要
    if texts != nil, self.image === image { texts = found }
  }

  func stopFindingText() { texts = nil }

  /// 点了一行字：一笔盖住它补掉
  func erase(text box: CGRect, using choice: AIModel) async {
    strokes = [Self.stroke(covering: box)]
    texts?.removeAll { $0 == box }
    await erase(using: choice)
  }

  /// 盖住一行字的一笔：横穿中线，粗 1.6 倍字高（上下各多出三成），两头的圆角也盖得住字框的四个角
  nonisolated static func stroke(covering box: CGRect) -> Stroke {
    Stroke(
      points: [CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY)],
      width: box.height * 1.6)
  }

  @concurrent nonisolated private static func lines(in image: CGImage) async -> [CGRect] {
    ((try? AIMark.lines(in: image)) ?? []).map(\.rect)
  }

  /// 先撤笔画，没有笔画了再退回上一次擦除（把那一块原来的像素贴回去；全撤完就是载入时那张）
  func undo() {
    if !strokes.isEmpty {
      strokes.removeLast()
    } else if let patch = history.popLast(), let current = image {
      undone.append(Patch(rect: patch.rect, pixels: Self.copy(current, patch.rect)))
      image = history.isEmpty ? original : Self.paste(patch, over: current)
      if history.isEmpty { comparing = false }
    }
  }

  /// 重做撤销掉的那一次擦除
  func redo() {
    guard let patch = undone.popLast(), let current = image else { return }
    history.append(Patch(rect: patch.rect, pixels: Self.copy(current, patch.rect)))
    image = Self.paste(patch, over: current)
  }

  /// 另存成「原名-去水印」；存不成时状态栏说清楚为什么
  func save() {
    guard let source, let image else { return }
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      CGImageSourceGetType(input) != nil
    else {
      state = .failed("原图「\(source.lastPathComponent)」不在原处了（挪走或删掉了），没存。")
      return
    }
    let target = source.adding("-去水印").uniqued()
    guard ImageConverter.save(image, like: input, to: target) else {
      state = .failed("没存成「\(target.lastPathComponent)」：系统写不了这种格式，或者这个文件夹不让写。")
      return
    }
    savedDepth = history.count
    state = .saved(target)
  }

  @concurrent nonisolated private static func read(_ url: URL) async -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { ImageConverter.upright($0, at: 0) }
  }

  /// 笔画的外接框（原图像素、左上为原点）：每个点四周各半个笔宽（圆头），取整到盖住的整像素
  nonisolated static func bounds(of strokes: [Stroke]) -> CGRect {
    strokes.reduce(CGRect.null) { box, stroke in
      stroke.points.reduce(box) {
        $0.union(
          CGRect(origin: $1, size: .zero).insetBy(dx: -stroke.width / 2, dy: -stroke.width / 2))
      }
    }.integral
  }

  /// image 里 rect 那一块，画进自己的小画布（cropping 出来的和整张共用内存，存它等于存整张）
  nonisolated static func copy(_ image: CGImage, _ rect: CGRect) -> CGImage {
    let context = Inpainter.canvas(like: image, width: Int(rect.width), height: Int(rect.height))
    context.draw(image.cropping(to: rect)!, in: CGRect(origin: .zero, size: rect.size))
    return context.makeImage()!
  }

  /// 把那一块贴回 image（换掉，不叠：透明的地方也还原），出一张新的整图
  nonisolated static func paste(_ patch: Patch, over image: CGImage) -> CGImage {
    let context = Inpainter.canvas(like: image, width: image.width, height: image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.setBlendMode(.copy)
    // CG 的原点在左下
    context.draw(
      patch.pixels,
      in: CGRect(
        x: patch.rect.minX, y: CGFloat(image.height) - patch.rect.maxY, width: patch.rect.width,
        height: patch.rect.height))
    return context.makeImage()!
  }

  /// 笔画画成和原图一样大的遮罩：白 = 要补，圆头圆角
  nonisolated static func mask(_ strokes: [Stroke], width: Int, height: Int) -> CGImage {
    mask(strokes, in: CGRect(x: 0, y: 0, width: width, height: height))
  }

  /// 笔画画成 rect（原图像素、左上为原点）那一块的遮罩，和那一块一样大
  nonisolated static func mask(_ strokes: [Stroke], in rect: CGRect) -> CGImage {
    let context = CGContext(
      data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    // 翻成左上原点、挪到这一块，和笔画的坐标一致
    context.translateBy(x: -rect.minX, y: rect.maxY)
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
  @Bindable private var downloads = ModelDownloads.shared
  @AppStorage(Prefs.inpaintModel) private var choice = AIModel.standard
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
        // 存过之后没再改就灰掉：再按一次只会多出一份「-去水印 2」
        .disabled(model.busy || !model.unsaved)
    } content: {
      VStack(spacing: 0) {
        if downloads.state(of: choice) != .ready {
          ModelBanner(choice: choice).padding(.horizontal, 20).padding(.vertical, 12)
          Hairline()
        }
        if model.source == nil {
          DropZone(
            tool: .erase, title: "拖入一张图",
            detail: "一次一张；能放大了涂细处，⌘Z 一笔一笔退回，结果另存成「原名-去水印」")
        } else if let image = model.image {
          ZStack(alignment: .bottom) {
            if model.comparing, let original = model.original {
              CompareSlider(before: original, after: image).padding(20).padding(.bottom, 56)
            } else {
              canvas(image)
            }
            controls.padding(.bottom, 14)
          }
        } else if case .failed(let reason) = model.state {
          LoadFailed(reason: reason, again: "换一张…") { model.clear() }
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
    let painting = downloads.state(of: choice) == .ready && !model.busy
    return ZStack(alignment: .topLeading) {
      Image(decorative: image, scale: 1).resizable()
      // 笔画用普通的 Path 叠上去（不用 Canvas：屏外截图自检抓不到 Canvas，整页会画坏，2026-10-30 实测）
      strokes(scale: scale)
        .modifier(Pulsing(active: model.busy && !reduceMotion))
      if let texts = model.texts {
        ForEach(Array(texts.enumerated()), id: \.offset) { _, box in
          Button {
            Task { await model.erase(text: box, using: choice) }
          } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(Color.accentColor.opacity(0.18))
              .strokeBorder(Color.accentColor, lineWidth: 1.5)
          }
          .buttonStyle(.plain)
          .frame(width: box.width * scale + 8, height: box.height * scale + 8)
          .position(x: box.midX * scale, y: box.midY * scale)
          .help("擦掉这行字")
        }
      } else if let hover, painting {
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
    // 选文字时不涂，只点框
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
            Task { await model.erase(using: choice) }
          }
          drawing = nil
        },
      including: model.texts == nil ? .all : .subviews
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
      Button("重做", systemImage: "arrow.uturn.forward") { model.redo() }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .help("重做（⇧⌘Z）")
        .disabled(model.busy || model.undone.isEmpty)
      Toggle(
        "选文字", systemImage: "text.viewfinder",
        isOn: Binding(
          get: { model.texts != nil },
          set: { on in
            if on { Task { await model.findText() } } else { model.stopFindingText() }
          })
      )
      .toggleStyle(.button)
      .help("找出图上的字，点哪行擦哪行")
      .disabled(model.busy || model.comparing)
      Toggle("对比原图", systemImage: "rectangle.split.2x1", isOn: $model.comparing)
        .toggleStyle(.button)
        .help("拖中间的线对比原图")
        .disabled(model.history.isEmpty)
      // 对比时用对比图自己的缩放（图下面靠右那一条），这一组不显示（原来灰着摆在那，同屏两套缩放）
      if !model.comparing {
        Divider().frame(height: 18)
        Button("缩小", systemImage: "minus.magnifyingglass") { zoom = max(1, zoom / 1.5) }
          .keyboardShortcut("-")
          .help("缩小（⌘-）")
          .disabled(zoom <= 1)
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
        Button("放大", systemImage: "plus.magnifyingglass") { zoom = min(8, zoom * 1.5) }
          .keyboardShortcut("=")
          .help("放大（⌘=）")
          .disabled(zoom >= 8)
      }
    }
    .labelStyle(.iconOnly)
    // 系统附件栏的按钮：点得到的地方比图标大，「选文字」「对比原图」打开时有一块底（原来只是图标变色，色弱分不清开没开）
    .buttonStyle(.accessoryBar)
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
    case .idle where model.texts != nil:
      if model.findingText {
        Text("正在找图上的字…")
      } else if model.texts?.isEmpty == true {
        Text("没找到字；再点一下「选文字」回到涂抹")
      } else {
        Text("找到 \(model.texts?.count ?? 0) 行字：点框住的那行擦掉；再点一下「选文字」回到涂抹")
      }
    case .idle, .loading:
      Text(
        [
          model.source?.lastPathComponent,
          model.history.isEmpty ? nil : "擦了 \(model.history.count) 处",
          "涂住要擦掉的地方，松手自动补；⌘Z 撤销，[ ] 调笔刷，捏合放大",
        ].compactMap(\.self).joined(separator: " · "))
    }
  }
}

/// 模型还没下好时页面顶上的一条（画笔擦除、AI 水印、去背景）：说要下哪个、多大，「下载」「换一个模型…」（补图模型才有），下载中是进度条
struct ModelBanner: View {
  let choice: AIModel
  /// 一句话说用它干什么（画笔擦除不用写）
  var purpose: String?
  @Bindable private var downloads = ModelDownloads.shared
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    switch downloads.state(of: choice) {
    case .ready:
      EmptyView()
    case .missing:
      HStack(spacing: 10) {
        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        Text(
          (purpose.map { $0 + "。" } ?? "")
            + "要先下载\(choice.kind)「\(choice.title) · \(choice.name)」（约 \(choice.downloadSize.formatted(.byteCount(style: .file)))），之后不用联网。"
        )
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        Spacer()
        if choice != .cutout { Button("换一个模型…") { openSettings() } }
        Button("下载") { downloads.start(choice) }.buttonStyle(BrandButtonStyle())
      }
    case .downloading(let fraction):
      HStack(spacing: 10) {
        ProgressView(value: fraction) {
          Text("正在下载\(choice.kind)「\(choice.title)」· \(Int((fraction * 100).rounded()))%（下完还要编译几秒）")
            .font(.caption)
        }
        Button("取消") { downloads.cancel(choice) }
      }
    case .failed(let reason):
      HStack(spacing: 10) {
        Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
          .font(.callout).lineLimit(2)
        Spacer()
        Button("重试") { downloads.start(choice) }
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
