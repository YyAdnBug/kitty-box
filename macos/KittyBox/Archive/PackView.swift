// 打包页（B2–B6、B10、B11）：拖进（或 ⌘V 粘贴、⌘O 添加）要打包的东西（可以来自不同的文件夹）→ 右边选项栏里选 zip / 7z、
// 设不设密码、看忽略清单（勾、加、删，改了就记住）→ 页头「打包」，包放在第一样东西旁边；「打包到…」自己选位置和名字。
// 中间是表格（名称、种类、大小，右键在访达中显示 / 移除，⌫ 移除）；底下状态栏写「N 项 · 打包 N 个文件 · 忽略 M 项」，
// 点「查看」看忽略了哪些、哪些文件名 Windows 不认。空着时整页是拖放区。

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class PackModel {
  private(set) var items: [URL] = []
  /// 跟着选中的东西和忽略清单重算（PackView 的 .task(id: planKey)）
  var plan: Archiver.PackPlan?
  var password = ""
  private(set) var running = false
  /// 打包进度 0–1；还不知道时是 nil
  private(set) var progress: Double?
  private(set) var result: Result<URL, any Error>?
  private var task: Task<Void, Never>?
  let ignore = IgnoreList()

  /// 上一包打好了，再加进来的是新的一包（同访达「压缩」：一次一个包）；同一样东西（带不带结尾的 /）不加两次
  func add(_ urls: [URL]) {
    if case .success = result { items = [] }
    for url in urls where !items.contains(where: { $0.path == url.path }) { items.append(url) }
    result = nil
  }

  func remove(_ urls: Set<URL>) {
    items.removeAll(where: urls.contains)
    result = nil
  }

  /// 选中的东西或忽略清单一变就重列
  var planKey: [String] {
    items.map(\.path) + ["|"] + ignore.off.sorted() + ["|"] + ignore.developerOn.sorted() + ["|"]
      + ignore.custom
  }

  /// target：「打包到…」选的位置；nil 放在第一样东西旁边
  func pack(_ options: Archiver.PackOptions, to target: URL? = nil) {
    guard let plan, !running else { return }
    running = true
    progress = nil
    result = nil
    task = Task {
      do {
        result = .success(
          try await Archiver.pack(plan, options: options, to: target) { self.progress = $0 })
        NSApp.bounceIfInBackground()
      } catch is CancellationError {
        result = nil
      } catch {
        result = .failure(error)
      }
      running = false
      progress = nil
      task = nil
    }
  }

  /// 停下来：7zz 停掉、打了一半的包删掉
  func stop() { task?.cancel() }
}

struct PackView: View {
  @Bindable var model: PackModel
  @AppStorage(Prefs.packFormat) private var format = Archiver.Format.zip
  @AppStorage(Prefs.packWindowsCompatible) private var windowsCompatible = false
  @AppStorage(Prefs.packLevel) private var level = Archiver.Level.normal
  @State private var selection = Set<URL>()
  @State private var newRule = ""
  @State private var ruleProblem: String?
  @State private var showsIgnored = false
  @State private var showsProblems = false
  @State private var showsPassword = false
  /// 在「加一条」里打字：回车是加规则，不是打包
  @FocusState private var typingRule: Bool

  private var options: Archiver.PackOptions {
    .init(
      format: format, password: model.password, windowsCompatible: windowsCompatible, level: level)
  }

  private var canPack: Bool {
    guard let plan = model.plan else { return false }
    return !plan.files.isEmpty && plan.clashes.isEmpty && !model.running
      && Archiver.passwordProblem(options) == nil
  }

