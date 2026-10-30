// 做完 / 没做成 / 正在做的那一行字：绿勾 +「存成「x」」+ 在访达中显示；红叹号 + 原因；进度条 + 百分比 +「停止」。
// 打包、解压、转换、去水印共用，只染图标、字用次要色。画布上的文件读不出时铺一张 LoadFailed。做完时 App 在后台，程序坞图标跳一下（bounceIfInBackground）。

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
    // 设置 › 通用「做完时程序坞图标跳一下」关了就不跳（没设过算开着）
    let wanted = UserDefaults.standard.object(forKey: Prefs.bounceWhenDone) as? Bool ?? true
    if wanted, !isActive { requestUserAttention(.informationalRequest) }
  }
}

/// 画布上的文件读不出来时铺在画布那里（画笔擦除、视频台标）：红叹号 + 原因 +「换一个…」「关掉」，不再一直转圈
struct LoadFailed: View {
  let reason: String
  /// 「换一张…」「换一个视频…」
  let again: String
  let close: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 30)).foregroundStyle(.red)
      Text(reason).font(.system(size: 13)).multilineTextAlignment(.center)
      HStack(spacing: 10) {
        Button("关掉", action: close)
        Button(again) { Navigator.shared.importing = true }.buttonStyle(BrandButtonStyle())
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
