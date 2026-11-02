// 用时下载的模型（都不随包，设置 › 模型里下载、删除）。补图模型（画笔擦除和 AI 水印共用，D2 用时下载；M7 起三个可选、设置里切换）：
// - 快速：MI-GAN 512（Picsart AI Research，MIT），约 25 MB，一处零点几秒，细节一般；
//   Core ML 版来自 Hugging Face 上 BryanHaley/photowagon-models 的 migan/MIGAN.mlpackage.zip；
// - 标准：LaMa 800（FP32，Apache-2.0），约 216 MB，一处约 1 秒，推荐（M4 选型见 PLAN §2「画笔擦除」）；
//   来源 mlboydaisuke/LaMa-CoreML 固定的 revision，三个文件各按 SHA256 校验；
// - 高清：Big LaMa 2048（Apache-2.0），约 190 MB，一次补 2048 见方，大图、大块更清楚，一处几秒；
//   来源 local-vision-models/lama-2048-coreml 的 LaMa2048.mlpackage.zip。
// 抠图模型（M9，去背景选「精细」时用；用户说系统的效果不好、问 GitHub 上有没有好的）：BiRefNet Lite 1024（MIT），约 82 MB，
//   什么都能抠（不只人和动物），头发丝、绒毛的边干净，一张约 1 秒（只用 CPU，见 Cutout）；Core ML 版来自 Hugging Face 上
//   metaclass/birefnet-lite-coreml 固定 revision 的 fp16compute-fp32io/r1 zip（转换脚本在 GitHub 的 miracle2k/birefnet-lite-coreml，MIT）。
// 三个补图模型的输入都是 image（RGB 图）+ mask（8 位灰度，白 = 要补），输出 output（RGB 图），边长按模型自己的输入约束（Inpainter 读）。
// zip 包整个按 SHA256 校验（ponytail: 这两个没有固定 revision，用 main，上游换了文件校验就不过、装不上，到时候更新 SHA256），
// 再用系统 tar 解开（bsdtar 认 zip）。下好用 Core ML 编译，放进「~/Library/Application Support/Kitty Box/Models/<名字>.mlmodelc」，
// 正式版和开发版共用。Hugging Face 连不上（比如在国内）时自动换镜像 hf-mirror.com 再下一遍（反正逐个校验，镜像给错了也装不上）。
// App 自己用 URLSession 下载，不带隔离标记。许可证在 Resources/lama-LICENSE.txt、migan-LICENSE.txt、birefnet-LICENSE.txt。
// ModelDownloads 是界面上看的那份状态（每个模型：没下 / 下载中 / 好了 / 没成）。

import CoreML
import CryptoKit
import Foundation
import Observation
import SwiftUI

