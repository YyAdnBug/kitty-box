// 一批图片一张一张处理、结果放在原图旁边：图片转换（C）和 Gemini 角标（D1）共用的列表模型和一行的样子。
// 拖进来的东西里只收系统能读的图片，别的数一下告诉用户。

import AppKit
import Observation
import SwiftUI

@Observable final class ImageBatch {
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

    /// 做好了的结果文件
    var result: URL? { if case .done(let url) = state { url } else { nil } }
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

  /// 移除选中的（正在做的不移）
  func remove(_ ids: Set<Item.ID>) {
    items.removeAll { item in
      guard ids.contains(item.id) else { return false }
      if case .running = item.state { return false }
      return true
    }
  }

  func clearFinished() {
    items.removeAll { if case .done = $0.state { true } else { false } }
  }

  /// 设置变了：做好的回到「等着」
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

  /// 把还没做好的交给 work（它把结果存在旁边、返回结果的位置），同时做几张：按核数，最多 4 张（RAW、大图解码吃内存）
  func run(_ work: @escaping @Sendable (URL) async throws -> URL) async {
    guard !running else { return }
    running = true
    defer { running = false }
    var queue = items.filter {
      switch $0.state {
      case .waiting, .failed: true
      default: false
      }
    }.map { ($0.id, $0.source) }[...]
    let lanes = min(ProcessInfo.processInfo.activeProcessorCount, 4)
    await withTaskGroup(of: (Item.ID, Result<URL, any Error>).self) { group in
      var inFlight = 0
      while true {
        // 补满：最多 lanes 张一起做
        while inFlight < lanes, let (id, source) = queue.popFirst() {
          update(id) { $0.state = .running }
          group.addTask {
            do { return (id, .success(try await work(source))) } catch {
              return (id, .failure(error))
            }
          }
          inFlight += 1
        }
        guard let (id, result) = await group.next() else { break }
        inFlight -= 1
        update(id) {
          switch result {
          case .success(let url): $0.state = .done(url)
          case .failure(let error): $0.state = .failed(error.localizedDescription)
          }
        }
      }
    }
    NSApp.bounceIfInBackground()
  }

  private func update(_ id: Item.ID, _ change: (inout Item) -> Void) {
    if let index = items.firstIndex(where: { $0.id == id }) { change(&items[index]) }
  }
}

/// 一张图的一行：缩略图、名字、做到哪了；做好的能在访达中显示，还没开始的能移除
struct BatchRow: View {
  let item: ImageBatch.Item
  /// 「转成」「存成」：做好了那行写「转成「x.jpg」」
  let doneVerb: String
  let removable: Bool
  let remove: () -> Void
  /// 没做成的那行后面跟一个按钮（Gemini 认不出时「改用画笔擦除」）
  var onFailure: (title: String, action: (URL) -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      FileThumb(url: item.source)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
        status.font(.system(size: 11))
      }
      Spacer(minLength: 4)
      if removable, case .waiting = item.state {
        Button("移除", systemImage: "xmark.circle.fill", action: remove)
          .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder private var status: some View {
    switch item.state {
    case .waiting:
      Text("等着").foregroundStyle(.secondary)
    case .running:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("正在处理…").foregroundStyle(.secondary)
      }
    case .done(let url):
      DoneLine(text: "\(doneVerb)「\(url.lastPathComponent)」", url: url)
    case .failed(let reason):
      VStack(alignment: .leading, spacing: 2) {
        FailLine(reason: reason)
        if let onFailure {
          Button(onFailure.title) { onFailure.action(item.source) }.buttonStyle(.link)
        }
      }
    }
  }
}
