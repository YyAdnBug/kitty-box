// Gemini 角标页（D1）：左边一批图，工具栏「去掉角标」一张一张去；右边是选中那张的预览，去好了就是前后对比（拖中间的线）。
// 认不出的那行写「没认出 Gemini 角标」，右键或行里的链接能改用画笔擦除（交给 Navigator 切过去）。
// 结果是「原名-去水印」放在原图旁边，不碰原图。

import AppKit
import SwiftUI

struct GeminiView: View {
  @Bindable var batch: ImageBatch
  /// 认不出的图交给画笔擦除
  let handOff: (URL) -> Void
  @State private var selection: ImageBatch.Item.ID?

  var body: some View {
    VStack(spacing: 0) {
      if batch.items.isEmpty {
        DropZone(
          tool: .gemini, title: "拖入 Gemini 生成的图",
          detail: "去掉右下角的星标：按原理还原、不靠猜，画质不受损；结果另存成「原名-去水印」")
      } else {
        HStack(spacing: 0) {
          list.frame(width: 300)
          Divider()
          if let item = selected {
            BeforeAfter(source: item.source, result: item.result)
              .padding(20)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      StatusBar {
        Text(summary)
      } trailing: {
        if batch.running {
          ProgressView().controlSize(.mini)
          Text("正在去…")
        } else {
          Text("只认 Gemini 生成图右下角的星标")
        }
      }
    }
    .navigationTitle("Gemini 角标")
    .toolbar {
      ToolbarItemGroup {
        Button("添加文件", systemImage: "plus") { Navigator.shared.importing = true }
          .help("添加图片（⌘O）")
        Button("清掉做完的", systemImage: "checklist.checked") { batch.clearFinished() }
          .help("清掉去好的")
          .disabled(batch.outputs.isEmpty || batch.running)
      }
      ToolbarItem(placement: .primaryAction) {
        Button("去掉角标") { Task { await batch.run { try await GeminiMark.clean($0) } } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!batch.hasWork || batch.running)
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
    .onDeleteCommand { if let selection, !batch.running { batch.remove(selection) } }
  }

  /// 选中的那张；没选（或选的被清掉了）就是第一张
  private var selected: ImageBatch.Item? {
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
      // ponytail: 预览按长边 2400 解，够屏幕看；要看 1:1 细节再加缩放
      guard let before = await Thumbnail.load(source, maxPixel: 2400) else { return }
      let after: CGImage? =
        if let result { await Thumbnail.load(result, maxPixel: 2400) } else { nil }
      images = (before, after)
    }
  }
}
