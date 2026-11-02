// 一批图的预览（AI 水印、去背景共用）。M9 改版（用户说「预览区域太小，能不能选中之后列表变成详情、名字到预览顶上去」）：
// - 平时一格一格的缩略图（同「照片」的网格）：图、名字、做到哪了（右上角对勾 / 叹号 / 转圈），点一格看大图；
// - 大图占满整块：名字、状态（做好了能点开、在访达中显示）挪到顶上一条，左边「全部 N 张」回到网格（Esc），
//   右边第几张、上一张 / 下一张（← →）；做好了是前后对比（拖中间的线，能放大），空格快速查看；
// - 只有一张时直接是大图。
// 右键（网格里）：打开结果、在访达中显示、改用画笔擦除、移除；能把格子拖出去（做好了拖的是结果）。
// 网格有焦点时（点空白处、Tab，或从大图回来）← → 挪一格、空格快速查看、⌫ 移除。换一张时预览不留上一张的图。

import AppKit
import SwiftUI

/// handOff：没做成的「改用画笔擦除」；checkerboard：结果有透明的地方，垫一层棋盘格
struct BatchPreview: View {
  @Bindable var batch: FileBatch
  let doneVerb: String
  var handOff: ((URL) -> Void)?
  var checkerboard = false
  var afterLabel = "去水印后"
  /// 页面上的输入框正在打字（AI 水印的「也去掉这些字」）：← → Esc 留给输入框，不换大图
  var typing = false
  /// 正在看大图的那张；nil 是网格
  @State private var opened: FileBatch.Item.ID?
  /// 网格里键盘停在哪一格（← → 挪，空格快速查看，⌫ 移除）；从大图回来停在刚看的那张
  @State private var cursor: FileBatch.Item.ID?
  @FocusState private var gridFocused: Bool

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
    ScrollViewReader { proxy in
      gridBody(proxy)
    }
  }

  private func gridBody(_ proxy: ScrollViewProxy) -> some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)],
        spacing: 20
      ) {
        ForEach(batch.items) { item in
          Button {
            opened = item.id
          } label: {
            BatchCard(item: item, handOff: handOff, marked: gridFocused && cursor == item.id)
          }
          .buttonStyle(.plain)
          .help("看大图")
          .onDrag { NSItemProvider(contentsOf: item.result ?? item.source) ?? NSItemProvider() }
          .contextMenu { menu(item) }
          .id(item.id)
        }
      }
      .padding(20)
    }
    // 键盘（同表格页）：网格有焦点时 ← → 挪一格、空格快速查看、⌫ 移除。
    // ponytail: 没有 ↑↓（列数随宽度变，要量宽度才知道跳几格），没有多选；真有人要再加
    .focusable()
    .focused($gridFocused)
    .focusEffectDisabled()
    .onKeyPress(.leftArrow) { moveCursor(-1) }
    .onKeyPress(.rightArrow) { moveCursor(1) }
    .onDeleteCommand {
      if let cursor, !batch.running { batch.remove(cursor) }
    }
    .spacePreview { batch.items.filter { $0.id == cursor }.map { $0.result ?? $0.source } }
    // 光标挪到看不见的格子、从大图回来：滚到它那里
    .onChange(of: cursor) { if let cursor { proxy.scrollTo(cursor) } }
    .onAppear {
      guard let cursor else { return }
      gridFocused = true
      proxy.scrollTo(cursor, anchor: .center)
    }
  }

  private func moveCursor(_ step: Int) -> KeyPress.Result {
    let ids = batch.items.map(\.id)
    let from = cursor.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
    guard ids.indices.contains(from + step) else { return .ignored }
    cursor = ids[from + step]
    return .handled
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
            cursor = opened
            opened = nil
          } label: {
            Label("全部 \(count) 张", systemImage: "chevron.left")
          }
          .keyboardShortcut(typing ? nil : .cancelAction)
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
            .keyboardShortcut(typing ? nil : KeyboardShortcut(.leftArrow, modifiers: []))
            .help("上一张（←）")
            .disabled(index == 0)
          Button("下一张", systemImage: "chevron.right") { opened = batch.items[index + 1].id }
            .keyboardShortcut(typing ? nil : KeyboardShortcut(.rightArrow, modifiers: []))
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
  /// 键盘停在这一格：图外描一圈强调色
  var marked = false
  @State private var image: CGImage?
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .fill(hovering ? Style.selectedFill : Style.hoverFill)
        .aspectRatio(1, contentMode: .fit)
        .overlay {
          if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
              .clipShape(RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
              .padding(10)
          }
        }
        .overlay(alignment: .topTrailing) { badge.padding(8) }
        .overlay {
          if marked {
            RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
              .strokeBorder(Style.brand, lineWidth: 2)
          }
        }
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
    case .waiting: Text("等待中").foregroundStyle(.secondary)
    case .running:
      if let progress = item.progress {
        ProgressView(value: progress)
      } else {
        Text("正在处理…").foregroundStyle(.secondary)
      }
    case .done(let url): Text("存成「\(url.lastPathComponent)」").foregroundStyle(.secondary)
    case .failed(let reason):
      VStack(alignment: .leading, spacing: 2) {
        // 右上角已经有红叹号：字用次要色（红字在白底上看不清）
        Text(reason).foregroundStyle(.secondary)
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
  /// 解好的图记着是哪两个文件的：换了一张（同一个位置的预览只是换了 source）先不显示上一张的；
  /// 结果没了（改了设置回到等待中）就不再对比旧结果
  @State private var images: (source: URL, result: URL?, before: CGImage, after: CGImage?)?
  @State private var unreadable = false

  var body: some View {
    Group {
      if let images, images.source == source, images.result == result, let after = images.after {
        CompareSlider(
          before: images.before, after: after, checkerboard: checkerboard, afterLabel: afterLabel)
      } else if let images, images.source == source {
        Image(decorative: images.before, scale: 1)
          .resizable()
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if unreadable {
        Label("读不出这张图", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: [source, result]) {
      unreadable = false
      // 换了一张：上一张的两张原尺寸位图先放掉，不和这一张的同时占着内存
      if images?.source != source { images = nil }
      // 连按 ← → 翻过去的不解（ImageIO 解到一半打断不了，一张大图几百 MB）
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      // 按原图分辨率解（对比能放大到 1:1 看去干净了没有）；长边封顶 16384，再大的图少见
      let before = await Thumbnail.load(source, maxPixel: 16_384)
      let after: CGImage? =
        if let result, before != nil { await Thumbnail.load(result, maxPixel: 16_384) } else { nil }
      // 解的时候又换了一张：别拿这一张盖掉
      guard !Task.isCancelled else { return }
      guard let before else {
        unreadable = true
        return
      }
      images = (source, result, before, after)
    }
  }
}