nonisolated enum AIModel: String, CaseIterable, Identifiable, Sendable {
  case fast, standard, hd, cutout

  var id: Self { self }

  /// 补图的那三个（设置里选一个给画笔擦除、AI 水印用）
  static let inpainters: [AIModel] = [.fast, .standard, .hd]

  /// 「补图模型」「抠图模型」（下载提示里说要下的是什么）
  var kind: String { self == .cutout ? "抠图模型" : "补图模型" }

  var title: String {
    switch self {
    case .fast: "快速"
    case .standard: "标准"
    case .hd: "高清"
    case .cutout: "精细"
    }
  }

  var name: String {
    switch self {
    case .fast: "MI-GAN"
    case .standard: "LaMa"
    case .hd: "Big LaMa 2048"
    case .cutout: "BiRefNet"
    }
  }

  var detail: String {
    switch self {
    case .fast: "下得快、补得快（一处零点几秒），小水印够用，大块细节一般"
    case .standard: "又快又好（一处约 1 秒），推荐"
    case .hd: "一次补 2048 见方，大图、大块更清楚，一处几秒"
    case .cutout: "什么都能抠，头发丝、绒毛的边干净，一张约 1 秒"
    }
  }

  /// 要下多少（给人看的「约 216 MB」、进度的权重）
  var downloadSize: Int64 {
    switch payload {
    case .files(_, let files): files.reduce(0) { $0 + $1.size }
    case .zip(_, _, let size): size
    }
  }

  struct File {
    let path: String
    let sha256: String
    let size: Int64
  }

  /// 怎么下：一个 mlpackage 的几个文件，或者一个 mlpackage 的 zip（路径相对 Hugging Face 站点）
  private enum Payload {
    case files(String, [File])
    case zip(String, sha256: String, size: Int64)
  }

  private var payload: Payload {
    switch self {
    case .fast:
      .zip(
        "BryanHaley/photowagon-models/resolve/main/migan/MIGAN.mlpackage.zip",
        sha256: "c279edffd937627477b716376cea8e51aa8ac42c1691c8b47365020b915903c8",
        size: 24_500_000)
    case .standard:
      .files(
        "mlboydaisuke/LaMa-CoreML/resolve/5ed76e3799ab4cad31381750d29880c267477e18/LaMa.mlpackage/",
        [
          File(
            path: "Manifest.json",
            sha256: "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58", size: 617),
          File(
            path: "Data/com.apple.CoreML/model.mlmodel",
            sha256: "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953",
            size: 1_101_809),
          File(
            path: "Data/com.apple.CoreML/weights/weight.bin",
            sha256: "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184",
            size: 215_544_960),
        ])
    case .hd:
      .zip(
        "local-vision-models/lama-2048-coreml/resolve/main/LaMa2048.mlpackage.zip",
        sha256: "094279456cc4ac4d682ee771bdca0032bd353aaa8e1ba9aa3b3d60b52bbcd353",
        size: 190_000_000)
    case .cutout:
      .zip(
        "metaclass/birefnet-lite-coreml/resolve/519543b900332b0fd834ab7a40a17099b2d2e7cb/fp16compute-fp32io/r1/BiRefNetLite-1024-FP16Compute-FP32IO-iOS17-r1.mlpackage.zip",
        sha256: "46e7f3306069d1385761c0db86d65913dc3f980bf5348eb0c3db429e3f8414b7",
        size: 82_250_830)
    }
  }

  /// 按顺序试：Hugging Face 本站，下不了再换镜像
  static let hosts = ["https://huggingface.co", "https://hf-mirror.com"]

  static var folder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Kitty Box/Models")
  }

  /// 标准那个沿用 D2 时的名字 LaMa.mlmodelc（已经下过的不用重下）
  var installed: URL {
    let stem =
      switch self {
      case .fast: "MIGAN"
      case .standard: "LaMa"
      case .hd: "LaMa2048"
      case .cutout: "BiRefNet"
      }
    return Self.folder.appending(path: stem + ".mlmodelc")
  }

  var isInstalled: Bool {
    FileManager.default.fileExists(atPath: installed.appending(path: "coremldata.bin").path)
  }

  /// 删掉下好的（设置里「删除」）
  func remove() throws {
    if FileManager.default.fileExists(atPath: installed.path) {
      try FileManager.default.removeItem(at: installed)
    }
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

  /// 下载、校验、（zip 的解开）、编译、放好。progress：0…1，按字节（解开、编译那几秒停在 1）
  @concurrent func install(progress: @escaping @Sendable (Double) -> Void) async throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    let staging = try fileManager.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Self.folder, create: true
    )
    defer { try? fileManager.removeItem(at: staging) }
    let package: URL
    switch payload {
    case .files(let path, let files):
      package = staging.appending(path: "Model.mlpackage")
      try await Self.fetch(
        files, fromFirstOf: Self.hosts.map { URL(string: $0 + "/" + path)! }, into: package,
        progress: progress)
    case .zip(let path, let sha256, let size):
      let name = (path as NSString).lastPathComponent
      let folder = (path as NSString).deletingLastPathComponent + "/"
      let download = staging.appending(path: "download")
      try await Self.fetch(
        [File(path: name, sha256: sha256, size: size)],
        fromFirstOf: Self.hosts.map { URL(string: $0 + "/" + folder)! }, into: download,
        progress: progress)
      package = try await Self.unzipPackage(download.appending(path: name), into: staging)
    }
    let compiled = try await MLModel.compileModel(at: package)
    defer { try? fileManager.removeItem(at: compiled) }
    // 编译停不下来：编译的时候点了「取消」，编好了也不装
    try Task.checkCancellation()
    if fileManager.fileExists(atPath: installed.path) {
      _ = try fileManager.replaceItemAt(installed, withItemAt: compiled)
    } else {
      try fileManager.moveItem(at: compiled, to: installed)
    }
  }

  /// 用系统 tar 解开 zip（bsdtar 认 zip），找出里面的 .mlpackage（略过 __MACOSX）
  static func unzipPackage(_ zip: URL, into folder: URL) async throws -> URL {
    let out = folder.appending(path: "unzipped")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let result = try await Subprocess.run(
      "/usr/bin/tar", ["-xf", zip.path, "-C", out.path, "--exclude", "__MACOSX"], captures: true)
    guard result.status == 0 else { throw Failure.download("解不开下载的模型包") }
    guard
      let walker = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil),
      let package = walker.lazy.compactMap({ $0 as? URL }).first(where: {
        $0.pathExtension == "mlpackage"
      })
    else { throw Failure.download("下载的包里没有模型") }
    return package
  }

  /// 一个地址一个地址试：前一个下到一半失败（连不上、服务器报错、校验不过），清掉已经下的、进度归零，换下一个；都不行就报最后那个错。
  /// 用户点了「取消」就停，不再换镜像
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
        try Task.checkCancellation()
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
      try Task.checkCancellation()
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

