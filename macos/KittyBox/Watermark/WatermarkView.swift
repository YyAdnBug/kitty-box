// 去水印页（D1–D7）：顶上三个模式——Gemini 角标（一批图一张一张去）、画笔擦除（EraseCanvas）、视频台标（VideoMarkView）。
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
    VStack(spacing: 0) {
      Picker("模式", selection: $model.mode) {
        ForEach(WatermarkModel.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .padding(.vertical, 12)
      Divider()
      switch model.mode {
      case .gemini: GeminiSection(batch: model.gemini, handOff: model.handOff)
      case .erase: EraseCanvas(model: model.erase)
      case .video: VideoMarkView(model: model.video)
      }
    }
    .frame(minWidth: 600, minHeight: 420)
    .navigationTitle("去水印")
    .dropDestination(for: URL.self) { urls, _ in
      model.add(urls)
      return true
    }
  }
}

/// Gemini 角标：一批图，点「去掉角标」一张一张去；认不出的那行写「没认出 Gemini 角标」
private struct GeminiSection: View {
  @Bindable var batch: ImageBatch
  let handOff: (URL) -> Void
  @State private var choosing = false

  var body: some View {
    VStack(spacing: 0) {
      if batch.items.isEmpty {
        DropHint(text: "把 Gemini 生成的图拖到这里，去掉右下角的星标", symbol: "sparkle") { choosing = true }
          .padding(20)
        Spacer()
      } else {
        List(batch.items) { item in
          BatchRow(
            item: item, doneVerb: "存成", removable: !batch.running,
            remove: { batch.remove(item.id) },
            onFailure: ("改用画笔擦除", handOff))
        }
      }
      Divider()
      HStack(spacing: 12) {
        Text(hint).font(.caption).foregroundStyle(.secondary)
        Spacer()
        if !batch.outputs.isEmpty {
          Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(batch.outputs) }
            .buttonStyle(.link)
          Button("清掉做完的") { batch.clearFinished() }.disabled(batch.running)
        }
        if !batch.items.isEmpty { Button("添加…") { choosing = true } }
        if batch.running { ProgressView().controlSize(.small) }
        Button("去掉角标") { Task { await batch.run { try await GeminiMark.clean($0) } } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!batch.hasWork || batch.running)
      }
      .padding(.horizontal, 20).padding(.vertical, 12)
    }
    .fileImporter(
      isPresented: $choosing, allowedContentTypes: [.image], allowsMultipleSelection: true
    ) {
      if case .success(let urls) = $0 { batch.add(urls) }
    }
  }

  private var hint: String {
    (batch.skipped > 0 ? "有 \(batch.skipped) 个不是能读的图片，没加进来。" : "")
      + "按原理还原、不靠猜，只认 Gemini 生成图右下角的星标；认不出的可以改用画笔擦除。"
  }
}
