// 首页（A2）：四个工具两行两列，一格一张卡（家族色块 + 名字 + 一行说明），点一格进去用，左上角返回。
// 文件拖到哪一格就交给哪个工具，拖到格子外面、或 ⌘V 粘贴，按类型分派（Navigator）；有图片时顶上一条提示，点一格交给它。

import SwiftUI

enum Tool: CaseIterable, Identifiable, Hashable {
  case pack, unpack, convert, watermark

  var id: Self { self }

  var title: String {
    switch self {
    case .pack: "打包"
    case .unpack: "解压"
    case .convert: "图片转换"
    case .watermark: "去水印"
    }
  }

  var detail: String {
    switch self {
    case .pack: "zip / 7z，可设密码"
    case .unpack: "zip、7z、RAR 都行"
    case .convert: "HEIC、WebP、RAW 等互转"
    case .watermark: "Gemini 角标、擦除、视频"
    }
  }

  var symbol: String {
    switch self {
    case .pack: "archivebox.fill"
    case .unpack: "shippingbox.and.arrow.backward.fill"
    case .convert: "photo.on.rectangle.angled"
    case .watermark: "eraser.fill"
    }
  }

  var color: Color {
    switch self {
    case .pack: Style.Family.pack
    case .unpack: Style.Family.unpack
    case .convert: Style.Family.convert
    case .watermark: Style.Family.watermark
    }
  }
}

struct HomeView: View {
  @Bindable private var navigator = Navigator.shared
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationStack(path: $navigator.path) {
      VStack(spacing: 20) {
        if let release = Updater.shared.available { updateBanner(release) }
        if !navigator.pending.isEmpty { pendingBanner }
        VStack(spacing: 4) {
          Text("要处理什么文件？").font(.system(size: 20, weight: .semibold))
          Text("拖进窗口、拖到程序坞图标上或按 ⌘V 粘贴，会自动交给合适的工具；也可以直接点一格")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
          GridRow {
            tile(.pack)
            tile(.unpack)
          }
          GridRow {
            tile(.convert)
            tile(.watermark)
          }
        }
      }
      .frame(maxWidth: 640)
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .fileDrop(.accentColor) { navigator.route($0) }
      .navigationTitle("Kitty Box")
      .navigationDestination(for: Tool.self) { tool in
        switch tool {
        case .pack: PackView(model: navigator.pack)
        case .unpack: UnpackView(model: navigator.unpack)
        case .convert: ConvertView(model: navigator.convert)
        case .watermark: WatermarkView(model: navigator.watermark)
        }
      }
    }
    // 进到工具页时窗口最小高度跟着变大（工具页自己的 minHeight 传不到窗口上）
    .frame(minWidth: 600, minHeight: navigator.path.isEmpty ? homeHeight : 560)
    .onAppear { navigator.openWindow = openWindow }
  }

  /// 首页的最小高度：标题 + 两行格子，每多一条横幅加一条的高
  private var homeHeight: CGFloat {
    330 + (navigator.pending.isEmpty ? 0 : 52) + (Updater.shared.available == nil ? 0 : 52)
  }

  private func tile(_ tool: Tool) -> some View {
    let pending = navigator.pending
    let refused = !pending.isEmpty && !navigator.accepts(tool, pending)
    return ToolButton(tool: tool) {
      if pending.isEmpty {
        navigator.path.append(tool)
      } else {
        navigator.open(tool, with: pending)
      }
    } drop: { urls in
      navigator.open(tool, with: urls)
    }
    .disabled(refused)
    .opacity(refused ? 0.4 : 1)
  }

  /// 有新版本时顶上的一条，点了打开关于窗口
  private func updateBanner(_ release: Updater.Release) -> some View {
    banner(symbol: "arrow.down.circle.fill", tint: .accentColor) {
      Text("有新版本 \(release.version)")
      Spacer()
      Button("看看") { openWindow(id: KittyBoxApp.aboutID) }
    }
  }

  /// 收到文件、还没选工具时顶上的一条
  private var pendingBanner: some View {
    banner(symbol: "tray.and.arrow.down.fill", tint: .accentColor) {
      Text(
        navigator.pending.count == 1
          ? "收到「\(navigator.pending[0].lastPathComponent)」，点一格交给它"
          : "收到 \(navigator.pending.count) 个文件，点一格交给它"
      )
      .lineLimit(1).truncationMode(.middle)
      Spacer()
      Button("不用了") { navigator.pending = [] }
    }
  }

  private func banner(symbol: String, tint: Color, @ViewBuilder content: () -> some View)
    -> some View
  {
    HStack(spacing: 10) {
      Image(systemName: symbol).foregroundStyle(tint)
      content()
    }
    .controlSize(.small)
    .padding(.horizontal, 14).padding(.vertical, 10)
    .cardSurface()
  }
}

/// 一格：点进去；文件能直接拖上来，拖着经过时描一圈家族色
private struct ToolButton: View {
  let tool: Tool
  let action: () -> Void
  let drop: ([URL]) -> Void
  @State private var targeted = false

  var body: some View {
    Button(action: action) { ToolTile(tool: tool) }
      .buttonStyle(TileButtonStyle())
      .overlay {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .fill(tool.color.opacity(0.08))
          .strokeBorder(tool.color, lineWidth: 2)
          .opacity(targeted ? 1 : 0)
          .allowsHitTesting(false)
      }
      .dropDestination(for: URL.self) { urls, _ in
        drop(urls)
        return true
      } isTargeted: {
        targeted = $0
      }
  }
}

private struct ToolTile: View {
  let tool: Tool

  var body: some View {
    HStack(spacing: 14) {
      KindTile(symbol: tool.symbol, color: tool.color, size: 44)
      VStack(alignment: .leading, spacing: 3) {
        Text(tool.title).font(.system(size: 14, weight: .semibold))
        Text(tool.detail)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 4)
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 84)
    .contentShape(Rectangle())
  }
}

/// 格子按钮：卡片表面，悬停时垫一层悬停色，按下时缩一点（glide 曲线；减弱动态效果时不缩）
private struct TileButtonStyle: ButtonStyle {
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    configuration.label
      .background(hovering ? Style.hoverFill : .clear, in: shape)
      .cardSurface()
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(
        Style.Motion.glide.animation(reduced: reduceMotion), value: configuration.isPressed
      )
      .onHover { hovering = $0 }
  }
}