  var body: some View {
    ToolPage(tool: .pack) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加文件（⌘O）")
      Button("移除", systemImage: "minus") { model.remove(selection) }
        .help("移除选中的（⌫）")
        .disabled(selection.isEmpty || model.running)
      Button("打包到…", systemImage: "square.and.arrow.down") { packTo() }
        .help("自己选包放在哪、叫什么")
        .disabled(!canPack)
      Button("打包") { model.pack(options) }
        .buttonStyle(BrandButtonStyle())
        .keyboardShortcut(typingRule ? nil : .defaultAction)
        .disabled(!canPack)
    } content: {
      if model.items.isEmpty {
        DropZone(tool: .pack, title: "拖入要打包的文件或文件夹", detail: "可以一次放好几个，打好的包放在它们旁边")
      } else {
        table
      }
    } options: {
      optionGroups
    } status: {
      status
    }
    .task(id: model.planKey) {
      model.plan = nil
      guard !model.items.isEmpty else { return }
      let plan = await Archiver.plan(model.items, rules: model.ignore.rules)
      if !Task.isCancelled { model.plan = plan }
    }
  }

  // MARK: 表格

  private var table: some View {
    Table(of: FileRow.self, selection: $selection) {
      TableColumn("名称") { row in
        HStack(spacing: 8) {
          FileThumb(url: row.url, size: 18)
          Text(row.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
        }
      }
      .width(min: 160, ideal: 240)
      TableColumn("种类") { FileKindText(url: $0.url).foregroundStyle(.secondary) }
        .width(min: 80, ideal: 120)
      TableColumn("大小") { FileSizeText(url: $0.url).foregroundStyle(.secondary) }
        .width(min: 60, ideal: 80)
      TableColumn("位置") { row in
        Text(
          (row.url.deletingLastPathComponent().path(percentEncoded: false) as NSString)
            .abbreviatingWithTildeInPath
        )
        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
    } rows: {
      ForEach(model.items.map(FileRow.init)) { TableRow($0) }
    }
    .contextMenu(forSelectionType: URL.self) { urls in
      Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
      Divider()
      Button("移除") { model.remove(urls) }
    } primaryAction: { urls in
      for url in urls { NSWorkspace.shared.open(url) }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: false))
    .scrollContentBackground(.hidden)
    .onDeleteCommand { model.remove(selection) }
    .spacePreview { model.items.filter(selection.contains) }
  }

  // MARK: 状态栏

  @ViewBuilder private var status: some View {
    switch model.result {
    case .success(let url): DoneLine(text: "已生成「\(url.lastPathComponent)」", url: url)
    case .failure(let error): FailLine(reason: error.localizedDescription)
    case nil: summary
    }
    Spacer(minLength: 8)
    if model.running {
      RunningProgress(label: "正在打包", value: model.progress) { model.stop() }
    }
  }

  @ViewBuilder private var summary: some View {
    if model.items.isEmpty {
      Text("还没选要打包的东西")
    } else if let plan = model.plan, !plan.clashes.isEmpty {
      // 不同文件夹里的同名东西：包里只放得下一个，不让打（不同于下面 Windows 不认的名字，那个照样能打）
      Label(
        "「\(plan.clashes.formatted(.list(type: .and)))」有同名的（在不同的文件夹里），包里只放得下一个，先移除一个",
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.red)
    } else if let plan = model.plan {
      HStack(spacing: 6) {
        Text(
          "\(model.items.count) 项 · 打包 \(plan.files.count.formatted()) 个文件 · 忽略 \(plan.ignored.count.formatted()) 项"
        )
        .monospacedDigit()
        if !plan.ignored.isEmpty {
          Button("查看") { showsIgnored = true }
            .buttonStyle(.link)
            .popover(isPresented: $showsIgnored, arrowEdge: .top) {
              PathList(
                title: "忽略了这些",
                rows: plan.ignored.map { ($0.path, "← " + IgnoreList.display($0.rule)) })
            }
        }
        if !plan.windowsProblems.isEmpty {
          Text("·")
          Label(
            "\(plan.windowsProblems.count) 个文件名 Windows 不认",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
          Button("查看") { showsProblems = true }
            .buttonStyle(.link)
            .popover(isPresented: $showsProblems, arrowEdge: .top) {
              PathList(
                title: "对方解压时会出错或少文件。照样能打包，要不要改名你决定。",
                rows: plan.windowsProblems.map { ($0.path, $0.reason) })
            }
        }
      }
    } else {
      Text("正在列文件…")
    }
  }

  // MARK: 选项（右边）

  @ViewBuilder private var optionGroups: some View {
    OptionGroup(title: "格式") {
      Picker("格式", selection: $format) {
        Text("zip").tag(Archiver.Format.zip)
        Text("7z").tag(Archiver.Format.sevenZip)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
    OptionGroup(title: "压缩", footnote: Text(levelHint)) {
      Picker("压缩", selection: $level) {
        ForEach(Archiver.Level.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
    OptionGroup(
      title: "密码",
      footnote: Archiver.passwordProblem(options).map { Text($0).foregroundStyle(.red) }
        ?? Text(passwordHint)
    ) {
      // 只输一遍、又看不见的话，打错一个字包就没人打得开了：能点开看一眼
      HStack(spacing: 6) {
        Group {
          if showsPassword {
            TextField("密码", text: $model.password, prompt: Text("不设密码"))
          } else {
            SecureField("密码", text: $model.password, prompt: Text("不设密码"))
          }
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        Button(
          showsPassword ? "隐藏密码" : "显示密码", systemImage: showsPassword ? "eye.slash" : "eye"
        ) { showsPassword.toggle() }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(showsPassword ? "隐藏密码" : "显示密码")
      }
      if format == .zip, !model.password.isEmpty {
        Toggle("让 Windows 自带解压也能打开", isOn: $windowsCompatible)
      }
    }
    OptionGroup(
      title: "忽略这些",
      footnote: ruleProblem.map { Text($0).foregroundStyle(.red) }
        ?? Text("改了就记住。按名字匹配，路径里哪一层都算；* 和 ? 可用；以 / 结尾的只认文件夹。")
    ) {
      group("系统杂文件", IgnoreList.system.map(\.pattern))
      Hairline()
      group("开发目录", IgnoreList.developer.map(\.pattern)) {
        let allOn = IgnoreList.developer.allSatisfy { model.ignore.isOn($0.pattern) }
        Button(allOn ? "全不勾" : "全部勾上") {
          for item in IgnoreList.developer { model.ignore.set(item.pattern, on: !allOn) }
        }
        .buttonStyle(.link)
      }
      Hairline()
      group("我加的", model.ignore.custom, removable: true)
      HStack {
        TextField("加一条", text: $newRule, prompt: Text("*.log、草稿、build/"))
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
          .focused($typingRule)
          .onSubmit(addRule)
        Button("添加", action: addRule).disabled(newRule.isEmpty)
      }
    }
  }

  private var levelHint: String {
    switch level {
    case .store: "不压缩，只是装在一起：最快，照片、视频这类本来就压过的用它正好。"
    case .fast: "压得少一点、快很多。"
    case .normal: "又快又小，一般用它。"
    case .smallest: "压到最小，大文件夹会慢不少。"
    }
  }

  private var passwordHint: String {
    switch (format, windowsCompatible) {
    case (.sevenZip, _):
      "设了密码连文件名也一起加密。Windows 自带解压打不开带密码的 7z，对方要装 7-Zip 等。"
    case (.zip, true):
      "设了密码用 ZipCrypto：Windows 自带解压能开，但这种加密容易被破解，重要的东西用 7z。"
    case (.zip, false):
      "设了密码用 AES-256：Windows 自带解压打不开，对方要装 7-Zip、WinRAR 或 Bandizip。"
    }
  }

  private func group(
    _ title: String, _ patterns: [String], removable: Bool = false,
    @ViewBuilder trailing: () -> some View = { EmptyView() }
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 12, weight: .medium))
        Spacer()
        trailing()
      }
      if patterns.isEmpty {
        Text("还没有").font(.caption).foregroundStyle(.tertiary)
      }
      FlowLayout(spacing: 6) {
        ForEach(patterns, id: \.self) { pattern in
          HStack(spacing: 2) {
            Toggle(
              IgnoreList.display(pattern),
              isOn: Binding(
                get: { model.ignore.isOn(pattern) }, set: { model.ignore.set(pattern, on: $0) })
            )
            .toggleStyle(ChipToggleStyle())
            .help(IgnoreList.note(for: pattern) ?? "自己加的")
            if removable {
              Button("删掉「\(pattern)」", systemImage: "xmark") { model.ignore.remove(pattern) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).font(.caption)
            }
          }
        }
      }
      .controlSize(.small)
    }
  }

  private func addRule() {
    ruleProblem = model.ignore.add(newRule)
    if ruleProblem == nil { newRule = "" }
  }

  /// 「打包到…」：默认名字和位置同「打包」，换了的话放在选的地方；选了替换已有的包时旧的挪到废纸篓（能放回去）
  private func packTo() {
    guard let plan = model.plan else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = Archiver.archiveName(for: plan.items, format: format)
    panel.directoryURL = plan.base
    panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .data]
    panel.canCreateDirectories = true
    panel.prompt = "打包"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.pack(options, to: url)
  }
}

/// 表格的一行（URL 本身不是 Identifiable）
private struct FileRow: Identifiable {
  let url: URL
  var id: URL { url }
}

extension IgnoreList {
  /// 「Icon\r」的 \r 看不见，显示成 ␍
  static func display(_ pattern: String) -> String {
    pattern.replacingOccurrences(of: "\r", with: "␍")
  }

  static func note(for pattern: String) -> String? {
    (system + developer).first { $0.pattern == pattern }?.note
  }
}

/// 路径 + 右边一小段说明的清单（状态栏「查看」弹出来的）：上面一句说明，几行就多高，最多露出十二行，多了自己滚
private struct PathList: View {
  let title: String
  let rows: [(path: String, note: String)]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      ScrollView {
        // 几千个 .DS_Store 时一下子全建出来会卡一下：按需建
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(rows, id: \.path) { row in
            HStack {
              Text(row.path).lineLimit(1).truncationMode(.middle)
              Spacer()
              Text(row.note).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
          }
        }
      }
      .frame(height: min(CGFloat(rows.count) * 20, 240))
    }
    .padding(14)
    .frame(width: 440)
  }
}

/// 忽略清单的一项：胶囊里一个勾选框 + 规则。勾上时是强调色的淡底和描边，没勾是发丝线（系统的按钮式开关在 26 上开关两态看不出差别）
private struct ChipToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    let shape = Capsule()
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
          .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
        configuration.label
          .foregroundStyle(configuration.isOn ? .primary : .secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(configuration.isOn ? Color.accentColor.opacity(0.12) : .clear, in: shape)
      .overlay {
        if configuration.isOn {
          shape.strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
        } else {
          shape.hairlineBorder()
        }
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .accessibilityValue(configuration.isOn ? "勾上" : "没勾")
  }
}

/// 一行排满了换行的排法（忽略清单的一排排开关）
private struct FlowLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    return CGSize(
      width: rows.map(\.width).max() ?? 0,
      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows = [Row()]
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if !rows[rows.count - 1].indices.isEmpty,
        rows[rows.count - 1].width + spacing + size.width > width
      {
        rows.append(Row())
      }
      var row = rows[rows.count - 1]
      row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
      row.height = max(row.height, size.height)
      row.indices.append(index)
      rows[rows.count - 1] = row
    }
    return rows
  }
}
