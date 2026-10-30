// 去水印页（D1–D7）：工具栏中间三个模式——Gemini 角标（一批图一张一张去，右边预览、去好的拖线对比前后）、
// 画笔擦除（EraseCanvas）、视频台标（VideoMarkView）。
// 拖进来的是视频就切到视频台标；是图片就进 Gemini 角标，正停在画笔擦除时进画笔擦除（一次一张）。Gemini 认不出的那行能一键
// 改用画笔擦除。结果都是「原名-去水印」放在原文件旁边，不碰原文件。

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class WatermarkModel {
  enum Mode: CaseIterable {
    case gemini, erase, video

    var title: String {
      switch self {
      case .gemini: "Gemini 角标"
      case .erase: "画笔擦除"
      case .video: "视频台标"
      }
    }
  }

  var mode = Mode.gemini
  let gemini = ImageBatch()
  let erase = EraseModel()
  let video = VideoMarkModel()

  /// 图片进 Gemini 角标（正停在画笔擦除时进画笔擦除，取第一张）；视频（取第一段）进视频台标，两样都有时停在视频台标
  func add(_ urls: [URL]) {
    let images = urls.filter(ImageConverter.canRead)
    if mode == .erase, let first = images.first {
      erase.load(first)
    } else if !images.isEmpty {
      gemini.add(images)
      mode = .gemini
    }
    if let first = urls.first(where: VideoDelogo.isVideo) {
      video.load(first)
      mode = .video
    }
  }

  /// Gemini 认不出的图交给画笔擦除
  func handOff(_ url: URL) {
    erase.load(url)
    mode = .erase
  }
}

struct WatermarkView: View {
  @Bindable var model: WatermarkModel

  var body: some View {
    Group {
      switch model.mode {
      case .gemini: GeminiSection(batch: model.gemini, handOff: model.handOff)
      case .erase: EraseCanvas(model: model.erase)
      case .video: VideoMarkView(model: model.video)
      }
    }
    .frame(minWidth: 600, minHeight: 420)
    .navigationTitle("去水印")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("模式", selection: $model.mode) {
          ForEach(WatermarkModel.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
    }
    .fileDrop(Tool.watermark.color) { model.add($0) }
  }
}

/// Gemini 角标：左边一批图，点「去掉角标」一张一张去；认不出的那行写「没认出 Gemini 角标」。
/// 右边是选中那张的预览，去好了就是前后对比（拖中间的线）
private struct GeminiSection: View {
  @Bindable var batch: ImageBatch
  let handOff: (URL) -> Void
  @State private var choosing = false
  @State private var selection: ImageBatch.Item.ID?

  var body: some View {
    VStack(spacing: 0) {
      if batch.items.isEmpty {
        DropZone(
          symbol: "sparkle", color: Tool.watermark.color, title: "拖入 Gemini 生成的图",
          detail: "去掉右下角的星标，按原理还原、不靠猜；结果另存成「原名-去水印」"
        ) { choosing = true }
      } else {
        HStack(spacing: 0) {
          List(selection: $selection) {
            ForEach(batch.items) { item in
              BatchRow(
                item: item, doneVerb: "存成", removable: !batch.running,
                remove: { batch.remove(item.id) },
                onFailure: ("改用画笔擦除", handOff))
            }
          }
          .listStyle(.sidebar)
          .frame(width: 280)
          Divider()
          if let item = selected {
            BeforeAfter(source: item.source, result: item.result)
              .padding(16)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      HStack(spacing: 12) {
        Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
        if !batch.outputs.isEmpty {
          Button("清掉做完的") { batch.clearFinished() }.disabled(batch.running)
        }
        if !batch.items.isEmpty { Button("添加…") { choosing = true } }
        if batch.running { ProgressView().controlSize(.small) }
        Button("去掉角标") { Task { await batch.run { try await GeminiMark.clean($0) } } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!batch.hasWork || batch.running)
      }
      .bottomBar()
    }
    .fileImporter(
      isPresented: $choosing, allowedContentTypes: [.image], allowsMultipleSelection: true
    ) {
      if case .success(let urls) = $0 { batch.add(urls) }
    }
  }

  /// 选中的那张；没选（或选的被清掉了）就是第一张
  private var selected: ImageBatch.Item? {
    batch.items.first { $0.id == selection } ?? batch.items.first
  }

  private var hint: String {
    (batch.skipped > 0 ? "有 \(batch.skipped) 个不是能读的图片，没加进来。" : "")
      + "只认 Gemini 生成图右下角的星标；认不出的可以改用画笔擦除。"
  }
}

extension ImageBatch.Item {
  /// 做好了的结果文件
  var result: URL? { if case .done(let url) = state { url } else { nil } }
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
