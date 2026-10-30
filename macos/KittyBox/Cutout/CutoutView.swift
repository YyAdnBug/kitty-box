// 去背景页（M7；M9 加「精细」抠法和网格预览）：拖进（⌘V 粘贴、⌘O 添加）一批图 → 右边选项栏选怎么抠（精细 = 下载的模型、
// 系统 = 主体识别）、背景（透明 / 白色）、要不要裁到主体 → 页头「去背景」，几张一起做（Cutout）。图是缩略图网格，
// 点一张看大图（BatchPreview），做好了是前后对比（透明处垫棋盘格）。选了精细、模型还没下时顶上一条下载。
// 结果是 PNG「原名-去背景.png」放在原图旁边，原图不动。

import SwiftUI

struct CutoutView: View {
  @Bindable var batch: FileBatch
  @AppStorage(Prefs.cutoutBackground) private var background = Cutout.Background.transparent
  @AppStorage(Prefs.cutoutCrop) private var crop = false
  @AppStorage(Prefs.cutoutEngine) private var engine = Cutout.Engine.model
  @Bindable private var downloads = ModelDownloads.shared

  var body: some View {
    ToolPage(tool: .cutout) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加图片（⌘O）")
      Button("清掉做完的", systemImage: "checklist.checked") { batch.clearFinished() }
        .help("清掉做好的")
        .disabled(batch.outputs.isEmpty || batch.running)
      Button("去背景") {
        let (background, crop, engine) = (background, crop, engine)
        Task {
          await batch.run {
            try await Cutout.remove($0, background: background, crop: crop, engine: engine)
          }
        }
      }
      .buttonStyle(BrandButtonStyle())
      .keyboardShortcut(.defaultAction)
      .disabled(!batch.hasWork || batch.running || needsModel)
    } content: {
      VStack(spacing: 0) {
        if needsModel {
          ModelBanner(choice: .cutout, purpose: "「精细」要用下载的抠图模型；也可以在右边改用系统的")
            .padding(.horizontal, 20).padding(.vertical, 12)
          Hairline()
        }
        if batch.items.isEmpty {
          DropZone(
            tool: .cutout, title: "拖入照片",
            detail: "人、动物、商品这类有主体的图；自动抠出来，背景换成透明或白色，存成「原名-去背景.png」")
        } else {
          BatchPreview(
            batch: batch, doneVerb: "存成", checkerboard: background == .transparent,
            afterLabel: "去背景后")
        }
      }
    } options: {
      OptionGroup(title: "怎么抠", footnote: Text(engineNote)) {
        Picker("怎么抠", selection: $engine) {
          ForEach(Cutout.Engine.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      OptionGroup(title: "背景", footnote: Text("透明的存成 PNG，放进文档、海报里不带底；白色的适合证件照、商品图。")) {
        Picker("背景", selection: $background) {
          ForEach(Cutout.Background.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      OptionGroup(title: "大小", footnote: Text("打开后结果只留主体那一块，不保留原图的四边。")) {
        Toggle("裁到主体的边上", isOn: $crop)
      }
    } status: {
      Text(summary)
      Spacer(minLength: 8)
      if batch.running {
        ProgressView().controlSize(.mini)
        Text("正在抠…")
      }
    }
    .onChange(of: background) { batch.resetDone() }
    .onChange(of: crop) { batch.resetDone() }
    .onChange(of: engine) { batch.resetDone() }
  }

  /// 选了精细、模型还没下好
  private var needsModel: Bool { engine == .model && downloads.state(of: .cutout) != .ready }

  private var engineNote: String {
    switch engine {
    case .model: "下载的抠图模型（约 82 MB，下一次就行），什么都能抠，头发丝、绒毛的边干净；一张约 1 秒。在本机跑，不上传。"
    case .system: "系统自带的主体识别，不用下载；人、动物、商品抠得好，风景、海报、纯文字的图认不出主体。"
    }
  }

  private var summary: String {
    if batch.items.isEmpty { return "还没有图片" }
    let failed = batch.items.count { if case .failed = $0.state { true } else { false } }
    return "\(batch.items.count) 张 · 已去掉背景 \(batch.outputs.count)"
      + (failed > 0 ? " · \(failed) 张没认出主体" : "")
      + (batch.skipped > 0 ? " · \(batch.skipped) 个不是图片，没加进来" : "")
  }
}
