// 一批图的预览（AI 水印、去背景共用）。M9 改版（用户说「预览区域太小，能不能选中之后列表变成详情、名字到预览顶上去」）：
// - 平时一格一格的缩略图（同「照片」的网格）：图、名字、做到哪了（右上角对勾 / 叹号 / 转圈），点一格看大图；
// - 大图占满整块：名字、状态（做好了能点开、在访达中显示）挪到顶上一条，左边「全部 N 张」回到网格（Esc），
//   右边第几张、上一张 / 下一张（← →）；做好了是前后对比（拖中间的线，能放大），空格快速查看；
// - 只有一张时直接是大图。
// 右键（网格里）：打开结果、在访达中显示、改用画笔擦除、移除；能把格子拖出去（做好了拖的是结果）。

import AppKit
import SwiftUI

/// handOff：没做成的「改用画笔擦除」；checkerboard：结果有透明的地方，垫一层棋盘格
struct BatchPreview: View {
  @Bindable var batch: FileBatch
  let doneVerb: String
  var handOff: ((URL) -> Void)?
  var checkerboard = false
  var afterLabel = "去水印后"
  /// 正在看大图的那张；nil 是网格
  @State private var opened: FileBatch.Item.ID?

  var body: some View {
    if let item = shown {
      detail(item)
    } else {
      grid
    }
  }

  /// 看哪张：点开的那张（被移除了就回网格）；只有一张时就是它
  private var shown: FileBatch.Item? {
    batch.items.count == 1 ? batch.items.first : batch.items.first { $0.id == opened }
  }

  // MARK: 网格

  private var grid: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)],
        spacing: 20
      ) {
        ForEach(batch.items) { item in
          Button {
            opened = item.id
          } label: {
            BatchCard(item: item, handOff: handOff)
          }
          .buttonStyle(.plain)
          .help("看大图")
          .onDrag { NSItemProvider(contentsOf: item.result ?? item.source) ?? NSItemProvider() }
          .contextMenu { menu(item) }
        }
      }
      .padding(20)
    }
  }

  @ViewBuilder private func menu(_ item: FileBatch.Item) -> some View {
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

  // MARK: 大图

  private func detail(_ item: FileBatch.Item) -> some View {
    let index = batch.items.firstIndex { $0.id == item.id } ?? 0
    let count = batch.items.count
    return VStack(spacing: 0) {
      HStack(spacing: 12) {
        if count > 1 {
          Button {
            opened = nil
          } label: {
            Label("全部 \(count) 张", systemImage: "chevron.left")
          }
          .keyboardShortcut(.cancelAction)
          .help("回到全部（Esc）")
          Hairline(vertical: true).frame(height: 24)
        }
        BatchRow(
          item: item, doneVerb: doneVerb, removable: !batch.running,
          remove: { batch.remove(item.id) },
          onFailure: handOff.map { ("改用画笔擦除", $0) })
        if count > 1 {
          Text("\(index + 1) / \(count)").monospacedDigit().foregroundStyle(.secondary)
          Button("上一张", systemImage: "chevron.left") { opened = batch.items[index - 1].id }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("上一张（←）")
            .disabled(index == 0)
          Button("下一张", systemImage: "chevron.right") { opened = batch.items[index + 1].id }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("下一张（→）")
            .disabled(index == count - 1)
        }
      }
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 20)
      .padding(.vertical, 6)
      Hairline()
      BeforeAfter(
        source: item.source, result: item.result, checkerboard: checkerboard, afterLabel: afterLabel
      )
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .focusable()
    .focusEffectDisabled()
    .spacePreview { [item.result ?? item.source] }
  }
}

/// 网格里的一格：图（等比放进方块）、右上角的状态、名字、一行状态（没做成的写原因，能改用画笔擦除）
private struct BatchCard: View {
  let item: FileBatch.Item
  let handOff: ((URL) -> Void)?
  @State private var image: CGImage?
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .fill(hovering ? Style.hoverFill : Color.secondary.opacity(0.08))
        .aspectRatio(1, contentMode: .fit)
        .overlay {
          if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
              .clipShape(RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
              .padding(10)
          }
        }
        .overlay(alignment: .topTrailing) { badge.padding(8) }
      Text(item.source.lastPathComponent)
        .lineLimit(1).truncationMode(.middle)
        .font(.callout)
      line.font(.caption).lineLimit(2)
    }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .task(id: item.source) { image = await Thumbnail.load(item.source, maxPixel: 440) }
  }

  @ViewBuilder private var badge: some View {
    switch item.state {
    case .waiting: EmptyView()
    case .running: ProgressView().controlSize(.small)
    case .done:
      Image(systemName: "checkmark.circle.fill").font(.title3)
        .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill").font(.title3)
        .symbolRenderingMode(.palette).foregroundStyle(.white, .red)
    }
  }

  @ViewBuilder private var line: some View {
    switch item.state {
    case .waiting: Text("等着").foregroundStyle(.secondary)
    case .running:
      if let progress = item.progress {
        ProgressView(value: progress)
      } else {
        Text("正在处理…").foregroundStyle(.secondary)
      }
    case .done(let url): Text("存成「\(url.lastPathComponent)」").foregroundStyle(.secondary)
    case .failed(let reason):
      VStack(alignment: .leading, spacing: 2) {
        Text(reason).foregroundStyle(.red)
        if let handOff {
          Button("改用画笔擦除") { handOff(item.source) }.buttonStyle(.link)
        }
      }
    }
  }
}

/// 一张图的预览：有结果时是前后对比，没有时只是原图（AI 水印、去背景、图片转换共用）
struct BeforeAfter: View {
  let source: URL
  let result: URL?
  var checkerboard = false
  var afterLabel = "去水印后"
  @State private var images: (before: CGImage, after: CGImage?)?

  var body: some View {
    Group {
      if let images, let after = images.after {
        CompareSlider(
          before: images.before, after: after, checkerboard: checkerboard, afterLabel: afterLabel)
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
