// 下载进度：URLSession 的 async download(from:delegate:) 本身不报进度，挂上这个委托就能一路报下了多少（0…1）。

import Foundation
import Synchronization

/// 看着一次下载下了多少（应用内更新和画笔擦除的模型下载共用；同 Kitty Tools：async 的 download(from:) 不报进度，委托只在 didCreateTask 把任务交过来，
/// 之后看它的 progress）。服务器没给大小就不报。观察的令牌放在 Mutex 里（不用 nonisolated(unsafe)）。
/// 整个类 nonisolated：URLSession 在它自己的线程上回调，跟着默认的主线程隔离会在后台触发执行器断言闪退
nonisolated final class DownloadWatcher: NSObject, URLSessionTaskDelegate, Sendable {
  private let report: @Sendable (Double) -> Void
  private let observation = Mutex<NSKeyValueObservation?>(nil)

  init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

  func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    let token = task.progress.observe(\.fractionCompleted) { [report] _, _ in
      let expected = task.countOfBytesExpectedToReceive
      if expected > 0 { report(Double(task.countOfBytesReceived) / Double(expected)) }
    }
    observation.withLock { $0 = token }
  }
}
