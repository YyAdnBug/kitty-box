// 首页（A2）：四个工具一格一个，点一格进去用，左上角返回。照 Kitty Tools 主界面的格子：家族色块 + 名字 + 一行说明。
// 各工具的页面从 M1 起一批一个加进来；还没做的进去是一句「还没做好」。

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
  @State private var path: [Tool] = []

  var body: some View {
    NavigationStack(path: $path) {
      HStack(spacing: 12) {
        ForEach(Tool.allCases) { tool in
          Button {
            path.append(tool)
          } label: {
            ToolTile(tool: tool)
          }
          .buttonStyle(TileButtonStyle())
        }
      }
      .padding(20)
      .navigationTitle("Kitty Box")
      .navigationDestination(for: Tool.self) { tool in
        ContentUnavailableView(
          tool.title, systemImage: tool.symbol, description: Text("还没做好，下一批就加上。")
        )
        .navigationTitle(tool.title)
      }
    }
    .frame(minWidth: 600, minHeight: 220)
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
