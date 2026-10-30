// 工具页共用的三件：空着时铺满的拖放区（DropZone）、整页收拖放时描一圈家族色（fileDrop）、底下的状态栏（StatusBar，同访达窗口底边）。
// 拖放区写明三种进来的路：添加文件（⌘O）、拖进来、⌘V 粘贴（Paste）。

import SwiftUI

/// 空着时铺满页面的拖放区：家族色的圆底符号 + 标题 + 一句说明 +「添加文件…」和 ⌘V 提示
struct DropZone: View {
  let tool: Tool
  let title: String
  let detail: String

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: tool.symbol)
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(tool.color)
        .frame(width: 76, height: 76)
        .background(tool.color.opacity(0.12), in: Circle())
      VStack(spacing: 6) {
        Text(title).font(.system(size: 15, weight: .semibold))
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      HStack(spacing: 10) {
        Button("添加文件…") { Navigator.shared.importing = true }.controlSize(.large)
        Text("或拖进来、按 ⌘V 粘贴").font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: Style.Radius.panel, style: .continuous)
        .strokeBorder(Style.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
    }
    .padding(16)
  }
}

/// 工具页底下的状态栏：左边一句状态（数了几个、做到哪了、结果），右边进度或一两个小按钮；28 pt 高、11 pt 字、顶上一条分隔线
struct StatusBar<Leading: View, Trailing: View>: View {
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 10) {
      leading.lineLimit(1)
      Spacer(minLength: 8)
      trailing
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .controlSize(.small)
    .padding(.horizontal, 12)
    .frame(height: 28)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }
}

extension StatusBar where Trailing == EmptyView {
  init(@ViewBuilder leading: () -> Leading) {
    self.init(leading: leading, trailing: { EmptyView() })
  }
}

extension View {
  /// 整页收拖放：拖着经过时整页描一圈家族色、垫一层淡底
  func fileDrop(_ color: Color, perform: @escaping ([URL]) -> Void) -> some View {
    modifier(FileDrop(color: color, perform: perform))
  }
}

private struct FileDrop: ViewModifier {
  let color: Color
  let perform: ([URL]) -> Void
  @State private var targeted = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .overlay {
        RoundedRectangle(cornerRadius: Style.Radius.panel, style: .continuous)
          .fill(color.opacity(0.08))
          .strokeBorder(color, lineWidth: 2)
          .padding(6)
          .opacity(targeted ? 1 : 0)
          .allowsHitTesting(false)
      }
      .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: targeted)
      .dropDestination(for: URL.self) { urls, _ in
        perform(urls)
        return true
      } isTargeted: {
        targeted = $0
      }
  }
}
