// 跑命令行工具（从 Kitty Tools 的 Shell/Subprocess.swift 拷来，加了 directory）：在进程外、不占主线程，等它结束拿退出码和输出。
// 解压的 tar、打包和解压的 7zz 都走这里（box-native §3：进程外 + continuation）。

import Foundation

enum Subprocess {
  struct Result {
    var status: Int32
    var output = ""
    var error = ""
  }

  /// captures = false 时输出直接丢掉。要的输出写进临时文件、结束后一次读完：管道缓冲只有 64 KB，
  /// 写满了子进程就卡住、等不到它结束（sqlite3 导出的浏览历史约 460 KB，ps 列几百个进程也可能超）。
  /// environment：不给就继承本进程的；timeout：到点还没结束就杀掉（SIGTERM，拿到的是非零状态；杀它的任务在主线程上，
  /// 主线程卡着时会晚到，只当兜底用）；
  /// quality：子进程的优先级（不急的活给 .utility）；directory：在哪个目录下跑（7zz 按清单打包时，清单里写的是相对它的路径）
  static func run(
    _ tool: String, _ arguments: [String], captures: Bool = false,
    environment: [String: String]? = nil, timeout: Duration? = nil,
    quality: QualityOfService = .default, directory: URL? = nil
  ) async throws -> Result {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.qualityOfService = quality
    if let environment { process.environment = environment }
    let watchdog = timeout.map { limit in
      Task {
        try? await Task.sleep(for: limit)
        if !Task.isCancelled, process.isRunning { process.terminate() }
      }
    }
    defer { watchdog?.cancel() }
    let files = captures ? [temporaryFile(), temporaryFile()] : []
    defer {
      for file in files { try? FileManager.default.removeItem(at: file) }
    }
    if captures {
      for file in files { FileManager.default.createFile(atPath: file.path, contents: nil) }
      process.standardOutput = try FileHandle(forWritingTo: files[0])
      process.standardError = try FileHandle(forWritingTo: files[1])
    } else {
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
    }
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    // 只关自己开的（nullDevice 是共用的，关了别处就写不进去了）
    if captures {
      for handle in [process.standardOutput, process.standardError] {
        try? (handle as? FileHandle)?.close()
      }
    }
    func read(_ index: Int) -> String {
      guard files.indices.contains(index), let data = try? Data(contentsOf: files[index]) else {
        return ""
      }
      return String(decoding: data, as: UTF8.self)
    }
    return Result(status: status, output: read(0), error: read(1))
  }

  private static func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "kittybox-\(UUID().uuidString)")
  }
}
