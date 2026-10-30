// 做完 / 没做成的那一行字：绿勾 +「存成「x」」+ 在访达中显示；红叹号 + 原因。打包、解压、转换、去水印共用，只染图标、字用次要色。

import AppKit
import SwiftUI

struct DoneLine: View {
  let text: String
  let url: URL

  var body: some View {
    HStack(spacing: 8) {
      Label {
        Text(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
      .layoutPriority(1)
      Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        .buttonStyle(.link)
    }
  }
}

struct FailLine: View {
  let reason: String

  var body: some View {
    Label {
      Text(reason).foregroundStyle(.secondary).lineLimit(2)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
    }
  }
}
