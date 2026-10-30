// 画笔擦除的补图模型（D2，2026-10-30 用户改成「用时下载」）：不随包——它一个就占了安装包的 207 MB——第一次用画笔擦除时下载。
// 来源是 Hugging Face 上 mlboydaisuke/LaMa-CoreML 固定的 revision（FP32，M4 选型见 PLAN §2「画笔擦除」），三个文件各按
// SHA256 校验，对不上就不装；下好用 Core ML 编译，放进「~/Library/Application Support/Kitty Box/Models/LaMa.mlmodelc」，
// 以后不用再下、不用联网。正式版和开发版共用这一份。Hugging Face 连不上（比如在国内）时自动换镜像 hf-mirror.com 再下一遍
// （2026-10-30 实测同一个 revision 的文件一样，反正每个都按 SHA256 校验，镜像给错了也装不上）。
// App 自己用 URLSession 下载，不带隔离标记。许可证 Apache-2.0
// （Resources/lama-LICENSE.txt）。LaMaDownload 是界面上看的那份状态（没下 / 下载中 / 好了 / 没成）。

import CoreML
import CryptoKit
import Foundation
import Observation

nonisolated enum LaMaModel {
  struct File {
    let path: String
    let sha256: String
    let size: Int64
  }

  /// 按顺序试：Hugging Face 本站，下不了再换镜像
  static let sources = ["https://huggingface.co", "https://hf-mirror.com"].map {
    URL(
      string: $0
        + "/mlboydaisuke/LaMa-CoreML/resolve/5ed76e3799ab4cad31381750d29880c267477e18/LaMa.mlpackage/"
    )!
  }
  static let files = [
    File(
      path: "Manifest.json",
      sha256: "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58", size: 617),
    File(
      path: "Data/com.apple.CoreML/model.mlmodel",
      sha256: "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953", size: 1_101_809),
    File(
      path: "Data/com.apple.CoreML/weights/weight.bin",
      sha256: "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184",
      size: 215_544_960),
  ]
  /// 要下多少（给人看的「约 216 MB」）
  static let downloadSize = files.reduce(0) { $0 + $1.size }

  static var folder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Kitty Box/Models")
  }
  static var installed: URL { folder.appending(path: "LaMa.mlmodelc") }
  static var isInstalled: Bool {
    FileManager.default.fileExists(atPath: installed.appending(path: "coremldata.bin").path)
  }

  enum Failure: LocalizedError {
    case download(String)
    case checksum(String)

    var errorDescription: String? {
      switch self {
      case .download(let reason): "模型没下载成：" + reason
      case .checksum(let file): "下载的模型文件（\(file)）和预期的不一样，没装。"
      }
    }
  }

  /// 下载、校验、编译、放好。progress：0…1，按字节（编译那几秒停在 1）
  @concurrent static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let staging = try fileManager.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
    defer { try? fileManager.removeItem(at: staging) }
    let package = staging.appending(path: "LaMa.mlpackage")
    try await fetch(files, fromFirstOf: sources, into: package, progress: progress)
    let compiled = try await MLModel.compileModel(at: package)
    defer { try? fileManager.removeItem(at: compiled) }
    if fileManager.fileExists(atPath: installed.path) {
      _ = try fileManager.replaceItemAt(installed, withItemAt: compiled)
    } else {
      try fileManager.moveItem(at: compiled, to: installed)
    }
  }

  /// 一个地址一个地址试：前一个下到一半失败（连不上、服务器报错、校验不过），清掉已经下的、进度归零，换下一个；都不行就报最后那个错
  static func fetch(
    _ files: [File], fromFirstOf sources: [URL], into package: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    var failure: any Error = Failure.download("没有可用的下载地址")
    for source in sources {
      do {
        try await fetch(files, from: source, into: package, progress: progress)
        return
      } catch {
        failure = error
        try? FileManager.default.removeItem(at: package)
        progress(0)
      }
    }
    throw failure
  }

  /// 一个个下到 package 里（保持原来的目录结构），每个都按 SHA256 校验；对不上就停，已经下的留在 package 里由调用方删
  static func fetch(
    _ files: [File], from base: URL, into package: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let total = Double(files.reduce(0) { $0 + $1.size })
    var done: Int64 = 0
    for file in files {
      let (before, size) = (Double(done), Double(file.size))
      let (temporary, response) = try await URLSession.shared.download(
        from: base.appending(path: file.path),
        delegate: DownloadWatcher { fraction in progress((before + fraction * size) / total) })
      defer { try? FileManager.default.removeItem(at: temporary) }
      if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
        throw Failure.download("服务器回了 \(status)")
      }
      guard try sha256(of: temporary) == file.sha256 else { throw Failure.checksum(file.path) }
      let target = package.appending(path: file.path)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: temporary, to: target)
      done += file.size
      progress(Double(done) / total)
    }
  }

  /// 分块读：两百多 MB 不一次读进内存
  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// 模型下载的状态（画笔擦除页顶上那一条、「擦除」按钮能不能点）
@Observable final class LaMaDownload {
  enum State: Equatable {
    case missing
    case downloading(Double)
    case ready
    case failed(String)
  }

  static let shared = LaMaDownload()

  private(set) var state: State = LaMaModel.isInstalled ? .ready : .missing

  func start() async {
    switch state {
    case .downloading, .ready: return
    case .missing, .failed: break
    }
    state = .downloading(0)
    do {
      try await LaMaModel.install { fraction in
        let percent = (fraction * 100).rounded() / 100
        Task { @MainActor in
          if case .downloading(let shown) = LaMaDownload.shared.state, shown != percent {
            LaMaDownload.shared.state = .downloading(percent)
          }
        }
      }
      state = .ready
    } catch {
      state = .failed(error.localizedDescription)
    }
  }
}
