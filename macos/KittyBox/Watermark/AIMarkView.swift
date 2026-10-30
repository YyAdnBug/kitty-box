// AI 水印页（M7，原来的「Gemini 角标」页）：左边一批图，页头「去掉水印」一张一张去（AIMark：Gemini 星标按原理还原，
// 「AI生成」这类文字水印找到位置交给补图模型补）；右边是选中那张的预览，去好了就是前后对比（拖中间的线，能放大）。
// 认不出的那行写「没认出 AI 水印」，右键或行里的链接能改用画笔擦除（交给 Navigator 切过去）。补图模型没下好时顶上一条。
// 结果是「原名-去水印」放在原图旁边，不碰原图。
// 列表 + 预览这一块（BatchPreview）去背景页也用。

import AppKit
import SwiftUI

struct AIMarkView: View {
  @Bindable var batch: FileBatch
  /// 认不出的图交给画笔擦除
  let handOff: (URL) -> Void
  @AppStorage(Prefs.inpaintModel) private var choice = InpaintModel.standard
  @Bindable private var downloads = ModelDownloads.shared

  var body: some View {
    ToolPage(tool: .aiMark) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加图片（⌘O）")
      Button("清掉做完的", systemImage: "checklist.checked") { batch.clearFinished() }
        .help("清掉去好的")
        .disabled(batch.outputs.isEmpty || batch.running)
      Button("去掉水印") {
        let choice = choice
        Task { await batch.run { try await AIMark.clean($0, using: choice) } }
      }
      .buttonStyle(BrandButtonStyle())
      .keyboardShortcut(.defaultAction)
      .disabled(!batch.hasWork || batch.running)
    } content: {
      VStack(spacing: 0) {
        if downloads.state(of: choice) != .ready {
          ModelBanner(choice: choice, purpose: "Gemini 星标不用它；「AI生成」这类文字水印要用补图模型补")
            .padding(.horizontal, 20).padding(.vertical, 12)
          Hairline()
        }
        if batch.items.isEmpty {
          DropZone(
            tool: .aiMark, title: "拖入 AI 生成的图",
            detail: "Gemini 的星标按原理还原，不靠猜；豆包、即梦这类角上的「AI生成」字样自动补掉。结果另存成「原名-去水印」")
        } else {
          BatchPreview(batch: batch, doneVerb: "存成", handOff: handOff)
        }
      }
    } status: {
      Text(summary)
      Spacer(minLength: 8)
      if batch.running {
        ProgressView().controlSize(.mini)
        Text("正在去…")
      } else {
        Text("认不出的可以右键改用画笔擦除")
      }
    }
  }

  private var summary: String {
    if batch.items.isEmpty { return "还没有图片" }
    let failed = batch.items.count { if case .failed = $0.state { true } else { false } }
    return "\(batch.items.count) 张 · 已去掉 \(batch.outputs.count)"
      + (failed > 0 ? " · \(failed) 张没去成" : "")
      + (batch.skipped > 0 ? " · \(batch.skipped) 个不是图片，没加进来" : "")
  }
}

/// 左边一列图（缩略图、名字、做到哪了），右边选中那张的预览：做好了是前后对比。AI 水印和去背景共用。
/// handOff：没做成的那行「改用画笔擦除」；checkerboard：结果有透明的地方，垫一层棋盘格
struct BatchPreview: View {
  @Bindable var batch: FileBatch
  let doneVerb: String
  var handOff: ((URL) -> Void)?
  var checkerboard = false
  @State private var selection: FileBatch.Item.ID?

  var body: some View {
    HStack(spacing: 0) {
      list.frame(width: 300)
      Hairline(vertical: true)
      if let item = selected {
        BeforeAfter(source: item.source, result: item.result, checkerboard: checkerboard)
          .padding(20)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var list: some View {
    List(selection: $selection) {
      ForEach(batch.items) { item in
        BatchRow(
          item: item, doneVerb: doneVerb, removable: !batch.running,
          remove: { batch.remove(item.id) },
          onFailure: handOff.map { ("改用画笔擦除", $0) }
        )
        .onDrag { NSItemProvider(contentsOf: item.result ?? item.source) ?? NSItemProvider() }
        .contextMenu {
          if let url = item.result {
            Button("打开结果") { NSWorkspace.shared.open(url) }
          }
          Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.result ?? item.source])
          }
          if let handOff { Button("改用画笔擦除") { handOff(item.source) } }
          Divider()
          Button("移除") { batch.remove(item.id) }.disabled(batch.running)
        }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .onDeleteCommand { if let selection, !batch.running { batch.remove(selection) } }
    .spacePreview { selected.map { [$0.result ?? $0.source] } ?? [] }
  }

  /// 选中的那张；没选（或选的被清掉了）就是第一张
  private var selected: FileBatch.Item? {
    batch.items.first { $0.id == selection } ?? batch.items.first
  }
}

/// 一张图的预览：有结果时是前后对比，没有时只是原图
private struct BeforeAfter: View {
  let source: URL
  let result: URL?
  let checkerboard: Bool
  @State private var images: (before: CGImage, after: CGImage?)?

  var body: some View {
    Group {
      if let images, let after = images.after {
        CompareSlider(before: images.before, after: after, checkerboard: checkerboard)
      } else if let images {
        Image(decorative: images.before, scale: 1)
          .resizable()
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: [source, result]) {
      // 按原图分辨率解（对比能放大到 1:1 看去干净了没有）；长边封顶 16384，再大的图少见
      guard let before = await Thumbnail.load(source, maxPixel: 16_384) else { return }
      let after: CGImage? =
        if let result { await Thumbnail.load(result, maxPixel: 16_384) } else { nil }
      images = (before, after)
    }
  }
}
