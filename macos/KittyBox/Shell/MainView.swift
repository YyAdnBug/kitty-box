// 主窗口（A1、A2，2026-10-30 改成侧边栏）：左边侧边栏按「压缩」「图片」「去水印」分组列出六个工具（家族色块 + 名字，还有没处理完的
// 数一个角标），右边是选中的工具页。照系统设置、常见文件工具的样子：工具多了用侧边栏，不用首页格子 + 返回。
// 文件拖到侧边栏的某一项就交给那个工具；收到不知道给谁的文件时弹出来问（Navigator.pending）。
// 「添加文件…」统一在这里弹选文件（Navigator.importing），选好交给当前工具。

import SwiftUI
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable, Hashable {
  case pack, unpack, convert, gemini, erase, video

  var id: Self { self }

  var title: String {
    switch self {
    case .pack: "打包"
    case .unpack: "解压"
    case .convert: "图片转换"
    case .gemini: "Gemini 角标"
    case .erase: "画笔擦除"
    case .video: "视频台标"
    }
  }

  var symbol: String {
    switch self {
    case .pack: "archivebox.fill"
    case .unpack: "shippingbox.and.arrow.backward.fill"
    case .convert: "photo.on.rectangle.angled"
    case .gemini: "sparkle"
    case .erase: "paintbrush.pointed.fill"
    case .video: "film.fill"
    }
  }

  var color: Color {
    switch self {
    case .pack: Style.Family.pack
    case .unpack: Style.Family.unpack
    case .convert: Style.Family.convert
    case .gemini, .erase, .video: Style.Family.watermark
    }
  }

  /// 选文件时能选什么、能不能一次选好几个
  var contentTypes: [UTType] {
    switch self {
    case .pack: [.item, .folder]
    case .unpack: [.item]
    case .convert, .gemini, .erase: [.image]
    case .video: [.movie]
    }
  }

  var takesMany: Bool { self != .erase && self != .video }

  /// 侧边栏的分组
  enum Shelf: String, CaseIterable, Identifiable {
    case archive = "压缩"
    case image = "图片"
    case watermark = "去水印"

    var id: Self { self }

    var tools: [Tool] {
      switch self {
      case .archive: [.pack, .unpack]
      case .image: [.convert]
      case .watermark: [.gemini, .erase, .video]
      }
    }
  }
}

struct MainView: View {
  /// 平时就是 Navigator.shared；截图自检传自己的进来
  @Bindable var navigator = Navigator.shared
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        ForEach(Tool.Shelf.allCases) { shelf in
          Section(shelf.rawValue) {
            ForEach(shelf.tools) { tool in
              SidebarRow(tool: tool) { navigator.open(tool, with: $0) }
                .badge(badge(tool))
                .tag(tool)
            }
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
      .safeAreaInset(edge: .bottom) {
        if let release = Updater.shared.available { updateCard(release) }
      }
    } detail: {
      page
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileDrop(navigator.tool.color) { navigator.give($0) }
    }
    .fileImporter(
      isPresented: $navigator.importing, allowedContentTypes: navigator.tool.contentTypes,
      allowsMultipleSelection: navigator.tool.takesMany
    ) {
      if case .success(let urls) = $0 { navigator.open(navigator.tool, with: urls) }
    }
    .confirmationDialog(pendingTitle, isPresented: asking, titleVisibility: .visible) {
      ForEach(Tool.allCases.filter { navigator.accepts($0, navigator.pending) }) { tool in
        Button(tool.title) { navigator.open(tool, with: navigator.pending) }
      }
      Button("取消", role: .cancel) { navigator.pending = [] }
    }
    .frame(minWidth: 860, minHeight: 540)
    .onAppear { navigator.openWindow = openWindow }
  }

  @ViewBuilder private var page: some View {
    switch navigator.tool {
    case .pack: PackView(model: navigator.pack)
    case .unpack: UnpackView(model: navigator.unpack)
    case .convert: ConvertView(model: navigator.convert)
    case .gemini: GeminiView(batch: navigator.gemini) { navigator.open(.erase, with: [$0]) }
    case .erase: EraseCanvas(model: navigator.erase)
    case .video: VideoMarkView(model: navigator.video)
    }
  }

  private var selection: Binding<Tool?> {
    Binding(get: { navigator.tool }, set: { if let tool = $0 { navigator.tool = tool } })
  }

  private var asking: Binding<Bool> {
    Binding(get: { !navigator.pending.isEmpty }, set: { if !$0 { navigator.pending = [] } })
  }

  private var pendingTitle: String {
    navigator.pending.count == 1
      ? "把「\(navigator.pending[0].lastPathComponent)」交给哪个工具？"
      : "把这 \(navigator.pending.count) 个文件交给哪个工具？"
  }

  /// 侧边栏的角标：还没处理的有几个（0 不显示）
  private func badge(_ tool: Tool) -> Int {
    switch tool {
    case .pack: navigator.pack.items.count
    case .unpack: navigator.unpack.jobs.count { !$0.isFinished }
    case .convert: navigator.convert.items.count { $0.result == nil }
    case .gemini: navigator.gemini.items.count { $0.result == nil }
    case .erase, .video: 0
    }
  }

  /// 有新版本时侧边栏底下的一张小卡，点了打开关于窗口
  private func updateCard(_ release: Updater.Release) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
      Text("有新版本 \(release.version)").lineLimit(1)
      Spacer(minLength: 4)
      Button("看看") { openWindow(id: KittyBoxApp.aboutID) }
    }
    .font(.system(size: 12))
    .controlSize(.small)
    .padding(10)
    .cardSurface()
    .padding(10)
  }
}

/// 侧边栏的一项：家族色块 + 名字；文件拖上来交给它，拖着经过时垫一层家族色
private struct SidebarRow: View {
  let tool: Tool
  let drop: ([URL]) -> Void
  @State private var targeted = false

  var body: some View {
    Label {
      Text(tool.title)
    } icon: {
      KindTile(symbol: tool.symbol, color: tool.color, size: 20)
    }
    .listRowBackground(
      RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
        .fill(tool.color.opacity(targeted ? 0.25 : 0))
        .padding(.horizontal, 10)
    )
    .dropDestination(for: URL.self) { urls, _ in
      drop(urls)
      return true
    } isTargeted: {
      targeted = $0
    }
  }
}
