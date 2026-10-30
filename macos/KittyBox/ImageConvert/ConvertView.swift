// 图片转换页（C1–C3）：拖进（⌘V 粘贴、⌘O 添加）图片 → 右边「选项」选转成什么（有损的再调质量）→ 工具栏「转成 X」，
// 一张一张转，结果放在原图旁边。表格列尺寸、大小、转换后的大小和差多少（照常见压图工具）；右键打开 / 在访达中显示 / 移除。
// 换了格式或质量，转好的那些回到「等待中」，再点一次按新的设置转（旧结果留在原处，新的重名加「 2」）。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConvertView: View {
  @Bindable var model: ImageBatch
  @AppStorage(Prefs.convertFormat) private var format = ImageConverter.Format.jpeg
  @AppStorage(Prefs.convertQuality) private var quality = 0.85
  @AppStorage(Prefs.showsOptions) private var showsOptions = true
  @State private var selection = Set<ImageBatch.Item.ID>()

  var body: some View {
    VStack(spacing: 0) {
      if model.items.isEmpty {
        DropZone(
          tool: .convert, title: "拖入图片",
          detail: "HEIC、WebP、RAW、PSD 等都能读，转好的放在原图旁边，拍摄信息带过去")
      } else {
        table
      }
      StatusBar {
        Text(summary)
      } trailing: {
        if model.running {
          ProgressView().controlSize(.mini)
          Text("正在转换…")
        } else if !model.outputs.isEmpty {
          Button("全部在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting(model.outputs)
          }
          .buttonStyle(.link)
        }
      }
    }
    .navigationTitle("图片转换")
    .toolbar {
      ToolbarItemGroup {
        Button("添加文件", systemImage: "plus") { Navigator.shared.importing = true }
          .help("添加图片（⌘O）")
        Button("清掉做完的", systemImage: "checklist.checked") { model.clearFinished() }
          .help("清掉转好的")
          .disabled(model.outputs.isEmpty || model.running)
      }
      ToolbarItem {
        Button("选项", systemImage: "sidebar.trailing") { showsOptions.toggle() }
          .help(showsOptions ? "收起选项" : "显示选项")
      }
      ToolbarItem(placement: .primaryAction) {
        Button("转成 \(format.title)") {
          let (format, quality) = (format, quality)
          Task {
            await model.run { try await ImageConverter.convert($0, to: format, quality: quality) }
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.hasWork || model.running)
      }
    }
    .inspector(isPresented: $showsOptions) {
      options.inspectorColumnWidth(min: 260, ideal: 280, max: 360)
    }
    .onChange(of: format) { model.resetDone() }
    .onChange(of: quality) { model.resetDone() }
  }

  private var table: some View {
    Table(model.items, selection: $selection) {
      TableColumn("图片") { item in
        HStack(spacing: 8) {
          FileThumb(url: item.source, size: 28)
          Text(item.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
        }
      }
      .width(min: 180, ideal: 260)
      TableColumn("尺寸") { PixelSizeText(url: $0.source).foregroundStyle(.secondary) }
        .width(min: 80, ideal: 100)
      TableColumn("大小") { FileSizeText(url: $0.source).foregroundStyle(.secondary) }
        .width(min: 60, ideal: 76)
      TableColumn("转换后") { item in
        switch item.state {
        case .waiting: Text("等待中").foregroundStyle(.tertiary)
        case .running:
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("正在转换…").foregroundStyle(.secondary)
          }
        case .done(let url): SizeChangeText(source: item.source, result: url)
        case .failed(let reason): FailLine(reason: reason)
        }
      }
      .width(min: 120, ideal: 160)
    }
    .contextMenu(forSelectionType: ImageBatch.Item.ID.self) { ids in
      let picked = model.items.filter { ids.contains($0.id) }
      Button("打开原图") { for item in picked { NSWorkspace.shared.open(item.source) } }
      if picked.contains(where: { $0.result != nil }) {
        Button("打开转好的") { for url in picked.compactMap(\.result) { NSWorkspace.shared.open(url) } }
      }
      Button("在访达中显示") {
        NSWorkspace.shared.activateFileViewerSelecting(picked.map { $0.result ?? $0.source })
      }
      Divider()
      Button("移除") { model.remove(ids) }
    } primaryAction: { ids in
      for item in model.items where ids.contains(item.id) {
        NSWorkspace.shared.open(item.result ?? item.source)
      }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: false))
    .onDeleteCommand { model.remove(selection) }
  }

  private var options: some View {
    Form {
      Section("转成") {
        Picker("格式", selection: $format) {
          ForEach(ImageConverter.Format.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
      }
      if format.hasQuality {
        Section {
          Slider(value: $quality, in: 0.3...1) {
            Text("质量")
          } minimumValueLabel: {
            Text("小")
          } maximumValueLabel: {
            Text("清晰")
          }
          .labelsHidden()
        } header: {
          HStack {
            Text("质量")
            Spacer()
            Text(quality.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
          }
        } footer: {
          Text("85% 看不出差别、文件小得多；要原样保留选 PNG 或 TIFF。").font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Section("说明") {
        Text(hint).font(.callout).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
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
    default: parts.append("照片的拍摄时间、相机、定位都会带过去，竖拍的自动转正。")
    }
    parts.append("结果放在原图旁边，重名加「 2」；换了格式或质量，转好的会回到等待中。转不成 WebP（系统写不了）。")
    return parts.joined()
  }
}
