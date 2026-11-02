// 前后对比（AI 水印、画笔擦除、视频台标、去背景、图片转换共用；去背景的透明处垫棋盘格）：两张一样大的图叠在一起，中间一条竖线，线左边露原图、右边是去掉之后的；
// 在图上任意处按下左右拖都能挪线。照常见修图工具的样子：线上一个圆把手，左上「原图」、右上「去水印后」（或去背景后、转换后）两个小标签，线挪到边上时那一侧的标签隐去。
// 能放大看细节（M6）：捏合，或图下面靠右的小条（缩小 / 适合 / 1:1 / 放大）；1:1 是一个原图像素对一个屏幕像素，放大后用触控板 / 滚轮挪。

import SwiftUI

struct CompareSlider: View {
  let before: CGImage
  let after: CGImage
  /// 去背景：结果透明的地方垫一层棋盘格（看得出哪里是透明的）
  var checkerboard = false
  /// 右上角那个标签：「去水印后」「去背景后」「转换后」
  var afterLabel = "去水印后"
  /// 线的位置：0 全是去掉之后的，1 全是原图
  @State private var split: CGFloat = 0.5
  /// 放大倍数：1 = 整张放得下
  @State private var zoom: CGFloat = 1
  @State private var pinchStart: CGFloat?
  /// 整张放得下时一个原图像素画多大（图下面那条缩放要用，图的那一块量出来的）
  @State private var fitNow: CGFloat = 1
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    // 缩放的小条在图下面单独一行、靠右：原来浮在整块的右下角，图窄时悬在空白里、图宽时压住图的一角（AI 水印正好在那）
    VStack(alignment: .trailing, spacing: 8) {
      GeometryReader { geometry in
        let image = CGSize(width: after.width, height: after.height)
        let fit = max(
          min(geometry.size.width / image.width, geometry.size.height / image.height), 0.01)
        let size = CGSize(width: image.width * fit * zoom, height: image.height * fit * zoom)
        ScrollView([.horizontal, .vertical]) {
          pane(size)
            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
        }
        .scrollIndicators(zoom > 1 ? .automatic : .never)
        .simultaneousGesture(
          MagnifyGesture()
            .onChanged { value in
              let start = pinchStart ?? zoom
              pinchStart = start
              zoom = clamp(start * value.magnification, fit: fit)
            }
            .onEnded { _ in pinchStart = nil }
        )
        // 只换掉图这一块：挂在整个上面会把缩放的小条也从旁白、全键盘控制里换没
        .accessibilityRepresentation {
          Slider(value: $split, in: 0...1) { Text("原图露出多少") }
        }
        .onChange(of: fit, initial: true) { fitNow = $1 }
      }
      zoomBar(fit: fitNow)
    }
  }

  /// 叠在一起的两张图、竖线、把手、两个标签（size：这次画多大）
  private func pane(_ size: CGSize) -> some View {
    let x = size.width * split
    return ZStack(alignment: .topLeading) {
      if checkerboard {
        Image(decorative: Self.checker, scale: 1).resizable(resizingMode: .tile)
      }
      Image(decorative: after, scale: 1).resizable()
      Image(decorative: before, scale: 1).resizable()
        .mask(alignment: .leading) { Rectangle().frame(width: x) }
      Rectangle()
        .fill(.white)
        .frame(width: 2)
        .shadow(color: .black.opacity(0.35), radius: 2)
        .offset(x: x - 1)
      Image(systemName: "arrow.left.and.right")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.black.opacity(0.7))
        .frame(width: 30, height: 30)
        .background(.white, in: Circle())
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .position(x: x, y: size.height / 2)
      // 长条图画出来太窄、两个标签放不下时不画（原来字折成两行、两个叠在一起）
      if size.width >= 160 {
        HStack {
          tag("原图").opacity(split > 0.12 ? 1 : 0)
          Spacer()
          tag(afterLabel).opacity(split < 0.88 ? 1 : 0)
        }
        .padding(8)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipShape(RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0).onChanged {
        split = min(max($0.location.x / size.width, 0), 1)
      }
    )
    .pointerStyle(.columnResize)
  }

  /// 右下角的小条：缩小、适合、1:1、放大
  private func zoomBar(fit: CGFloat) -> some View {
    // 1:1：一个原图像素对一个屏幕像素
    let actual = 1 / (fit * displayScale)
    return HStack(spacing: 10) {
      Button("缩小", systemImage: "minus.magnifyingglass") { zoom = clamp(zoom / 1.5, fit: fit) }
        .disabled(zoom <= 1)
      Button("适合") { zoom = 1 }.labelStyle(.titleOnly).disabled(zoom == 1)
      Button("1:1") { zoom = clamp(actual, fit: fit) }.labelStyle(.titleOnly)
        .disabled(abs(zoom - actual) < 0.01)
      Button("放大", systemImage: "plus.magnifyingglass") { zoom = clamp(zoom * 1.5, fit: fit) }
    }
    .labelStyle(.iconOnly)
    // 系统附件栏的按钮：点得到的地方比图标大（原来无边框的小按钮只有图标那么大）
    .buttonStyle(.accessoryBar)
    .controlSize(.small)
    .floatingBar()
  }

  /// 最小整张放得下，最大放到 1:1 的 4 倍（够看清一个像素）
  private func clamp(_ value: CGFloat, fit: CGFloat) -> CGFloat {
    min(max(value, 1), max(4 / (fit * displayScale), 1))
  }

  /// 棋盘格的一块（16 × 16，浅灰白相间；铺满用 tile）
  private static let checker: CGImage = {
    let context = CGContext(
      data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    context.setFillColor(gray: 0.86, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    context.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
    return context.makeImage()!
  }()

  private func tag(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .fixedSize()
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        .black.opacity(0.5),
        in: RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
  }
}
