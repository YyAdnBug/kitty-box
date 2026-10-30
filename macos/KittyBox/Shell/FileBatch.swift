// 一批文件交给同一件事处理、结果放在原文件旁边：图片转换（C）、Gemini 角标（D1）、视频转换（M6）共用的列表模型，
// 和列表的一行（BatchRow）。拖进来的东西里只收这一页能处理的（accepts），别的数一下告诉用户。
// 几个一起做（lanes），每一个能报进度；用 start 开始的能 stop：取消整批，正在做的那几个写「已停止」，没开始的留着。

import AppKit
import Observation
import SwiftUI

@Observable final class FileBatch {
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
    /// 正在做时的进度 0–1；不报进度的活是 nil
    var progress: Double?
    /// 视频转换：只转这一段（秒）；nil = 整段
    var trim: ClosedRange<Double>?

    /// 做好了的结果文件
    var result: URL? { if case .done(let url) = state { url } else { nil } }
  }

  var items: [Item] = []
  private(set) var running = false
  /// 上次拖进来的东西里有几个这一页收不了（没加进来）
  private(set) var skipped = 0
  /// 收哪些文件：图片转换、Gemini 收图片，视频转换收视频
  @ObservationIgnored private let accepts: (URL) -> Bool
  /// start 开始的那一批（stop 取消它）
  @ObservationIgnored private var runner: Task<Void, Never>?

  init(accepts: @escaping (URL) -> Bool = ImageConverter.canRead) {
    self.accepts = accepts
  }

  func add(_ urls: [URL]) {
    let taken = urls.filter(accepts)
    skipped = urls.count - taken.count
    let have = Set(items.map(\.source))
    items += taken.filter { !have.contains($0) }.map { Item(source: $0) }
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

  /// 视频转换选了一段（nil = 不剪了）：做好的那个回到「等着」
  func setTrim(_ id: Item.ID, _ range: ClosedRange<Double>?) {
    update(id) {
      $0.trim = range
      if case .done = $0.state { $0.state = .waiting }
    }
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

  /// 不报进度的活：几个一起做，按核数、最多 4 个（RAW、大图解码吃内存）
  func run(_ work: @escaping @Sendable (URL) async throws -> URL) async {
    await run(lanes: min(ProcessInfo.processInfo.activeProcessorCount, 4)) { source, _ in
      try await work(source)
    }
  }

  /// 把还没做好的交给 work（它把结果存在旁边、返回结果的位置，一路报进度 0–1），lanes 个一起做
  func run(
    lanes: Int,
    _ work: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL
  ) async {
    guard !running else { return }
    running = true
    defer { running = false }
    var queue = items.filter {
      switch $0.state {
      case .waiting, .failed: true
      default: false
      }
    }.map { ($0.id, $0.source) }[...]
    await withTaskGroup(of: (Item.ID, Result<URL, any Error>).self) { group in
      var inFlight = 0
      while true {
        // 补满：最多 lanes 个一起做；整批被停下了就不再开新的
        while inFlight < lanes, !Task.isCancelled, let (id, source) = queue.popFirst() {
          update(id) {
            $0.state = .running
            $0.progress = nil
          }
          group.addTask {
            let report: @Sendable (Double) -> Void = { fraction in
              Task { @MainActor in self.update(id) { $0.progress = fraction } }
            }
            do { return (id, .success(try await work(source, report))) } catch {
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
          case .failure(is CancellationError): $0.state = .failed("已停止")
          case .failure(let error): $0.state = .failed(error.localizedDescription)
          }
        }
      }
    }
    NSApp.bounceIfInBackground()
  }

  /// 开始一批（之后能 stop）
  func start(
    lanes: Int,
    _ work: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL
  ) {
    guard !running else { return }
    runner = Task { await run(lanes: lanes, work) }
  }

  /// 停下 start 开始的那一批：正在做的取消，没开始的留着
  func stop() { runner?.cancel() }

  private func update(_ id: Item.ID, _ change: (inout Item) -> Void) {
    if let index = items.firstIndex(where: { $0.id == id }) { change(&items[index]) }
  }
}

/// 一张图的一行：缩略图、名字、做到哪了；做好的能在访达中显示，还没开始的能移除
struct BatchRow: View {
  let item: FileBatch.Item
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
        if let progress = item.progress {
          ProgressView(value: progress).frame(width: 90)
          Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            .foregroundStyle(.secondary)
        } else {
          ProgressView().controlSize(.mini)
          Text("正在处理…").foregroundStyle(.secondary)
        }
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
