// 工具页的骨架（六个工具页共用，照 Kitty Tools 设置窗的页）：
// - 页头（PageHeader）：40 pt 家族色块 + 标题（title2）+ 一句说明（callout），右边这一页的操作按钮，最右是品牌粉主按钮。
//   操作放页头、不放窗口工具栏：工具栏按钮多了窗口一窄就收进「»」，各栏的工具栏底色也不一样（2026-10-30 用户报）。
// - 中间内容；有选项的页（打包、图片转换）右边固定一栏选项（OptionGroup 卡片），不用系统的检查器：它在窗口不够宽时
//   会先把侧边栏收起来再展开自己（2026-10-30 用户报）。
// - 底下状态栏（28 pt、11 pt 字）：数了几个、做到哪了、结果。
// 整页同一个底色（窗口底），各块之间只用发丝线分开。另有空着时铺满的拖放区（DropZone）和整页收拖放的描边（fileDrop）。

import SwiftUI

struct ToolPage<Actions: View, Content: View, Options: View, Status: View>: View {
  let tool: Tool
  @ViewBuilder var actions: Actions
  @ViewBuilder var content: Content
  @ViewBuilder var options: Options
  @ViewBuilder var status: Status

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(tool: tool) { actions }
      Hairline()
      HStack(spacing: 0) {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        if Options.self != EmptyView.self {
          Hairline(vertical: true)
          ScrollView {
            VStack(alignment: .leading, spacing: 18) { options }.padding(16)
          }
          .frame(width: 300)
        }
      }
      Hairline()
      HStack(spacing: 10) { status }
        .lineLimit(1)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(tool.title)
  }
}

extension ToolPage where Options == EmptyView {
  init(
    tool: Tool, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content,
    @ViewBuilder status: () -> Status
  ) {
    self.init(
      tool: tool, actions: actions, content: content, options: { EmptyView() }, status: status)
  }
}

/// 页头：40 pt 家族色块 + 标题 + 一句说明，右边一排操作
private struct PageHeader<Actions: View>: View {
  let tool: Tool
  @ViewBuilder var actions: Actions

  var body: some View {
    HStack(spacing: 12) {
      KindTile(symbol: tool.symbol, color: tool.color, size: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(tool.title).font(.title2.weight(.semibold))
        Text(tool.summary).font(.callout).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.tail)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 12)
      HStack(spacing: 8) { actions }.fixedSize()
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .padding(.bottom, 14)
  }
}

/// 右边选项栏里的一组：11 pt 组名、一张卡片（卡片表面，里面的行间距 10），下面可以跟一段说明小字
struct OptionGroup<Content: View>: View {
  let title: String
  var footnote: Text?
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
      VStack(alignment: .leading, spacing: 10) { content }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
      if let footnote {
        footnote
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 10)
      }
    }
  }
}

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
        Button("添加文件…") { Navigator.shared.importing = true }
          .buttonStyle(BrandButtonStyle())
        Text("或拖进来、按 ⌘V 粘贴").font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: Style.Radius.panel, style: .continuous)
        .strokeBorder(Style.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
    }
    .padding(20)
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
