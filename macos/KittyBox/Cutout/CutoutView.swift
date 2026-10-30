// 去背景页（M7）：拖进（⌘V 粘贴、⌘O 添加）一批图 → 右边选项栏选背景（透明 / 白色）、要不要裁到主体 → 页头「去背景」，
// 几张一起做（Cutout，系统的主体识别，本机、不用下模型）。左边一列图，右边选中那张的前后对比（透明处垫棋盘格）。
// 结果是 PNG「原名-去背景.png」放在原图旁边，原图不动。

import SwiftUI

struct CutoutView: View {
  @Bindable var batch: FileBatch
  @AppStorage(Prefs.cutoutBackground) private var background = Cutout.Background.transparent
  @AppStorage(Prefs.cutoutCrop) private var crop = false

  var body: some View {
    ToolPage(tool: .cutout) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加图片（⌘O）")
      Button("清掉做完的", systemImage: "checklist.checked") { batch.clearFinished() }
        .help("清掉做好的")
        .disabled(batch.outputs.isEmpty || batch.running)
      Button("去背景") {
        let (background, crop) = (background, crop)
        Task { await batch.run { try await Cutout.remove($0, background: background, crop: crop) } }
      }
      .buttonStyle(BrandButtonStyle())
      .keyboardShortcut(.defaultAction)
      .disabled(!batch.hasWork || batch.running)
    } content: {
      if batch.items.isEmpty {
        DropZone(
          tool: .cutout, title: "拖入照片",
          detail: "人、动物、商品这类有主体的照片；自动抠出来，背景换成透明或白色，存成「原名-去背景.png」")
      } else {
        BatchPreview(batch: batch, doneVerb: "存成", checkerboard: background == .transparent)
      }
    } options: {
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
      OptionGroup(title: "说明") {
        Text("用系统自带的主体识别（同「照片」里的拷贝主体），在本机跑，不用下模型、不上传。风景、纯文字的截图认不出主体。")
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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
  }

  private var summary: String {
    if batch.items.isEmpty { return "还没有图片" }
    let failed = batch.items.count { if case .failed = $0.state { true } else { false } }
    return "\(batch.items.count) 张 · 已去掉背景 \(batch.outputs.count)"
      + (failed > 0 ? " · \(failed) 张没认出主体" : "")
      + (batch.skipped > 0 ? " · \(batch.skipped) 个不是图片，没加进来" : "")
  }
}
