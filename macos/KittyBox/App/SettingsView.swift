// 设置窗口（M7，App 菜单「设置…」⌘,；用户问「没看到设置的入口」）：两页，分组表单，同 Kitty Tools 设置页的样子。
// - 通用：外观（跟随系统 / 浅色 / 深色）、自动检查更新、做完时程序坞图标跳一下、访达「服务」菜单怎么开关、结果放哪。
// - 补图模型：画笔擦除和 AI 水印用哪个（快速 / 标准 / 高清，InpaintModel），各自下载、删除，下好的占多少地方。
// 打包的忽略清单、各页的格式和质量就在各自页面的右边，不在这里重复一份。

import AppKit
import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
      ModelSettings().tabItem { Label("补图模型", systemImage: "cpu") }
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
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Form {
      Section("外观") {
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
          Button("打开键盘快捷键设置…") {
            NSWorkspace.shared.open(
              URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
          }
        } label: {
          Text("访达右键 › 服务")
          Text("选中文件右键，「服务」里有用 Kitty Box 打包、解压、转换图片、去 AI 水印、去背景。不想要可以在 键盘 › 键盘快捷键 › 服务 里关掉。")
        }
      } header: {
        Text("访达")
      }
      Section {
        Text("结果都放在原文件旁边，原文件不动；重名时加「 2」。去水印、去背景另存成「原名-去水印」「原名-去背景」。")
          .foregroundStyle(.secondary)
      } header: {
        Text("结果放在哪")
      }
    }
    .formStyle(.grouped)
    .frame(height: 620)
    .onChange(of: appearance) { $1.apply() }
  }
}

private struct ModelSettings: View {
  @AppStorage(Prefs.inpaintModel) private var choice = InpaintModel.standard
  @Bindable private var downloads = ModelDownloads.shared
  @State private var used: Int64?

  var body: some View {
    Form {
      Section {
        ForEach(InpaintModel.allCases) { model in
          ModelRow(model: model, choice: $choice, downloads: downloads)
        }
      } header: {
        Text("画笔擦除、AI 水印用哪个模型")
      } footer: {
        Text("点一行选它。模型下载后放在这台 Mac 上，之后不用联网；用到没下的那个时，页面上会提示下载。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        LabeledContent {
          Button("在访达中显示") {
            try? FileManager.default.createDirectory(
              at: InpaintModel.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([InpaintModel.folder])
          }
        } label: {
          Text("下好的模型")
          Text(
            used.map { "一共占 " + $0.formatted(.byteCount(style: .file)) } ?? "正在算…")
        }
      } header: {
        Text("存放")
      } footer: {
        Text("MI-GAN 是 MIT 许可，LaMa 和 Big LaMa 是 Apache-2.0；都在本机跑，图片不上传。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(height: 440)
    .task(id: downloads.states) { used = await Self.size(of: InpaintModel.folder) }
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

/// 一个模型一行：选中圈、名字和说明、大小；右边下载 / 进度 / 删除
private struct ModelRow: View {
  let model: InpaintModel
  @Binding var choice: InpaintModel
  let downloads: ModelDownloads

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: choice == model ? "largecircle.fill.circle" : "circle")
        .font(.system(size: 15))
        .foregroundStyle(choice == model ? Style.brand : Color.secondary)
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
      switch downloads.state(of: model) {
      case .ready:
        Label("已下载", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
          .foregroundStyle(.green).help("已下载")
        Button("删除") { downloads.remove(model) }
      case .downloading(let fraction):
        ProgressView(value: fraction).frame(width: 80)
        Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
          .foregroundStyle(.secondary)
      case .missing:
        Button("下载") { Task { await downloads.start(model) } }
      case .failed(let reason):
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(reason)
        Button("重试") { Task { await downloads.start(model) } }
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onTapGesture { choice = model }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(choice == model ? .isSelected : [])
  }
}
