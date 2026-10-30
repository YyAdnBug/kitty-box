// 收文件的两件共用的东西：工具页空着时铺满的拖放区（DropZone），和整页收拖放、拖着经过时描一圈家族色（fileDrop）。
// 拖放区写明三种进来的路：拖进来、⌘V 粘贴（Paste）、选择文件。

import SwiftUI

/// 空着时铺满页面的拖放区：家族色的圆底符号 + 标题 + 一句说明 +「选择文件…」和 ⌘V 提示
struct DropZone: View {
  let symbol: String
  let color: Color
  let title: String
  let detail: String
  let choose: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: symbol)
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(color)
        .frame(width: 76, height: 76)
        .background(color.opacity(0.12), in: Circle())
      VStack(spacing: 6) {
        Text(title).font(.system(size: 15, weight: .semibold))
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      HStack(spacing: 10) {
        Button("选择文件…", action: choose).controlSize(.large)
        Text("或按 ⌘V 粘贴").font(.system(size: 12)).foregroundStyle(.secondary)
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

extension View {
  /// 整页收拖放：拖着经过时整页描一圈家族色、垫一层淡底
  func fileDrop(_ color: Color, perform: @escaping ([URL]) -> Void) -> some View {
    modifier(FileDrop(color: color, perform: perform))
  }

  /// 页面底部的操作栏：工具栏材质、顶上一条分隔线
  func bottomBar() -> some View {
    padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
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
