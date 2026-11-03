// 设置窗口（M7，App 菜单「设置…」⌘,；用户问「没看到设置的入口」）：两页，分组表单，同 Kitty Tools 设置页的样子。
// - 通用：外观（跟随系统 / 浅色 / 深色）、自动检查更新、做完时程序坞图标跳一下、访达右键菜单（M9 的访达扩展：开没开、去哪打开、
//   新建文件模板文件夹；还有「服务」菜单怎么关）、右键「用 X 打开」的 App、结果放哪。
// - 模型：画笔擦除和 AI 水印用哪个补图模型（快速 / 标准 / 高清，AIModel），去背景「精细」用的抠图模型；各自下载、删除，下好的占多少地方。
// 打包的忽略清单、各页的格式和质量就在各自页面的右边，不在这里重复一份。

import AppKit
import FinderSync
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
      ModelSettings().tabItem { Label("模型", systemImage: "brain") }
    }
    .frame(width: 560)
  }
}

/// 外观：跟随系统 / 浅色 / 深色（设成整个 App 的 NSApp.appearance：SwiftUI 的 preferredColorScheme 设回「跟随」时不会变回来）
enum Appearance: String, CaseIterable {
  case system, light, dark

  var title: String {
    switch self {
    case .system: "跟随系统"
    case .light: "浅色"
    case .dark: "深色"
    }
  }

