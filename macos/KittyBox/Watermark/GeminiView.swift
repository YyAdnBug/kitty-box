// Gemini 角标页（D1）：左边一批图，页头「去掉角标」一张一张去；右边是选中那张的预览，去好了就是前后对比（拖中间的线）。
// 认不出的那行写「没认出 Gemini 角标」，右键或行里的链接能改用画笔擦除（交给 Navigator 切过去）。
// 结果是「原名-去水印」放在原图旁边，不碰原图。

import AppKit
import SwiftUI

struct GeminiView: View {
  @Bindable var batch: FileBatch
  /// 认不出的图交给画笔擦除
  let handOff: (URL) -> Void
  @State private var selection: FileBatch.Item.ID?

  var body: some View {
    ToolPage(tool: .gemini) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加图片（⌘O）")
      Button("清掉做完的", systemImage: "checklist.checked") { batch.clearFinished() }
        .help("清掉去好的")
        .disabled(batch.outputs.isEmpty || batch.running)
      Button("去掉角标") { Task { await batch.run { try await GeminiMark.clean($0) } } }
        .buttonStyle(BrandButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(!batch.hasWork || batch.running)
    } content: {
      if batch.items.isEmpty {
        DropZone(
          tool: .gemini, title: "拖入 Gemini 生成的图",
          detail: "按原理还原、不靠猜；可以一次放一批，结果另存成「原名-去水印」")
      } else {
        HStack(spacing: 0) {
          list.frame(width: 300)
          Hairline(vertical: true)
          if let item = selected {
            BeforeAfter(source: item.source, result: item.result)
              .padding(20)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
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

  private var list: some View {
    List(selection: $selection) {
      ForEach(batch.items) { item in
        BatchRow(
          item: item, doneVerb: "存成", removable: !batch.running,
          remove: { batch.remove(item.id) },
          onFailure: ("改用画笔擦除", handOff)
        )
        .onDrag { NSItemProvider(contentsOf: item.result ?? item.source) ?? NSItemProvider() }
        .contextMenu {
          if let url = item.result {
            Button("打开去好的") { NSWorkspace.shared.open(url) }
          }
          Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.result ?? item.source])
          }
          Button("改用画笔擦除") { handOff(item.source) }
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

  private var summary: String {
    if batch.items.isEmpty { return "还没有图片" }
    let failed = batch.items.count { if case .failed = $0.state { true } else { false } }
    return "\(batch.items.count) 张 · 已去掉 \(batch.outputs.count)"
      + (failed > 0 ? " · \(failed) 张没认出" : "")
      + (batch.skipped > 0 ? " · \(batch.skipped) 个不是图片，没加进来" : "")
  }
}

/// 一张图的预览：有结果时是前后对比，没有时只是原图
private struct BeforeAfter: View {
  let source: URL
  let result: URL?
  @State private var images: (before: CGImage, after: CGImage?)?

  var body: some View {
    Group {
      if let images, let after = images.after {
        CompareSlider(before: images.before, after: after)
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
      // 按原图分辨率解（对比能放大到 1:1 看星标去干净了没有）；长边封顶 16384，再大的图少见
      guard let before = await Thumbnail.load(source, maxPixel: 16_384) else { return }
      let after: CGImage? =
        if let result { await Thumbnail.load(result, maxPixel: 16_384) } else { nil }
      images = (before, after)
    }
  }
}