/// 各个模型的下载状态（设置 › 模型、画笔擦除、AI 水印、去背景页顶上那一条）
@Observable final class ModelDownloads {
  enum State: Equatable {
    case missing
    case downloading(Double)
    case ready
    case failed(String)
  }

  static let shared = ModelDownloads()

  private(set) var states: [AIModel: State] = Dictionary(
    uniqueKeysWithValues: AIModel.allCases.map { ($0, $0.isInstalled ? .ready : .missing) })
  /// 正在下的（「取消」停它）
  @ObservationIgnored private var jobs: [AIModel: Task<Void, Never>] = [:]

  func state(of model: AIModel) -> State { states[model] ?? .missing }

  func start(_ model: AIModel) {
    guard jobs[model] == nil, state(of: model) != .ready else { return }
    states[model] = .downloading(0)
    jobs[model] = Task {
      do {
        try await ProcessInfo.processInfo.working("正在下载\(model.kind)") {
          try await model.install { fraction in
            let percent = (fraction * 100).rounded() / 100
            Task { @MainActor in
              if case .downloading(let shown) = ModelDownloads.shared.state(of: model),
                shown != percent
              {
                ModelDownloads.shared.states[model] = .downloading(percent)
              }
            }
          }
        }
        states[model] = .ready
        // 几百 MB 要下好一阵：旁白念一句（不跳程序坞图标，那是给打包、解压这些活的）
        AccessibilityNotification.Announcement("\(model.kind)「\(model.title)」下好了").post()
      } catch {
        // 取消了：回到没下（下了一半的在 install 的临时文件夹里，已经删了）
        states[model] = Task.isCancelled ? .missing : .failed(error.localizedDescription)
        if !Task.isCancelled {
          AccessibilityNotification.Announcement("\(model.kind)没下成：" + error.localizedDescription)
            .post()
        }
      }
      jobs[model] = nil
    }
  }

  /// 停下正在下的（几百 MB，下错了、网慢时不用干等）
  func cancel(_ model: AIModel) { jobs[model]?.cancel() }

  /// 删掉下好的（正在用的也能删，用时再下）
  func remove(_ model: AIModel) {
    try? model.remove()
    Task {
      if model == .cutout {
        await Matting.shared.forget()
      } else {
        await Inpainter.shared.forget(model)
      }
    }
    states[model] = model.isInstalled ? .ready : .missing
  }
}
