// 会一直卡着线程、等系统框架自己做完的同步调用（Vision 认字、抠主体）放到 GCD 上跑，这边 await 它。
// 别在 Swift 并发的线程池上干等：macOS 27 上这些框架里面也要用那个池子，池子只有 CPU 核数那么多线程（8 核 8 个），
// 几件活一起干等就占满了，框架自己的活排不上，谁也等不到，整个卡死（2026-11-02 全量测试卡死时抓的堆栈：8 个线程全卡在
// 认字、读视频帧上；池子限成 1 个线程（LIBDISPATCH_COOPERATIVE_POOL_STRICT=1）时第一次认字就卡住）。GCD 的线程卡住了会再开。

import Foundation

nonisolated func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
{
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      continuation.resume(with: Result(catching: work))
    }
  }
}
