// 空格快速查看（M6，同访达）：表格、列表里选中几行按空格，系统的快速查看面板预览选中的（←→ 换一个），再按空格关掉。
// 做好了的行看结果，还没做的看原文件。打包、解压、图片转换、视频转换的表格和 Gemini 角标的列表共用。

import QuickLook
import SwiftUI

extension View {
  /// selected：现在选中的那几个文件（按空格时取）
  func spacePreview(_ selected: @escaping () -> [URL]) -> some View {
    modifier(SpacePreview(selected: selected))
  }
}

private struct SpacePreview: ViewModifier {
  let selected: () -> [URL]
  @State private var current: URL?
  @State private var items: [URL] = []

  func body(content: Content) -> some View {
    content
      .onKeyPress(.space) {
        if current != nil {
          current = nil
          return .handled
        }
        let urls = selected()
        guard let first = urls.first else { return .ignored }
        items = urls
        current = first
        return .handled
      }
      .quickLookPreview($current, in: items)
  }
}