  func apply() {
    NSApp.appearance =
      switch self {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
  }
}

private struct GeneralSettings: View {
  @AppStorage(Prefs.appearance) private var appearance = Appearance.system
  @AppStorage(Prefs.autoCheckUpdates) private var autoCheckUpdates = true
  @AppStorage(Prefs.bounceWhenDone) private var bounceWhenDone = true
  /// 访达扩展开了没有（系统设置里改了，切回来时再看一次）
  @State private var finderOn = FIFinderSyncController.isExtensionEnabled
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Form {
      // 组名不再写一遍「外观」：那一行自己就叫外观
      Section {
        Picker("外观", selection: $appearance) {
          ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
      }
      Section {
        Toggle("自动检查更新", isOn: $autoCheckUpdates)
        LabeledContent("现在就查一次") {
          Button("检查更新…") {
            openWindow(id: KittyBoxApp.aboutID)
            Task { await Updater.shared.check() }
          }
        }
      } header: {
        Text("更新")
      } footer: {
        Text("打开 App 10 秒后在 GitHub 上查一次；有新版本时侧边栏底下有一张小卡。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("提醒") {
        Toggle(isOn: $bounceWhenDone) {
          Text("做完时程序坞图标跳一下")
          Text("只在 Kitty Box 在后台时跳，跳一次。")
        }
      }
      Section {
        LabeledContent {
          Button(finderOn ? "管理…" : "去打开…") {
            FIFinderSyncController.showExtensionManagementInterface()
          }
        } label: {
          HStack(spacing: 6) {
            Text("右键菜单")
            Text(finderOn ? "已打开" : "没打开")
              .font(.caption)
              .foregroundStyle(finderOn ? Style.positiveInk : Color.secondary)
          }
          Text(
            "选中文件右键，第一层就有「用 Kitty Box 打包、解压、转换、去水印、去背景」；文件夹空白处右键有「新建文件」；两处都有下面选的「用 App 打开」。要在「系统设置 › 通用 › 登录项与扩展 › 访达」里打开 Kitty Box。"
          )
        }
        LabeledContent {
          Button("打开模板文件夹") {
            let folder = FileManager.default.urls(
              for: .applicationSupportDirectory, in: .userDomainMask)[0]
              .appending(path: "Kitty Box/新建文件模板")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
          }
        } label: {
          Text("新建文件模板")
          Text(
            "自带文本、Markdown、Word、Excel、PPT；文件夹里另有 JSON、HTML、Python、Shell、CSV 几个例子（第一次在访达空白处右键时放进去，能改能删）。往里面放任何文件（比如带抬头的 Word），右键「新建文件」里就多一项；「自定义后缀…」能建任意后缀的空文件。"
          )
        }
        LabeledContent {
          Button("打开键盘快捷键设置…") {
            NSWorkspace.shared.open(
              URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
          }
        } label: {
          Text("右键 › 服务")
          Text("不打开上面的右键菜单，「服务」里也有这几项。嫌重复可以在「系统设置 › 键盘 › 键盘快捷键 › 服务」里关掉。")
        }
      } header: {
        Text("访达")
      }
      OpenWithSection()
      Section {
        Text("结果都放在原文件旁边，原文件不动；重名时加「 2」。去水印、去背景另存成「原名-去水印」「原名-去背景」。")
          .foregroundStyle(.secondary)
      } header: {
        Text("结果放在哪")
      }
    }
    .formStyle(.grouped)
    .frame(height: 720)
    .onChange(of: appearance) { $1.apply() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in finderOn = FIFinderSyncController.isExtensionEnabled
    }
  }
}

/// 访达右键「用 X 打开」的 App：一行一个（图标、名字、移除），最后「添加 App…」。存 bundle id（挪了位置、升了级照样认得）；
/// 访达扩展读同一个偏好，改了下次右键就是新的
private struct OpenWithSection: View {
  /// 没设过时只有终端（同 FinderMenu.openWithApps 的默认）
  @State private var ids =
    UserDefaults.standard.stringArray(forKey: Prefs.openWithApps) ?? ["com.apple.Terminal"]

  var body: some View {
    Section {
      ForEach(ids, id: \.self) { id in
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        LabeledContent {
          Button("移除") { ids.removeAll { $0 == id } }
        } label: {
          HStack(spacing: 8) {
            Image(
              nsImage: app.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .application)
            )
            .resizable()
            .frame(width: 20, height: 20)
            Text(app.map(Self.name) ?? id).lineLimit(1).truncationMode(.tail)
            if app == nil {
              Text("这台 Mac 上没有").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      LabeledContent {
        Button("添加 App…", action: add)
      } label: {
        Text(ids.isEmpty ? "右键里不列 App" : "再加一个")
      }
    } header: {
      Text("右键「用 App 打开」")
    } footer: {
      Text("文件夹空白处右键用它打开这个文件夹，选中文件或文件夹右键用它打开选中的；它打不开的文件改成打开所在的文件夹（终端就开在那里）。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onChange(of: ids) { UserDefaults.standard.set($1, forKey: Prefs.openWithApps) }
  }

  /// 访达里的名字（终端、Visual Studio Code），不带 .app
  private static func name(_ app: URL) -> String {
    let name = FileManager.default.displayName(atPath: app.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
  }

  /// 从「应用程序」里挑，可以多选；已经在列表里的不重复加
  private func add() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = true
    panel.directoryURL = URL(filePath: "/Applications")
    panel.prompt = "添加"
    guard panel.runModal() == .OK else { return }
    for id in panel.urls.compactMap({ Bundle(url: $0)?.bundleIdentifier }) where !ids.contains(id) {
      ids.append(id)
    }
  }
}

private struct ModelSettings: View {
  @AppStorage(Prefs.inpaintModel) private var choice = AIModel.standard
  @Bindable private var downloads = ModelDownloads.shared
  @State private var used: Int64?

  var body: some View {
    Form {
      Section {
        ForEach(AIModel.inpainters) { model in
          ModelRow(model: model, choice: $choice, downloads: downloads)
        }
      } header: {
        Text("画笔擦除、AI 水印用哪个模型")
      } footer: {
        Text("点一行选它。模型下载后放在这台 Mac 上，之后不用联网；用到没下的那个时，页面上会提示下载。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        ModelRow(model: .cutout, choice: nil, downloads: downloads)
      } header: {
        Text("去背景「精细」用的抠图模型")
      }
      Section {
        LabeledContent {
          Button("在访达中显示") {
            try? FileManager.default.createDirectory(
              at: AIModel.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([AIModel.folder])
          }
        } label: {
          Text("下好的模型")
          Text(
            used.map { "一共占 " + $0.formatted(.byteCount(style: .file)) } ?? "正在算…")
        }
      } header: {
        Text("存放")
      } footer: {
        Text("MI-GAN、BiRefNet 是 MIT 许可，LaMa 和 Big LaMa 是 Apache-2.0；都在本机跑，图片不上传。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(height: 540)
    .task(id: downloads.states) { used = await Self.size(of: AIModel.folder) }
  }

  /// 文件夹里一共多大
  @concurrent nonisolated private static func size(of folder: URL) async -> Int64 {
    guard
      let walker = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
    else { return 0 }
    return walker.lazy.compactMap { $0 as? URL }.reduce(0) {
      $0
        + Int64(
          (try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
            ?? 0)
    }
  }
}

/// 一个模型一行：选中圈（补图模型才有，choice 是 nil 就不画）、名字和说明、大小；右边下载 / 进度 / 删除。
/// 选哪个是一个按钮（圈 + 名字说明，点整块都行）：Tab、空格、旁白都按得到（原来是整行的点按手势，只认鼠标）
private struct ModelRow: View {
  let model: AIModel
  let choice: Binding<AIModel>?
  let downloads: ModelDownloads
  @State private var confirmingRemove = false

  var body: some View {
    HStack(spacing: 12) {
      if let choice {
        Button {
          choice.wrappedValue = model
        } label: {
          info.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice.wrappedValue == model ? .isSelected : [])
      } else {
        info
      }
      switch downloads.state(of: model) {
      case .ready:
        Label("已下载", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
          .foregroundStyle(.green).help("已下载")
        Button("删除", role: .destructive) { confirmingRemove = true }
          .confirmationDialog(
            "删掉「\(model.title) · \(model.name)」？", isPresented: $confirmingRemove
          ) {
            Button("删除", role: .destructive) { downloads.remove(model) }
          } message: {
            Text("再用时要重新下载（约 \(model.downloadSize.formatted(.byteCount(style: .file)))）。")
          }
      case .downloading(let fraction):
        ProgressView(value: fraction).frame(width: 80)
        Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
          .foregroundStyle(.secondary)
        Button("取消") { downloads.cancel(model) }
      case .missing:
        Button("下载") { downloads.start(model) }
      case .failed(let reason):
        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).help(reason)
        Button("重试") { downloads.start(model) }
      }
    }
    .padding(.vertical, 2)
  }

  /// 选中圈、名字和说明（撑满到右边的按钮前）
  private var info: some View {
    HStack(spacing: 12) {
      if let choice {
        Image(systemName: choice.wrappedValue == model ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 15))
          .foregroundStyle(choice.wrappedValue == model ? Style.brand : Color.secondary)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(model.title).fontWeight(.medium)
          Text(model.name).foregroundStyle(.secondary)
          if model == .standard {
            Text("推荐")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Style.onBrand)
              .padding(.horizontal, 6).padding(.vertical, 1)
              .background(Style.brand, in: .capsule)
          }
        }
        Text(model.detail + " · 约 " + model.downloadSize.formatted(.byteCount(style: .file)))
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
    }
  }
}
