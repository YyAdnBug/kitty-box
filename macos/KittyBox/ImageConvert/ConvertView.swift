// 图片转换页（C1–C3、M5）：拖进（⌘V 粘贴、⌘O 添加）图片 → 右边选项栏选转成什么（有损的再调质量）、要不要缩小、
// 去不去定位 → 页头「转成 X」，几张一起转，结果放在原图旁边。上半是选中那张的预览，转好了是前后对比（M8，能放大看画质）；
// 下半表格列尺寸、大小、转换后的大小和差多少（照常见压图工具）；右键打开 / 在访达中显示 / 移除。
// 换了格式、质量、尺寸、定位，转好的那些回到「等待中」，再点一次按新的设置转（旧结果留在原处，新的重名加「 2」）；
// 转的时候右边的选项锁住，页头换成「停止」。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConvertView: View {
  @Bindable var model: FileBatch
  @AppStorage(Prefs.convertFormat) private var format = ImageConverter.Format.jpeg
  @AppStorage(Prefs.convertQuality) private var quality = 0.85
  @AppStorage(Prefs.convertMaxSide) private var maxSide = 0
  @AppStorage(Prefs.convertStripLocation) private var stripLocation = false
  @State private var selection = Set<FileBatch.Item.ID>()

  var body: some View {
    ToolPage(tool: .convert) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加图片（⌘O）")
      Button("清掉做完的", systemImage: "checkmark.circle.badge.xmark") { model.clearFinished() }
        .help("清掉转好的")
        .disabled(model.outputs.isEmpty || model.running)
      if model.running {
        Button("停止") { model.stop() }
          .buttonStyle(BrandButtonStyle())
          .help("正在转的几张转完就停，没开始的留着")
      } else {
        Button("转成 \(format.title)") {
          let (format, quality, stripLocation) = (format, quality, stripLocation)
          let maxSide = maxSide > 0 ? maxSide : nil
          model.start {
            try await ImageConverter.convert(
              $0, to: format, quality: quality, maxSide: maxSide, stripLocation: stripLocation)
          }
        }
        .buttonStyle(BrandButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(!model.hasWork)
      }
    } content: {
      if model.items.isEmpty {
        DropZone(
          tool: .convert, title: "拖入图片",
          detail: "HEIC、WebP、RAW、PSD 等都能读；可以一次放一批，几张一起转")
      } else {
        // 上半是选中那张的预览，转好了是前后对比（能放大看画质），下半是表格；中间能拖
        VSplitView {
          if let item = selected {
            BeforeAfter(source: item.source, result: item.result, afterLabel: "转换后")
              .padding(16)
              .frame(minHeight: 200, idealHeight: 320, maxHeight: .infinity)
          }
          table.frame(minHeight: 120, maxHeight: .infinity)
        }
      }
    } options: {
      // 跑的时候锁住：这一批按点按钮时的设置转，中途改了会转出和页头对不上的结果
      optionGroups.disabled(model.running)
    } status: {
      Text(summary)
      Spacer(minLength: 8)
      if model.running {
        ProgressView().controlSize(.mini)
        Text("正在转换…")
      } else if !model.outputs.isEmpty {
        Button("全部在访达中显示") {
          NSWorkspace.shared.activateFileViewerSelecting(model.outputs)
        }
        .textLink()
      }
    }
    .onChange(of: format) { model.resetDone() }
    .onChange(of: quality) { model.resetDone() }
    .onChange(of: maxSide) { model.resetDone() }
    .onChange(of: stripLocation) { model.resetDone() }
  }

  private var table: some View {
    Table(of: FileBatch.Item.self, selection: $selection) {
      TableColumn("图片") { item in
        HStack(spacing: 8) {
          FileThumb(url: item.source, size: 28)
          Text(item.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
        }
      }
      .width(min: 120, ideal: 170)
      TableColumn("尺寸") { PixelSizeText(url: $0.source).foregroundStyle(.secondary) }
        .width(min: 70, ideal: 90)
      TableColumn("大小") { FileSizeText(url: $0.source).foregroundStyle(.secondary) }
        .width(min: 54, ideal: 64)
      TableColumn("转换后") { item in
        switch item.state {
        case .waiting: WaitingLine()
        case .running:
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("正在转换…").foregroundStyle(.secondary)
          }
        case .done(let url): SizeChangeText(source: item.source, result: url)
        case .failed(let reason): FailLine(reason: reason)
        }
      }
      .width(min: 110, ideal: 130)
    } rows: {
      // 能直接拖到访达或别的 App：转好的拖结果，还没转的拖原图
      ForEach(model.items) { item in
        TableRow(item).itemProvider { NSItemProvider(contentsOf: item.result ?? item.source) }
      }
    }
    .contextMenu(forSelectionType: FileBatch.Item.ID.self) { ids in
      let picked = model.items.filter { ids.contains($0.id) }
      Button("打开原图", systemImage: "arrow.up.forward.app") {
        for item in picked { NSWorkspace.shared.open(item.source) }
      }
      if picked.contains(where: { $0.result != nil }) {
        Button("打开转好的", systemImage: "arrow.up.forward.app") {
          for url in picked.compactMap(\.result) { NSWorkspace.shared.open(url) }
        }
      }
      Button("在访达中显示", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting(picked.map { $0.result ?? $0.source })
      }
      Divider()
      Button("移除", systemImage: "minus.circle") { model.remove(ids) }
    } primaryAction: { ids in
      for item in model.items where ids.contains(item.id) {
        NSWorkspace.shared.open(item.result ?? item.source)
      }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: false))
    .scrollContentBackground(.hidden)
    .onDeleteCommand { model.remove(selection) }
    .spacePreview {
      model.items.filter { selection.contains($0.id) }.map { $0.result ?? $0.source }
    }
  }

  /// 预览哪一张：选中的那一行，没选就第一张
  private var selected: FileBatch.Item? {
    model.items.first { selection.contains($0.id) } ?? model.items.first
  }

  @ViewBuilder private var optionGroups: some View {
    OptionGroup(title: "转成") {
      Picker("格式", selection: $format) {
        ForEach(ImageConverter.Format.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .labelsHidden()
    }
    if format.hasQuality {
      OptionGroup(
        title: "质量", footnote: Text("85% 看不出差别、文件小得多；要原样保留选 PNG 或 TIFF。")
      ) {
        HStack {
          Text("小").font(.caption).foregroundStyle(.secondary)
          Slider(value: $quality, in: 0.3...1).labelsHidden()
          Text("清晰").font(.caption).foregroundStyle(.secondary)
          Text(quality.formatted(.percent.precision(.fractionLength(0))))
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)
        }
      }
    }
    if format.iconSizes == nil {
      OptionGroup(title: "尺寸", footnote: Text("长边超过的等比缩小，小图不放大。")) {
        Picker("长边", selection: $maxSide) {
          Text("原尺寸").tag(0)
          ForEach([3840, 2560, 1920, 1280, 800], id: \.self) { Text("长边 \($0)").tag($0) }
        }
        .labelsHidden()
      }
    }
    OptionGroup(
      title: "隐私", footnote: Text("只去掉 GPS 位置，拍摄时间、相机照样带过去；发给别人前打开。")
    ) {
      Toggle("去掉定位信息", isOn: $stripLocation)
    }
    OptionGroup(title: "说明") {
      Text(hint).font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var summary: String {
    if model.items.isEmpty { return "还没有图片" }
    let failed = model.items.count { if case .failed = $0.state { true } else { false } }
    return "\(model.items.count) 张 · 已转 \(model.outputs.count)"
      + (failed > 0 ? " · \(failed) 张没转成" : "")
      + (model.skipped > 0 ? " · \(model.skipped) 个不是图片，没加进来" : "")
  }

  private var hint: String {
    var parts: [String] = []
    switch format {
    case .ico, .icns: parts.append("图标格式会等比放进正方形，做出几种尺寸。")
    case .gif, .tiff: parts.append("动图、多页的图会保留每一帧。")
    case .pdf: parts.append("每张图一页。")
    default:
      parts.append("照片的拍摄时间、相机\(stripLocation ? "" : "、定位")都会带过去，竖拍的自动转正。")
    }
    parts.append("结果放在原图旁边，重名加「 2」；换了格式或质量，转好的会回到等待中。转不成 WebP（系统写不了）。")
    return parts.joined()
  }
}
