// FileBatch：一批一起做——全做完、各自的结果和失败对得上，同时在做的不超过 4 张、也确实不止一张；
// 一个一个做时停下：正在做的那个「已停止」，没开始的留着；只收 accepts 认的文件、重复的只收一个；跑的时候移除的不做、连按两下只开一批。

import Foundation
import Testing

@testable import KittyBox

struct FileBatchTests {
  /// 同时在做的有几张、最多到过几张
  private actor Gauge {
    var now = 0
    var peak = 0
    func enter() {
      now += 1
      peak = max(peak, now)
    }
    func leave() { now -= 1 }
  }

  @Test func runsSeveralAtOnce() async {
    let batch = FileBatch()
    batch.items = (1...8).map { .init(source: URL(filePath: "/tmp/kittybox-batch/\($0).png")) }
    let gauge = Gauge()
    await batch.run { source in
      await gauge.enter()
      try? await Task.sleep(for: .milliseconds(60))
      await gauge.leave()
      if source.lastPathComponent == "3.png" { throw CocoaError(.fileReadCorruptFile) }
      return source.deletingPathExtension().appendingPathExtension("jpg")
    }
    #expect(batch.outputs.count == 7)
    #expect(batch.outputs.contains(URL(filePath: "/tmp/kittybox-batch/8.jpg")))
    #expect(batch.items.filter { if case .failed = $0.state { true } else { false } }.count == 1)
    let peak = await gauge.peak
    #expect(peak > 1 && peak <= 4, "\(peak)")
    #expect(!batch.running)
  }

  @Test func stopsTheBatch() async throws {
    let batch = FileBatch(accepts: { $0.pathExtension == "mov" })
    // 同一次里重复的、已经在列表里的都只收一个
    batch.add(
      (1...3).map { URL(filePath: "/tmp/kittybox-batch/\($0).mov") } + [
        URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/kittybox-batch/1.mov"),
      ])
    #expect(batch.skipped == 1)
    batch.add([URL(filePath: "/tmp/kittybox-batch/2.mov")])
    #expect(batch.items.count == 3)
    // 一个要做一分钟的活：停下之前不可能做完（别的测试同时在主线程上跑重活，按时间等不靠谱）
    let work: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL = {
      source, progress in
      progress(0.5)
      try await Task.sleep(for: .seconds(60))
      return source
    }
    // 连按两下：只开一批，停止停的就是它
    batch.start(lanes: 1, work)
    batch.start(lanes: 1, work)
    for _ in 0..<500 {
      if case .running = batch.items[0].state { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    batch.stop()
    for _ in 0..<3000 where batch.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!batch.running)
    let states = batch.items.map(\.state)
    if case .failed(let reason) = states[0] {
      #expect(reason == "已停止")
    } else {
      Issue.record("\(states[0])")
    }
    #expect(states.dropFirst().allSatisfy { if case .waiting = $0 { true } else { false } })
  }

  /// 放行之前一直等着的活：记下做了哪几个
  private actor Gate {
    var names: [String] = []
    var open = false
    func enter(_ name: String) { names.append(name) }
    func release() { open = true }
  }

  /// 跑的时候移除了还没开始的那一行：不做它；连按两下「开始」只开一批（停止停得住见 stopsTheBatch）
  @Test func skipsRemovedRowsAndStartsOnce() async throws {
    let batch = FileBatch(accepts: { _ in true })
    batch.add((1...3).map { URL(filePath: "/tmp/kittybox-batch/\($0).mov") })
    let gate = Gate()
    let work: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL = {
      source, _ in
      await gate.enter(source.lastPathComponent)
      while await !gate.open { try await Task.sleep(for: .milliseconds(10)) }
      return source
    }
    batch.start(lanes: 1, work)
    batch.start(lanes: 1, work)
    #expect(batch.running)
    for _ in 0..<500 {
      if case .running = batch.items[0].state { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    batch.remove([batch.items[1].id])
    await gate.release()
    for _ in 0..<3000 where batch.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.names == ["1.mov", "3.mov"])
    #expect(batch.outputs.count == 2)
  }

  @Test func trimResetsDone() {
    let batch = FileBatch(accepts: { _ in true })
    let movie = URL(filePath: "/tmp/kittybox-batch/1.mov")
    batch.items = [.init(source: movie, state: .done(movie))]
    batch.setTrim(batch.items[0].id, 1...3)
    #expect(batch.items[0].trim == 1...3)
    #expect(batch.hasWork)
  }
}
