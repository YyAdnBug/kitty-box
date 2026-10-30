// 首页（A2）：四个工具一格一个，点一格进去用，左上角返回。照 Kitty Tools 主界面的格子：家族色块 + 名字 + 一行说明。
// 文件拖到哪一格就交给哪个工具，拖到格子外面按类型分派（Navigator）；有图片时顶上一条提示，点一格交给它。
// 还没做的工具进去是一句「还没做好」。

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

  /// 做好了、能收文件的工具
  var isReady: Bool { self != .watermark }
}

struct HomeView: View {
  @Bindable private var navigator = Navigator.shared
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationStack(path: $navigator.path) {
      VStack(spacing: 12) {
        if !navigator.pending.isEmpty { pendingBanner }
        HStack(spacing: 12) {
          ForEach(Tool.allCases) { tool in
            let pending = navigator.pending
            let refused = !pending.isEmpty && !navigator.accepts(tool, pending)
            ToolButton(tool: tool) {
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
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .dropDestination(for: URL.self) { urls, _ in
        navigator.route(urls)
        return true
      }
      .navigationTitle("Kitty Box")
      .navigationDestination(for: Tool.self) { tool in
        switch tool {
        case .pack: PackView(model: navigator.pack)
        case .unpack: UnpackView(model: navigator.unpack)
        case .convert: ConvertView(model: navigator.convert)
        case .watermark:
          ContentUnavailableView(
            tool.title, systemImage: tool.symbol, description: Text("还没做好，后面几批加上。")
          )
          .navigationTitle(tool.title)
        }
      }
    }
    // 进到工具页时窗口最小高度跟着变大（工具页自己的 minHeight 传不到窗口上）
    .frame(
      minWidth: 600,
      minHeight: navigator.path.isEmpty ? (navigator.pending.isEmpty ? 220 : 270) : 560
    )
    .onAppear { navigator.openWindow = openWindow }
  }

  /// 收到文件、还没选工具时顶上的一条
  private var pendingBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.secondary)
      Text(
        navigator.pending.count == 1
          ? "收到「\(navigator.pending[0].lastPathComponent)」，点一格交给它"
          : "收到 \(navigator.pending.count) 个文件，点一格交给它"
      )
      .lineLimit(1).truncationMode(.middle)
      Spacer()
      Button("不用了") { navigator.pending = [] }.buttonStyle(.link)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .cardSurface()
  }
}

/// 一格：点进去；做好了的工具能直接把文件拖上来，拖着经过时描一圈家族色
private struct ToolButton: View {
  let tool: Tool
  let action: () -> Void
  let drop: ([URL]) -> Void
  @State private var targeted = false

  var body: some View {
    let button = Button(action: action) { ToolTile(tool: tool) }
      .buttonStyle(TileButtonStyle())
      .overlay {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .strokeBorder(tool.color, lineWidth: 2)
          .opacity(targeted ? 1 : 0)
          .allowsHitTesting(false)
      }
    if tool.isReady {
      button.dropDestination(for: URL.self) { urls, _ in
        drop(urls)
        return true
      } isTargeted: {
        targeted = $0
      }
    } else {
      button
    }
  }
}

private struct ToolTile: View {
  let tool: Tool

  var body: some View {
    VStack(spacing: 8) {
      KindTile(symbol: tool.symbol, color: tool.color, size: 40)
      Text(tool.title).font(.system(size: 14, weight: .semibold))
      Text(tool.detail)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, minHeight: 120)
    .padding(.horizontal, 8)
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
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(
        Style.Motion.glide.animation(reduced: reduceMotion), value: configuration.isPressed
      )
      .onHover { hovering = $0 }
  }
}
