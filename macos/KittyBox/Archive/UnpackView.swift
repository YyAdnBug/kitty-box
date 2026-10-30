// 解压页（B7–B9）：拖进压缩包就一个接一个解，解到包旁边。有密码的停下来就地问（不记），密码不对说一声再问。
// 拖到程序坞图标上的压缩包也进这里（Navigator），直接开始。

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class UnpackModel {
  struct Job: Identifiable {
    enum State {
      case waiting
      case running
      case done(URL)
      /// again：上次给的密码不对
      case needsPassword(again: Bool)
      case failed(String)
    }

    let id = UUID()
    let archive: URL
    var state = State.waiting
    var password = ""
  }

  var jobs: [Job] = []
  private var worker: Task<Void, Never>?

  func add(_ urls: [URL]) {
    let busy = Set(jobs.filter { if case .done = $0.state { false } else { true } }.map(\.archive))
    jobs += urls.filter { !busy.contains($0) }.map { Job(archive: $0) }
    start()
  }

  func retry(_ id: Job.ID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    jobs[index].state = .waiting
    start()
  }

  func clearFinished() {
    jobs.removeAll {
      switch $0.state {
      case .done, .failed: true
      default: false
      }
    }
  }

  /// 一个接一个解（同时解好几个大包只会互相抢磁盘）
  private func start() {
    guard worker == nil else { return }
    worker = Task {
      while let job = jobs.first(where: { if case .waiting = $0.state { true } else { false } }) {
        update(job.id) { $0.state = .running }
        let state: Job.State
        do {
          state = .done(try await Archiver.unpack(job.archive, password: job.password))
        } catch Archiver.Failure.needsPassword {
          state = .needsPassword(again: false)
        } catch Archiver.Failure.wrongPassword {
          state = .needsPassword(again: true)
        } catch {
          state = .failed(error.localizedDescription)
        }
        update(job.id) { $0.state = state }
      }
      worker = nil
    }
  }

  private func update(_ id: Job.ID, _ change: (inout Job) -> Void) {
    if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
  }
}

struct UnpackView: View {
  @Bindable var model: UnpackModel
  @State private var choosing = false

  var body: some View {
    VStack(spacing: 0) {
      if model.jobs.isEmpty {
        DropHint(text: "把压缩包拖到这里，解到它旁边", symbol: "shippingbox") { choosing = true }
          .padding(20)
        Spacer()
      } else {
        List($model.jobs) { $job in
          JobRow(job: $job) { model.retry(job.id) }
        }
        Divider()
        HStack {
          // verbatim：不然 __MACOSX 的下划线会被当成 Markdown 的斜体
          Text(verbatim: "zip、7z、RAR、tar、iso 等都行；__MACOSX、._ 开头的杂文件不解出来。")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("清掉做完的") { model.clearFinished() }
          Button("添加…") { choosing = true }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
      }
    }
    .frame(minWidth: 600, minHeight: 360)
    .navigationTitle("解压")
    .dropDestination(for: URL.self) { urls, _ in
      model.add(urls)
      return true
    }
    .fileImporter(
      isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true
    ) {
      if case .success(let urls) = $0 { model.add(urls) }
    }
  }
}

private struct JobRow: View {
  @Binding var job: UnpackModel.Job
  let retry: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: job.archive.path))
        .resizable().frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(job.archive.lastPathComponent).lineLimit(1).truncationMode(.middle)
        status
      }
      Spacer()
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder private var status: some View {
    switch job.state {
    case .waiting:
      Text("等着").font(.caption).foregroundStyle(.secondary)
    case .running:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("正在解压…").font(.caption).foregroundStyle(.secondary)
      }
    case .done(let url):
      HStack(spacing: 8) {
        Label("解到「\(url.lastPathComponent)」", systemImage: "checkmark.circle.fill")
          .font(.caption).foregroundStyle(.green)
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          .buttonStyle(.link).font(.caption)
      }
    case .needsPassword(let again):
      HStack(spacing: 8) {
        Text(again ? "密码不对，再试一次：" : "这个包有密码：").font(.caption)
          .foregroundStyle(again ? .red : .secondary)
        SecureField("密码", text: $job.password).textFieldStyle(.roundedBorder)
          .frame(width: 180).onSubmit(retry)
        Button("解压", action: retry).disabled(job.password.isEmpty)
      }
      .controlSize(.small)
    case .failed(let reason):
      Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption)
        .foregroundStyle(.red).lineLimit(2)
    }
  }
}
