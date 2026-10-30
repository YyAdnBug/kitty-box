// 做完 / 没做成 / 正在做的那一行字：绿勾 +「存成「x」」+ 在访达中显示；红叹号 + 原因；进度条 + 百分比 +「停止」。
// 打包、解压、转换、去水印共用，只染图标、字用次要色。做完时 App 在后台，程序坞图标跳一下（bounceIfInBackground）。

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
        .fixedSize()
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

/// 正在做：知道进度时一条 100 宽的进度条 + 百分比，不知道时转圈 + 「正在…」；后面「停止」
struct RunningProgress: View {
  let label: String
  let value: Double?
  let stop: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if let value {
        ProgressView(value: value).frame(width: 100)
        Text(value.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
      } else {
        ProgressView().controlSize(.mini)
        Text(label + "…")
      }
      Button("停止", action: stop).buttonStyle(.link)
    }
  }
}

extension NSApplication {
  /// 一件事做完时 App 在后台：程序坞图标跳一下（只跳一次，不一直喊）
  func bounceIfInBackground() {
    if !isActive { requestUserAttention(.informationalRequest) }
  }
}
