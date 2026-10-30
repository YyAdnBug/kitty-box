// 图片转换页（C1–C3）：拖进图片 → 选转成什么（有损的再调质量）→ 转换，一张一张转，结果放在原图旁边。
// 换了格式或质量，转好的那些回到「等着」，再点一次按新的设置转（旧结果留在原处，新的重名加「 2」）。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConvertView: View {
  @Bindable var model: ImageBatch
  @AppStorage(Prefs.convertFormat) private var format = ImageConverter.Format.jpeg
  @AppStorage(Prefs.convertQuality) private var quality = 0.85
  @State private var choosing = false

  var body: some View {
    VStack(spacing: 0) {
      if model.items.isEmpty {
        DropHint(text: "把图片拖到这里，转好的放在原图旁边", symbol: "photo") { choosing = true }
          .padding(20)
        Spacer()
      } else {
        List(model.items) { item in
          BatchRow(item: item, doneVerb: "转成", removable: !model.running) { model.remove(item.id) }
        }
      }
      Divider()
      footer.padding(.horizontal, 20).padding(.vertical, 12)
    }
    .frame(minWidth: 600, minHeight: 360)
    .navigationTitle("图片转换")
    .dropDestination(for: URL.self) { urls, _ in
      model.add(urls)
      return true
    }
    .fileImporter(
      isPresented: $choosing, allowedContentTypes: [.image], allowsMultipleSelection: true
    ) {
      if case .success(let urls) = $0 { model.add(urls) }
    }
    .onChange(of: format) { model.resetDone() }
    .onChange(of: quality) { model.resetDone() }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 16) {
        Picker("转成", selection: $format) {
          ForEach(ImageConverter.Format.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .fixedSize()
        if format.hasQuality {
          HStack(spacing: 6) {
            Text("质量")
            Slider(value: $quality, in: 0.3...1).frame(width: 140)
            Text(quality.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
              .frame(width: 40, alignment: .trailing)
          }
        }
        Spacer()
        if model.running { ProgressView().controlSize(.small) }
        Button("转换") {
          let (format, quality) = (format, quality)
          Task {
            await model.run { try await ImageConverter.convert($0, to: format, quality: quality) }
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.hasWork || model.running)
      }
      HStack(spacing: 12) {
        Text(hint).font(.caption).foregroundStyle(.secondary)
        Spacer()
        if !model.outputs.isEmpty {
          Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(model.outputs) }
            .buttonStyle(.link)
          Button("清掉做完的") { model.clearFinished() }.disabled(model.running)
        }
        if !model.items.isEmpty { Button("添加…") { choosing = true } }
      }
    }
  }

  private var hint: String {
    var parts: [String] = []
    if model.skipped > 0 { parts.append("有 \(model.skipped) 个不是能读的图片，没加进来。") }
    switch format {
    case .ico, .icns: parts.append("图标格式会等比放进正方形，做出几种尺寸。")
    case .gif, .tiff: parts.append("动图、多页的图会保留每一帧。")
    case .pdf: parts.append("每张图一页。")
    default: parts.append("照片的拍摄时间、相机、定位都会带过去。")
    }
    parts.append("转不成 WebP（系统写不了）。")
    return parts.joined()
  }
}
