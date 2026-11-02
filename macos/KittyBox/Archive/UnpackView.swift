// 解压页（B7–B9）：拖进压缩包就一个接一个解，解到包旁边。有密码的停下来弹框问（不记），密码不对说一声再问；
// 点了「跳过」那一行留着「输入密码…」。拖到程序坞图标上、⌘V 粘贴的压缩包也进这里（Navigator），直接开始。
// 表格：压缩包、大小、状态；右键看看里面 / 在访达中显示 / 重试 / 解到… / 移除，双击还没解好的也是看看里面，⌫ 移除，空格快速查看。
// 跳过了密码框的那一个不再自己弹出来，后面要密码的照样问；没解成的再拖进来就是重试；分卷包一整套拖进来只解第一卷。
// 从 App 自己的网址（访达扩展「用 Kitty Box 解压」，别的网页、App 也能打开）来的不自己开始：那一行写「还没开始」，点「开始解压」才解。
// 空着时整页是拖放区。

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class UnpackModel {
  struct Job: Identifiable {
    enum State {
      /// 从网址来的：等用户点「开始解压」
      case held
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
    /// 「解到…」选的文件夹；nil 是压缩包旁边
    var destination: URL?
    /// 正在解时的进度 0–1；还不知道（tar.gz 这类没有总数）时是 nil
    var progress: Double?
    /// 解好了、但没能挪到废纸篓时的原因（网络盘这类没有废纸篓的地方）
    var note: String?

    /// 解完了或没解成（不会再自己动）
    var isFinished: Bool {
      switch state {
      case .done, .failed: true
      default: false
      }
    }

    /// 没解成、在等密码或还没开始：能重试（开始）、能「解到…」
    var canRetry: Bool {
      switch state {
      case .held, .failed, .needsPassword: true
      default: false
      }
    }

    var result: URL? { if case .done(let url) = state { url } else { nil } }
  }

  var jobs: [Job] = []
  /// 点了「跳过」的（不再自己弹框问，后面要密码的照样问）
  private(set) var skipped: Set<Job.ID> = []
  private var worker: Task<Void, Never>?
  /// 正在解的那一个和它的任务（「停止」取消它，接着解下一个）
  private var current: (id: Job.ID, task: Task<URL, any Error>)?
  private let defaults: UserDefaults

  /// defaults：单测传临时偏好域（「解完移到废纸篓」不看用户的）
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 分卷包的后几卷换成第一卷（一整套只解一次）；还在排队、正在解的不再加；没解成的再拖进来就是重试；解好的再解一份。
  /// autostart = false（App 自己的网址交过来的）：只放进表格、写「还没开始」，不自己解，已有的那一行也不动
  func add(_ urls: [URL], autostart: Bool = true) {
    for url in urls.map(Archiver.firstVolume) {
      if let job = jobs.last(where: { $0.archive.path == url.path }), job.result == nil {
        if autostart { retry(job.id) }
      } else {
        jobs.append(Job(archive: url, state: autostart ? .waiting : .held))
      }
    }
    if autostart { start() }
  }

  /// 没解成、在等密码的再解一次（解好的、正在解的、排着队的不动）；folder 是「解到…」选的文件夹
  func retry(_ id: Job.ID, into folder: URL? = nil) {
    guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].canRetry else { return }
    if let folder { jobs[index].destination = folder }
    jobs[index].state = .waiting
    skipped.remove(id)
    start()
  }

  /// 密码框点了「跳过」：这一行留着「输入密码…」，接着问下一个要密码的
  func skip(_ id: Job.ID) {
    skipped.insert(id)
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

  /// 第一个等着输密码、没被跳过的（弹框问它）
  var askingID: Job.ID? {
    jobs.first {
      if case .needsPassword = $0.state { !skipped.contains($0.id) } else { false }
    }?.id
  }

  /// 停下正在解的这一个：子进程停掉、解了一半的文件夹删掉，这一行写「已停止」，能重试
  func stop(_ id: Job.ID) {
    if current?.id == id { current?.task.cancel() }
  }

  /// 在一个接一个地解（退出 App 前要问）
  var running: Bool { worker != nil }

  /// 退出 App 前：正在解的停下、排着队的不再开始，等子进程停掉、解了一半的「.名字 解压中」删掉再回来
  func stopAll() async {
    worker?.cancel()
    // 正在解的那个是另开的任务，不随 worker 一起取消
    current?.task.cancel()
    await worker?.value
  }

  /// 一个接一个解（同时解好几个大包只会互相抢磁盘）
  private func start() {
    // 没有要解的（拖到「解压」那一行的全不是压缩包）：不开工，不然旁白白念一句「解压做完了」
    guard worker == nil,
      jobs.contains(where: { if case .waiting = $0.state { true } else { false } })
    else { return }
    worker = Task {
      while !Task.isCancelled,
        let job = jobs.first(where: { if case .waiting = $0.state { true } else { false } })
      {
        update(job.id) {
          $0.state = .running
          $0.progress = nil
        }
        let task = Task {
          try await Archiver.unpack(job.archive, into: job.destination, password: job.password) {
            fraction in self.update(job.id) { $0.progress = fraction }
          }
        }
        current = (job.id, task)
        let state: Job.State
        do {
          state = .done(try await ProcessInfo.processInfo.working("正在解压") { try await task.value })
        } catch is CancellationError {
          state = .failed("已停止")
        } catch Archiver.Failure.needsPassword {
          state = .needsPassword(again: false)
        } catch Archiver.Failure.wrongPassword {
          state = .needsPassword(again: true)
        } catch {
          state = .failed(error.localizedDescription)
        }
        current = nil
        update(job.id) { $0.state = state }
        // 解完把压缩包移到废纸篓（偏好里开着时；能从废纸篓放回去，分卷包不挪）
        if case .done = state, defaults.bool(forKey: Prefs.unpackTrashArchive),
          !Archiver.isMultiVolume(job.archive)
        {
          do {
            try FileManager.default.trashItem(at: job.archive, resultingItemURL: nil)
          } catch {
            update(job.id) { $0.note = "压缩包没能移到废纸篓（这个位置可能没有废纸篓）" }
          }
        }
      }
      worker = nil
      let failed = jobs.count { if case .failed = $0.state { true } else { false } }
      let locked = jobs.count { if case .needsPassword = $0.state { true } else { false } }
      NSApp.finished(
        "解压做完了" + (failed > 0 ? "，\(failed) 个没解成" : "") + (locked > 0 ? "，\(locked) 个要密码" : ""))
    }
  }

  private func update(_ id: Job.ID, _ change: (inout Job) -> Void) {
    if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
  }
}

struct UnpackView: View {
  @Bindable var model: UnpackModel
  @AppStorage(Prefs.unpackTrashArchive) private var trashArchive = false
  @State private var selection = Set<UnpackModel.Job.ID>()
  /// 正在弹框问密码的那一个
  @State private var asking: UnpackModel.Job.ID?
  /// 正在「看看里面」的那一个
  @State private var peeking: UnpackModel.Job?

  var body: some View {
    ToolPage(tool: .unpack) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加压缩包（⌘O）")
      Toggle("解完移到废纸篓", isOn: $trashArchive)
        .toggleStyle(.checkbox)
        .help("解好之后把压缩包挪到废纸篓（能放回去；分卷包不挪）")
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
      "「\(job(asking)?.archive.lastPathComponent ?? "")」有密码", isPresented: askingBinding,
      presenting: asking
    ) { id in
      SecureField("密码", text: passwordBinding)
      Button("解压") { model.retry(id) }
      Button("跳过", role: .cancel) { model.skip(id) }
    } message: { id in
      if case .needsPassword(again: true) = job(id)?.state {
        Text("密码不对，再试一次。")
      } else {
        Text("输入密码接着解；密码不会被记下来。")
      }
    }
  }

  private var table: some View {
    Table(of: UnpackModel.Job.self, selection: $selection) {
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
        JobStatus(
          job: job, askPassword: { asking = job.id }, stop: { model.stop(job.id) },
          retry: { model.retry(job.id) })
      }
      .width(min: 240, ideal: 420)
    } rows: {
      // 解好的能直接拖到访达或别的 App（拖的是解出来的东西）
      ForEach(model.jobs) { job in
        TableRow(job).itemProvider { job.result.flatMap(NSItemProvider.init(contentsOf:)) }
      }
    }
    .contextMenu(forSelectionType: UnpackModel.Job.ID.self) { ids in
      if ids.count == 1, let id = ids.first {
        Button("看看里面") { peeking = job(id) }
      }
      Button("在访达中显示") {
        let urls = ids.compactMap { id in job(id).map { $0.result ?? $0.archive } }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
      }
      if ids.contains(where: { if case .running = job($0)?.state { true } else { false } }) {
        Button("停止") { for id in ids { model.stop(id) } }
      }
      if ids.contains(where: { if case .held = job($0)?.state { true } else { false } }) {
        Button("开始解压") { for id in ids { model.retry(id) } }
      }
      if ids.contains(where: { job($0)?.isFinished == true && job($0)?.result == nil }) {
        Button("重试") { for id in ids { model.retry(id) } }
      }
      // 包旁边写不进去（挂载的磁盘映像、只读的共享）时的出路
      if ids.contains(where: { job($0)?.canRetry == true }) {
        Button("解到…") { unpack(ids) }
      }
      Divider()
      Button("移除") { model.remove(ids) }
    } primaryAction: { ids in
      // 双击：解好的打开，还没解好的看看里面
      for id in ids {
        if let url = job(id)?.result { NSWorkspace.shared.open(url) } else { peeking = job(id) }
      }
    }
    .sheet(item: $peeking) { ArchiveContents(job: $0) }
    .tableStyle(.inset(alternatesRowBackgrounds: false))
    .scrollContentBackground(.hidden)
    .onDeleteCommand { model.remove(selection) }
    .spacePreview {
      model.jobs.filter { selection.contains($0.id) }.map { $0.result ?? $0.archive }
    }
  }

  private var summary: String {
    if model.jobs.isEmpty { return "还没有压缩包" }
    let done = model.jobs.count { $0.result != nil }
    let locked = model.jobs.count { if case .needsPassword = $0.state { true } else { false } }
    let held = model.jobs.count { if case .held = $0.state { true } else { false } }
    return "\(model.jobs.count) 个压缩包 · 已解压 \(done)" + (locked > 0 ? " · \(locked) 个要密码" : "")
      + (held > 0 ? " · \(held) 个还没开始" : "")
  }

  private func job(_ id: UnpackModel.Job.ID?) -> UnpackModel.Job? {
    model.jobs.first { $0.id == id }
  }

  /// 「解到…」：选一个文件夹，没解成的、等密码的解到那里
  private func unpack(_ ids: Set<UnpackModel.Job.ID>) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "解到这里"
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    for id in ids { model.retry(id, into: folder) }
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
  let stop: () -> Void
  let retry: () -> Void

  var body: some View {
    switch job.state {
    case .held:
      // 从网址来的不自己解（别的网页、App 也能打开那个网址）：点一下才开始
      HStack(spacing: 8) {
        Label("还没开始", systemImage: "pause.circle").foregroundStyle(.secondary)
        Button("开始解压", action: retry).textLink().fixedSize()
      }
    case .waiting:
      Label("等待中", systemImage: "clock").foregroundStyle(.secondary)
    case .running:
      RunningProgress(label: "正在解压", value: job.progress, stop: stop)
        .foregroundStyle(.secondary)
    case .done(let url):
      DoneLine(text: "解到「\(url.lastPathComponent)」" + (job.note.map { "，" + $0 } ?? ""), url: url)
    case .needsPassword(let again):
      HStack(spacing: 8) {
        // 只染图标：红字在浅底上对比度不够
        Label {
          Text(again ? "密码不对" : "要密码").foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "lock.fill").foregroundStyle(again ? .red : .secondary)
        }
        Button("输入密码…", action: askPassword).textLink()
      }
    case .failed(let reason):
      // 重试放在行里（同「输入密码…」），只用键盘也够得着
      HStack(spacing: 8) {
        FailLine(reason: reason)
        Button("重试", action: retry).textLink().fixedSize()
      }
    }
  }
}

