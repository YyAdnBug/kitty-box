// AI 水印页（M7，原来的「Gemini 角标」页）：一批图（BatchPreview：缩略图网格，点一张看大图），页头「去掉水印」一张一张去
// （AIMark：Gemini 星标按原理还原，「AI生成」这类文字水印找到位置交给补图模型补）；去好了大图是前后对比（拖中间的线，能放大）。
// 认不出的那格写「没认出 AI 水印」，右键或格里的链接能改用画笔擦除（交给 Navigator 切过去）。补图模型没下好时顶上一条。
// 结果是「原名-去水印」放在原图旁边，不碰原图。去的时候「也去掉这些字」锁住，页头换成「停止」。

import AppKit
import SwiftUI

struct AIMarkView: View {
  @Bindable var batch: FileBatch
  /// 认不出的图交给画笔擦除
  let handOff: (URL) -> Void
  @AppStorage(Prefs.inpaintModel) private var choice = AIModel.standard
  @Bindable private var downloads = ModelDownloads.shared
  /// 也去掉这些字（用户自己加的，逗号隔开）
  @AppStorage(Prefs.aiMarkWords) private var extra = ""
  /// 正在「也去掉这些字」里打字：回车、← → Esc 留给输入框，不去点页头的按钮、不换大图
  @FocusState private var typing: Bool

  var body: some View {
    ToolPage(tool: .aiMark) {
      Button("添加文件…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("添加图片（⌘O）")
      Button("清掉做完的", systemImage: "checkmark.circle.badge.xmark") { batch.clearFinished() }
        .help("清掉去好的")
        .disabled(batch.outputs.isEmpty || batch.running)
      if batch.running {
        Button("停止") { batch.stop() }
          .buttonStyle(BrandButtonStyle())
          .help("正在去的几张去完就停，没开始的留着")
      } else {
        Button("去掉水印") {
          let (choice, words) = (choice, AIMark.words(extra))
          batch.start { try await AIMark.clean($0, using: choice, words: words) }
        }
        .buttonStyle(BrandButtonStyle())
        .keyboardShortcut(typing ? nil : .defaultAction)
        .disabled(!batch.hasWork)
      }
    } content: {
      VStack(spacing: 0) {
        if downloads.state(of: choice) != .ready {
          ModelBanner(choice: choice, purpose: "Gemini 星标不用它；「AI生成」这类文字水印要用补图模型补")
            .padding(.horizontal, 20).padding(.vertical, 12)
          Hairline()
        }
        if batch.items.isEmpty {
          DropZone(
            tool: .aiMark, title: "拖入 AI 生成的图",
            detail: "Gemini 的星标按原理还原，不靠猜；豆包、即梦这类角上的「AI生成」字样自动补掉。结果另存成「原名-去水印」")
        } else {
          BatchPreview(batch: batch, doneVerb: "存成", handOff: handOff, typing: typing)
        }
      }
    } options: {
      OptionGroup(
        title: "也去掉这些字",
        footnote: Text("不是 AI 生成的字也行：署名、网址、「样张」…用逗号隔开；整张图里找，带这些字的那一行整行补掉。只想擦一张图上的某几行，用画笔擦除的「选文字」。")
      ) {
        TextField("比如：样张, @我的名字", text: $extra, axis: .vertical)
          .lineLimit(2...4)
          .textFieldStyle(.roundedBorder)
          .focused($typing)
      }
      // 去的时候锁住：这一批按点按钮时填的字去
      .disabled(batch.running)
      OptionGroup(title: "会去掉什么") {
        Text("Gemini 的星标按原理还原；贴在上下边的「AI生成」「Made with AI」这类字样，和上面填的字，用补图模型补掉。")
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } status: {
      Text(summary)
      Spacer(minLength: 8)
      if batch.running {
        ProgressView().controlSize(.mini)
        Text("正在去水印…")
      } else {
        Text("认不出的可以右键改用画笔擦除")
      }
    }
    .onChange(of: extra) { batch.resetDone() }
  }

  private var summary: String {
    if batch.items.isEmpty { return "还没有图片" }
    let failed = batch.items.count { if case .failed = $0.state { true } else { false } }
    return "\(batch.items.count) 张 · 已去掉 \(batch.outputs.count)"
      + (failed > 0 ? " · \(failed) 张没去成" : "")
      + (batch.skipped > 0 ? " · \(batch.skipped) 个不是图片，没加进来" : "")
  }
}
