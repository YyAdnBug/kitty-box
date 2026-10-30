// 打包页（B2–B6、B10、B11）：拖进（或 ⌘V 粘贴、⌘O 添加）要打包的东西 → 右边「选项」里选 zip / 7z、设不设密码、看忽略清单
// （勾、加、删，改了就记住）→ 工具栏「打包」，包放在原文件旁边。
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
  private(set) var result: Result<URL, any Error>?
  let ignore = IgnoreList()

  func add(_ urls: [URL]) {
    items += urls.filter { !items.contains($0) }
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

  func pack(_ options: Archiver.PackOptions) async {
    guard let plan, !running else { return }
    running = true
    defer { running = false }
    do {
      result = .success(try await Archiver.pack(plan, options: options))
    } catch {
      result = .failure(error)
    }
  }
}

struct PackView: View {
  @Bindable var model: PackModel
  @AppStorage(Prefs.packFormat) private var format = Archiver.Format.zip
  @AppStorage(Prefs.packWindowsCompatible) private var windowsCompatible = false
  @AppStorage(Prefs.showsOptions) private var showsOptions = true
  @State private var selection = Set<URL>()
  @State private var newRule = ""
  @State private var ruleProblem: String?
  @State private var showsIgnored = false
  @State private var showsProblems = false

  private var options: Archiver.PackOptions {
    .init(format: format, password: model.password, windowsCompatible: windowsCompatible)
  }

  var body: some View {
    VStack(spacing: 0) {
      if model.items.isEmpty {
        DropZone(tool: .pack, title: "拖入要打包的文件或文件夹", detail: "可以一次放好几个，打好的包放在它们旁边")
      } else {
        table
      }
      statusBar
    }
    .navigationTitle("打包")
    .toolbar { toolbar }
    .inspector(isPresented: $showsOptions) {
      optionsForm.inspectorColumnWidth(min: 280, ideal: 300, max: 380)
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
        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
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
    .onDeleteCommand { model.remove(selection) }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup {
      Button("添加文件", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加文件（⌘O）")
      Button("移除", systemImage: "minus") { model.remove(selection) }
        .help("移除选中的（⌫）")
        .disabled(selection.isEmpty || model.running)
    }
    ToolbarItem {
      Button("选项", systemImage: "sidebar.trailing") { showsOptions.toggle() }
        .help(showsOptions ? "收起选项" : "显示选项")
    }
    ToolbarItem(placement: .primaryAction) {
      Button("打包") { Task { await model.pack(options) } }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(
          model.plan?.files.isEmpty != false || model.running
            || Archiver.passwordProblem(options) != nil)
    }
  }

  // MARK: 状态栏

  private var statusBar: some View {
    StatusBar {
      switch model.result {
      case .success(let url): DoneLine(text: "已生成「\(url.lastPathComponent)」", url: url)
      case .failure(let error): FailLine(reason: error.localizedDescription)
      case nil: summary
      }
    } trailing: {
      if model.running {
        ProgressView().controlSize(.mini)
        Text("正在打包…")
      }
    }
  }

  @ViewBuilder private var summary: some View {
    if model.items.isEmpty {
      Text("还没选要打包的东西")
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

  private var optionsForm: some View {
    Form {
      Section("格式") {
        Picker("格式", selection: $format) {
          Text("zip").tag(Archiver.Format.zip)
          Text("7z").tag(Archiver.Format.sevenZip)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      Section {
        SecureField("密码", text: $model.password, prompt: Text("不设密码"))
          .labelsHidden()
        if format == .zip, !model.password.isEmpty {
          Toggle("让 Windows 自带解压也能打开", isOn: $windowsCompatible)
        }
      } header: {
        Text("密码")
      } footer: {
        if let problem = Archiver.passwordProblem(options) {
          Text(problem).font(.caption).foregroundStyle(.red)
        } else {
          Text(passwordHint).font(.caption).foregroundStyle(.secondary)
        }
      }
      Section {
        group("系统杂文件", IgnoreList.system.map(\.pattern))
        group("开发目录", IgnoreList.developer.map(\.pattern)) {
          let allOn = IgnoreList.developer.allSatisfy { model.ignore.isOn($0.pattern) }
          Button(allOn ? "全不勾" : "全部勾上") {
            for item in IgnoreList.developer { model.ignore.set(item.pattern, on: !allOn) }
          }
          .buttonStyle(.link)
        }
        group("我加的", model.ignore.custom, removable: true)
        HStack {
          TextField("加一条", text: $newRule, prompt: Text("*.log、草稿、build/"))
            .labelsHidden()
            .onSubmit(addRule)
          Button("添加", action: addRule).disabled(newRule.isEmpty)
        }
      } header: {
        Text("忽略这些")
      } footer: {
        Text(ruleProblem ?? "改了就记住。按名字匹配，路径里哪一层都算；* 和 ? 可用；以 / 结尾的只认文件夹。")
          .font(.caption).foregroundStyle(ruleProblem == nil ? Color.secondary : .red)
      }
    }
    .formStyle(.grouped)
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
        Text(title)
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
    .padding(.vertical, 2)
  }

  private func addRule() {
    ruleProblem = model.ignore.add(newRule)
    if ruleProblem == nil { newRule = "" }
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
        VStack(alignment: .leading, spacing: 4) {
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
