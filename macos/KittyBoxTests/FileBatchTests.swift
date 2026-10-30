// FileBatch：一批一起做——全做完、各自的结果和失败对得上，同时在做的不超过 4 张、也确实不止一张；
// 一个一个做时停下：正在做的那个「已停止」，没开始的留着；只收 accepts 认的文件。

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
    batch.add(
      (1...3).map { URL(filePath: "/tmp/kittybox-batch/\($0).mov") } + [URL(filePath: "/tmp/a.txt")]
    )
    #expect(batch.items.count == 3)
    #expect(batch.skipped == 1)
    batch.start(lanes: 1) { source, progress in
      progress(0.5)
      try await Task.sleep(for: .seconds(5))
      return source
    }
    for _ in 0..<50 where !batch.running { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(100))
    batch.stop()
    for _ in 0..<200 where batch.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!batch.running)
    let states = batch.items.map(\.state)
    if case .failed(let reason) = states[0] {
      #expect(reason == "已停止")
    } else {
      Issue.record("\(states[0])")
    }
    #expect(states.dropFirst().allSatisfy { if case .waiting = $0 { true } else { false } })
  }
}
