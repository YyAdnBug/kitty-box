// 解压页（B7–B9）：拖进压缩包就一个接一个解，解到包旁边。有密码的停下来弹框问（不记），密码不对说一声再问；
// 点了「跳过」那一行留着「输入密码…」。拖到程序坞图标上、⌘V 粘贴的压缩包也进这里（Navigator），直接开始。
// 表格：压缩包、大小、状态；右键在访达中显示 / 重试 / 移除，⌫ 移除。空着时整页是拖放区。

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

    /// 解完了或没解成（不会再自己动）
    var isFinished: Bool {
      switch state {
      case .done, .failed: true
      default: false
      }
    }

    var result: URL? { if case .done(let url) = state { url } else { nil } }
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
    jobs.removeAll(where: \.isFinished)
  }

  /// 移除选中的（正在解的不移）
  func remove(_ ids: Set<Job.ID>) {
    jobs.removeAll { job in
      guard ids.contains(job.id) else { return false }
      if case .running = job.state { return false }
      return true
    }
  }

  /// 第一个等着输密码的（弹框问它）
  var askingID: Job.ID? {
    jobs.first { if case .needsPassword = $0.state { true } else { false } }?.id
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
  @State private var selection = Set<UnpackModel.Job.ID>()
  /// 正在弹框问密码的那一个
  @State private var asking: UnpackModel.Job.ID?

  var body: some View {
    ToolPage(tool: .unpack) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加压缩包（⌘O）")
      Button("清掉做完的", systemImage: "checklist.checked") { model.clearFinished() }
        .help("清掉解完的和没解成的")
        .disabled(!model.jobs.contains(where: \.isFinished))
    } content: {
      if model.jobs.isEmpty {
        DropZone(
          tool: .unpack, title: "拖入压缩包",
          detail: "放进来就开始解，一个接一个；有密码的会停下来问")
      } else {
        table
      }
    } status: {
      Text(summary)
      Spacer(minLength: 8)
      // verbatim：不然 __MACOSX 的下划线会被当成 Markdown 的斜体
      Text(verbatim: "__MACOSX、._ 开头的杂文件不解出来")
    }
    .onAppear { asking = model.askingID }
    .onChange(of: model.askingID) { asking = $1 }
    .alert(
      "「\(job(asking)?.archive.lastPathComponent ?? "")」有密码", isPresented: askingBinding
    ) {
      SecureField("密码", text: passwordBinding)
      Button("解压") { if let asking { model.retry(asking) } }
      Button("跳过", role: .cancel) {}
    } message: {
      if case .needsPassword(again: true) = job(asking)?.state {
        Text("密码不对，再试一次。")
      } else {
        Text("输入密码接着解；密码不会被记下来。")
      }
    }
  }

  private var table: some View {
    Table(model.jobs, selection: $selection) {
      TableColumn("压缩包") { job in
        HStack(spacing: 8) {
          FileThumb(url: job.archive, size: 18)
          Text(job.archive.lastPathComponent).lineLimit(1).truncationMode(.middle)
        }
      }
      .width(min: 160, ideal: 240)
      TableColumn("大小") { FileSizeText(url: $0.archive).foregroundStyle(.secondary) }
        .width(min: 60, ideal: 80)
      TableColumn("状态") { job in
        JobStatus(job: job) { asking = job.id }
      }
      .width(min: 240, ideal: 420)
    }
    .contextMenu(forSelectionType: UnpackModel.Job.ID.self) { ids in
      Button("在访达中显示") {
        let urls = ids.compactMap { id in job(id).map { $0.result ?? $0.archive } }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
      }
      if ids.contains(where: { job($0)?.isFinished == true && job($0)?.result == nil }) {
        Button("重试") { for id in ids { model.retry(id) } }
      }
      Divider()
      Button("移除") { model.remove(ids) }
    } primaryAction: { ids in
      for id in ids { if let url = job(id)?.result { NSWorkspace.shared.open(url) } }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: false))
    .scrollContentBackground(.hidden)
    .onDeleteCommand { model.remove(selection) }
  }

  private var summary: String {
    if model.jobs.isEmpty { return "还没有压缩包" }
    let done = model.jobs.count { $0.result != nil }
    let locked = model.jobs.count { if case .needsPassword = $0.state { true } else { false } }
    return "\(model.jobs.count) 个压缩包 · 已解压 \(done)" + (locked > 0 ? " · \(locked) 个要密码" : "")
  }

  private func job(_ id: UnpackModel.Job.ID?) -> UnpackModel.Job? {
    model.jobs.first { $0.id == id }
  }

  private var askingBinding: Binding<Bool> {
    Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
  }

  private var passwordBinding: Binding<String> {
    Binding(
      get: { job(asking)?.password ?? "" },
      set: { text in
        if let index = model.jobs.firstIndex(where: { $0.id == asking }) {
          model.jobs[index].password = text
        }
      })
  }
}

/// 表格「状态」那一格
private struct JobStatus: View {
  let job: UnpackModel.Job
  let askPassword: () -> Void

  var body: some View {
    switch job.state {
    case .waiting:
      Label("等待中", systemImage: "clock").foregroundStyle(.secondary)
    case .running:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("正在解压…").foregroundStyle(.secondary)
      }
    case .done(let url):
      DoneLine(text: "解到「\(url.lastPathComponent)」", url: url)
    case .needsPassword(let again):
      HStack(spacing: 8) {
        Label(again ? "密码不对" : "要密码", systemImage: "lock.fill")
          .foregroundStyle(again ? .red : .secondary)
        Button("输入密码…", action: askPassword).buttonStyle(.link)
      }
    case .failed(let reason):
      FailLine(reason: reason)
    }
  }
}
