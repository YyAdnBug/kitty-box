// 图片转换页（C1–C3）：拖进图片 → 选转成什么（有损的再调质量）→ 转换，一张一张转，结果放在原图旁边。
// 换了格式或质量，转好的那些回到「等着」，再点一次按新的设置转（旧结果留在原处，新的重名加「 2」）。

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class ConvertModel {
  struct Item: Identifiable {
    enum State {
      case waiting
      case running
      case done(URL)
      case failed(String)
    }

    let id = UUID()
    let source: URL
    var state = State.waiting
  }

  var items: [Item] = []
  private(set) var running = false
  /// 上次拖进来的东西里有几个不是图片（没加进来）
  private(set) var skipped = 0

  func add(_ urls: [URL]) {
    let images = urls.filter(ImageConverter.canRead)
    skipped = urls.count - images.count
    let have = Set(items.map(\.source))
    items += images.filter { !have.contains($0) }.map { Item(source: $0) }
  }

  func remove(_ id: Item.ID) { items.removeAll { $0.id == id } }

  func clearFinished() {
    items.removeAll { if case .done = $0.state { true } else { false } }
  }

  /// 设置变了：转好的回到「等着」
  func resetDone() {
    for index in items.indices {
      if case .done = items[index].state { items[index].state = .waiting }
    }
  }

  var outputs: [URL] { items.compactMap { if case .done(let url) = $0.state { url } else { nil } } }

  var hasWork: Bool {
    items.contains {
      switch $0.state {
      case .waiting, .failed: true
      default: false
      }
    }
  }

  /// ponytail: 一张一张转；几百张时嫌慢再改成按核数并发
  func convert(to format: ImageConverter.Format, quality: Double) async {
    guard !running else { return }
    running = true
    defer { running = false }
    for item in items {
      switch item.state {
      case .waiting, .failed: break
      default: continue
      }
      update(item.id) { $0.state = .running }
      let state: Item.State
      do {
        state = .done(try await ImageConverter.convert(item.source, to: format, quality: quality))
      } catch {
        state = .failed(error.localizedDescription)
      }
      update(item.id) { $0.state = state }
    }
  }

  private func update(_ id: Item.ID, _ change: (inout Item) -> Void) {
    if let index = items.firstIndex(where: { $0.id == id }) { change(&items[index]) }
  }
}

struct ConvertView: View {
  @Bindable var model: ConvertModel
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
          ItemRow(item: item, removable: !model.running) { model.remove(item.id) }
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
        Button("转换") { Task { await model.convert(to: format, quality: quality) } }
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

private struct ItemRow: View {
  let item: ConvertModel.Item
  let removable: Bool
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: item.source.path))
        .resizable().frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(item.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
        status
      }
      Spacer()
      if removable, case .waiting = item.state {
        Button("移除", systemImage: "xmark.circle.fill", action: remove)
          .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder private var status: some View {
    switch item.state {
    case .waiting:
      Text("等着").font(.caption).foregroundStyle(.secondary)
    case .running:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("正在转换…").font(.caption).foregroundStyle(.secondary)
      }
    case .done(let url):
      HStack(spacing: 8) {
        Label("转成「\(url.lastPathComponent)」", systemImage: "checkmark.circle.fill")
          .font(.caption).foregroundStyle(.green)
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          .buttonStyle(.link).font(.caption)
      }
    case .failed(let reason):
      Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption)
        .foregroundStyle(.red)
    }
  }
}
