// ImageBatch：一批一起做——全做完、各自的结果和失败对得上，同时在做的不超过 4 张、也确实不止一张。

import Foundation
import Testing

@testable import KittyBox

struct ImageBatchTests {
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
    let batch = ImageBatch()
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
}