/// 「看看里面」（M6）：包里有哪些文件、各多大、一共多少；连文件名都加了密的包说一声要先输密码
private struct ArchiveContents: View {
  let job: UnpackModel.Job
  @Environment(\.dismiss) private var dismiss
  @State private var entries: [Archiver.Entry]?
  @State private var problem: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        FileThumb(url: job.archive, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(job.archive.lastPathComponent).font(.headline)
            .lineLimit(1).truncationMode(.middle)
          Text(summary).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)
      Hairline()
      Group {
        if let entries {
          List(entries) { entry in
            HStack(spacing: 8) {
              Image(systemName: "doc").foregroundStyle(.secondary)
              Text(entry.path).lineLimit(1).truncationMode(.middle)
              Spacer(minLength: 8)
              Text(entry.size.map { $0.formatted(.byteCount(style: .file)) } ?? "")
                .monospacedDigit().foregroundStyle(.secondary)
            }
          }
          .listStyle(.inset)
          .scrollContentBackground(.hidden)
        } else if let problem {
          Label(problem, systemImage: "lock.fill").foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      Hairline()
      HStack {
        Spacer()
        Button("好") { dismiss() }
          .buttonStyle(BrandButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }
    .frame(width: 560, height: 460)
    .onExitCommand { dismiss() }
    .task {
      do {
        entries = try await Archiver.contents(of: job.archive, password: job.password)
      } catch Archiver.Failure.needsPassword, Archiver.Failure.wrongPassword {
        problem = "这个包连文件名都加了密，输入密码之后才能看。"
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  private var summary: String {
    guard let entries else { return problem == nil ? "正在读…" : "" }
    let sizes = entries.compactMap(\.size)
    let total =
      sizes.count == entries.count && !entries.isEmpty
      ? " · 解开后共 " + sizes.reduce(0, +).formatted(.byteCount(style: .file)) : ""
    return entries.isEmpty ? "包里没有文件" : "\(entries.count.formatted()) 个文件" + total
  }
}
