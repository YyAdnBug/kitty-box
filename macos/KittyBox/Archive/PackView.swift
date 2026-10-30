// 打包页（B2–B6、B10、B11）：拖进要打包的东西 → 选 zip / 7z、设不设密码 → 看忽略清单（勾、加、删，改了就记住）→
// 底部写「打包 N 个，忽略 M 项」，点开看忽略了哪些、哪些文件名 Windows 不认 → 打包，包放在原文件旁边。

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

  func remove(_ url: URL) {
    items.removeAll { $0 == url }
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
  @State private var choosing = false
  @State private var newRule = ""
  @State private var ruleProblem: String?
  @State private var showsIgnored = false

  private var options: Archiver.PackOptions {
    .init(format: format, password: model.password, windowsCompatible: windowsCompatible)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          itemsSection
          optionsSection
          ignoreSection
        }
        .padding(20)
      }
      Divider()
      footer.padding(.horizontal, 20).padding(.vertical, 12)
    }
    .frame(minWidth: 600, minHeight: 540)
    .navigationTitle("打包")
    .dropDestination(for: URL.self) { urls, _ in
      model.add(urls)
      return true
    }
    .fileImporter(
      isPresented: $choosing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true
    ) {
      if case .success(let urls) = $0 { model.add(urls) }
    }
    .task(id: model.planKey) {
      model.plan = nil
      guard !model.items.isEmpty else { return }
      let plan = await Archiver.plan(model.items, rules: model.ignore.rules)
      if !Task.isCancelled { model.plan = plan }
    }
  }

  // MARK: 要打包的东西

  @ViewBuilder private var itemsSection: some View {
    if model.items.isEmpty {
      DropHint(text: "把要打包的文件或文件夹拖到这里", symbol: "archivebox") { choosing = true }
    } else {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(model.items, id: \.self) { url in
          HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
              .resizable().frame(width: 20, height: 20)
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("移除", systemImage: "xmark.circle.fill") { model.remove(url) }
              .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
          }
        }
        Button("添加…") { choosing = true }.controlSize(.small)
      }
    }
  }

  // MARK: 格式和密码

  private var optionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 16) {
        Picker("格式", selection: $format) {
          Text("zip").tag(Archiver.Format.zip)
          Text("7z").tag(Archiver.Format.sevenZip)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        SecureField("密码", text: $model.password, prompt: Text("不设密码"))
          .frame(width: 200)
      }
      if format == .zip, !model.password.isEmpty {
        Toggle("让 Windows 自带解压也能打开", isOn: $windowsCompatible)
      }
      if let problem = Archiver.passwordProblem(options) {
        Text(problem).font(.caption).foregroundStyle(.red)
      } else {
        Text(passwordHint).font(.caption).foregroundStyle(.secondary)
      }
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

  // MARK: 忽略清单

  private var ignoreSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("忽略这些").font(.headline)
        Text("改了就记住，下次打包照样").font(.caption).foregroundStyle(.secondary)
      }
      group("系统杂文件", IgnoreList.system.map(\.pattern))
      group("开发目录", IgnoreList.developer.map(\.pattern)) {
        let allOn = IgnoreList.developer.allSatisfy { model.ignore.isOn($0.pattern) }
        Button(allOn ? "全不勾" : "全部勾上") {
          for item in IgnoreList.developer { model.ignore.set(item.pattern, on: !allOn) }
        }
        .buttonStyle(.link).font(.caption)
      }
      group("我加的", model.ignore.custom, removable: true)
      HStack {
        TextField("加一条", text: $newRule, prompt: Text("加一条：*.log、草稿、build/"))
          .onSubmit(addRule)
          .frame(maxWidth: 260)
        Button("添加", action: addRule).disabled(newRule.isEmpty)
      }
      Text(ruleProblem ?? "按名字匹配，路径里哪一层都算；* 和 ? 可用；以 / 结尾的只认文件夹。")
        .font(.caption).foregroundStyle(ruleProblem == nil ? Color.secondary : .red)
    }
  }

  private func group(
    _ title: String, _ patterns: [String], removable: Bool = false,
    @ViewBuilder trailing: () -> some View = { EmptyView() }
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(title).font(.subheadline).foregroundStyle(.secondary)
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

  // MARK: 底部

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        summary
        Spacer()
        if model.running { ProgressView().controlSize(.small) }
        Button("打包") { Task { await model.pack(options) } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(
            model.plan?.files.isEmpty != false || model.running
              || Archiver.passwordProblem(options) != nil)
      }
      if showsIgnored, let ignored = model.plan?.ignored, !ignored.isEmpty {
        PathList(rows: ignored.map { ($0.path, "← " + IgnoreList.display($0.rule)) })
      }
      if let problems = model.plan?.windowsProblems, !problems.isEmpty {
        Text("\(problems.count) 个文件名 Windows 不认，对方解压时会出错或少文件。照样能打包，要不要改名你决定：")
          .font(.caption).foregroundStyle(.orange)
        PathList(rows: problems.map { ($0.path, $0.reason) })
      }
      resultLine
    }
  }

  @ViewBuilder private var summary: some View {
    if model.items.isEmpty {
      Text("还没选要打包的东西").foregroundStyle(.secondary)
    } else if let plan = model.plan {
      HStack(spacing: 8) {
        Text("打包 \(plan.files.count.formatted()) 个，忽略 \(plan.ignored.count.formatted()) 项")
          .monospacedDigit()
        if !plan.ignored.isEmpty {
          Button(showsIgnored ? "收起" : "看看忽略了哪些") { showsIgnored.toggle() }
            .buttonStyle(.link)
        }
      }
    } else {
      Text("正在列文件…").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var resultLine: some View {
    switch model.result {
    case .success(let url):
      HStack {
        Label("已生成「\(url.lastPathComponent)」", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          .buttonStyle(.link)
      }
    case .failure(let error):
      Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    case nil:
      EmptyView()
    }
  }
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

/// 空着时的拖放提示：虚线框 + 一句话 + 「选择…」（解压页也用）
struct DropHint: View {
  let text: String
  let symbol: String
  let choose: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
      Text(text).foregroundStyle(.secondary)
      Button("选择…", action: choose)
    }
    .frame(maxWidth: .infinity, minHeight: 140)
    .background {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .strokeBorder(Style.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
    }
  }
}

/// 路径 + 右边一小段说明的清单：几行就多高，最多露出六行，多了自己滚
private struct PathList: View {
  let rows: [(path: String, note: String)]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(rows, id: \.path) { row in
          HStack {
            Text(row.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(row.note).foregroundStyle(.secondary)
          }
          .font(.caption)
        }
      }
      .padding(8)
    }
    .frame(height: min(CGFloat(rows.count) * 18 + 16, 124))
    .background(
      Style.hoverFill, in: RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous))
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
