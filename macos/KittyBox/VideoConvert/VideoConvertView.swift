// 视频转换页（M6）：拖进（⌘V 粘贴、⌘O 添加）一批视频 → 右边选项栏选转成什么（MP4 H.264 / HEVC、GIF、只要声音）、
// 缩到多大 → 页头「转换」，一个一个转（视频编码器就那么几路，一起转不见得快），每个有进度，能停下。
// 表格列时长、尺寸、大小、转换后的大小和差多少；右键打开 / 在访达中显示 / 移除，空格快速查看，做好的能拖出去。

import AVFoundation
import AppKit
import SwiftUI

struct VideoConvertView: View {
  @Bindable var model: FileBatch
  @AppStorage(Prefs.videoTarget) private var target = VideoConverter.Target.h264
  @AppStorage(Prefs.videoSize) private var size = VideoConverter.Size.original
  @State private var selection = Set<FileBatch.Item.ID>()

  var body: some View {
    ToolPage(tool: .videoConvert) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加视频（⌘O）")
      Button("清掉做完的", systemImage: "checklist.checked") { model.clearFinished() }
        .help("清掉转好的")
        .disabled(model.outputs.isEmpty || model.running)
      if model.running {
        Button("停止") { model.stop() }
          .buttonStyle(BrandButtonStyle())
          .help("停下正在转的，没开始的留着")
      } else {
        Button("转换") {
          let (target, size) = (target, size)
          model.start(lanes: 1) { source, progress in
            try await VideoConverter.convert(source, to: target, size: size, progress: progress)
          }
        }
        .buttonStyle(BrandButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(!model.hasWork)
      }
    } content: {
      if model.items.isEmpty {
        DropZone(
          tool: .videoConvert, title: "拖入视频",
          detail: "MOV、MP4、M4V 等；可以一次放一批，一个一个转，转好的放在原视频旁边")
      } else {
        table
      }
    } options: {
      optionGroups
    } status: {
      Text(summary)
      Spacer(minLength: 8)
      if !model.outputs.isEmpty, !model.running {
        Button("全部在访达中显示") {
          NSWorkspace.shared.activateFileViewerSelecting(model.outputs)
        }
        .buttonStyle(.link)
      }
    }
    .onChange(of: target) { model.resetDone() }
    .onChange(of: size) { model.resetDone() }
  }

  private var table: some View {
    Table(of: FileBatch.Item.self, selection: $selection) {
      TableColumn("视频") { item in
        HStack(spacing: 8) {
          FileThumb(url: item.source, size: 28)
          Text(item.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
        }
      }
      .width(min: 140, ideal: 190)
      TableColumn("时长") { VideoLengthText(url: $0.source).foregroundStyle(.secondary) }
        .width(min: 44, ideal: 50)
      TableColumn("尺寸") { VideoSizeText(url: $0.source).foregroundStyle(.secondary) }
        .width(min: 70, ideal: 84)
      TableColumn("大小") { FileSizeText(url: $0.source).foregroundStyle(.secondary) }
        .width(min: 54, ideal: 64)
      TableColumn("转换后") { item in
        switch item.state {
        case .waiting: Text("等待中").foregroundStyle(.tertiary)
        case .running:
          if let progress = item.progress {
            HStack(spacing: 6) {
              ProgressView(value: progress).frame(width: 80)
              Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                .foregroundStyle(.secondary)
            }
          } else {
            HStack(spacing: 6) {
              ProgressView().controlSize(.mini)
              Text("正在转换…").foregroundStyle(.secondary)
            }
          }
        case .done(let url): SizeChangeText(source: item.source, result: url)
        case .failed(let reason): FailLine(reason: reason)
        }
      }
      .width(min: 110, ideal: 140)
    } rows: {
      ForEach(model.items) { item in
        TableRow(item).itemProvider { NSItemProvider(contentsOf: item.result ?? item.source) }
      }
    }
    .contextMenu(forSelectionType: FileBatch.Item.ID.self) { ids in
      let picked = model.items.filter { ids.contains($0.id) }
      Button("打开原视频") { for item in picked { NSWorkspace.shared.open(item.source) } }
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
    .scrollContentBackground(.hidden)
    .onDeleteCommand { model.remove(selection) }
    .spacePreview {
      model.items.filter { selection.contains($0.id) }.map { $0.result ?? $0.source }
    }
  }

  @ViewBuilder private var optionGroups: some View {
    OptionGroup(title: "转成") {
      Picker("转成", selection: $target) {
        ForEach(VideoConverter.Target.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
    }
    if target == .h264 || target == .hevc {
      OptionGroup(title: "尺寸", footnote: Text("按短边算：横屏 720p 就是高 720；比它小的不放大。")) {
        Picker("尺寸", selection: $size) {
          ForEach(VideoConverter.Size.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
    }
    OptionGroup(title: "说明") {
      Text(hint).font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var hint: String {
    switch target {
    case .h264: "H.264 哪里都能放，手机、Windows、网页都认。想把文件压小，选 720p 或 480p。"
    case .hevc: "HEVC 同样清楚、文件小一半左右；很老的设备和部分网站不认。"
    case .gif:
      "每秒 \(Int(VideoConverter.gifFrameRate)) 帧、长边最多 \(Int(VideoConverter.gifMaxSide))、最多取前 \(Int(VideoConverter.gifMaxSeconds)) 秒，一直循环。GIF 文件大，长视频请转 MP4。"
    case .audio: "只留声音，存成 M4A（AAC），音乐、播客、录音都能直接放。"
    }
  }

  private var summary: String {
    if model.items.isEmpty { return "还没有视频" }
    let failed = model.items.count { if case .failed = $0.state { true } else { false } }
    return "\(model.items.count) 个视频 · 已转 \(model.outputs.count)"
      + (failed > 0 ? " · \(failed) 个没转成" : "")
      + (model.skipped > 0 ? " · \(model.skipped) 个不是视频，没加进来" : "")
  }
}

/// 表格里的「时长」：1:23
private struct VideoLengthText: View {
  let url: URL
  @State private var seconds: Double?

  var body: some View {
    Text(seconds.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? "--")
      .monospacedDigit()
      .task(id: url) { seconds = try? await AVURLAsset(url: url).load(.duration).seconds }
  }
}

/// 表格里的「尺寸」：1920 × 1080（转正之后的）
private struct VideoSizeText: View {
  let url: URL
  @State private var size: CGSize?

  var body: some View {
    Text(size.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "--")
      .monospacedDigit()
      .task(id: url) {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
          let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return }
        let oriented = natural.applying(transform)
        size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
      }
  }
}
