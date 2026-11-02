// 等着 / 做完 / 没做成 / 正在做的那一行字：钟 +「等待中」；绿勾 +「存成「x」」+ 在访达中显示；红圆叹号 + 原因（用户自己停下的
// 是灰色的停止图标，不算出错）；进度条 + 百分比 +「停止」。打包、解压、转换、去水印共用，只染图标、字用次要色。
// 没做成一律是红圆叹号（同网格角标），三角叹号只留给「注意」（Windows 不认的文件名）。
// 画布上的文件读不出时铺一张 LoadFailed。
// 一件事做完 / 没做成（finished）：旁白念一句，App 在后台时程序坞图标跳一下；长活做的时候 Mac 不闲置睡眠（working）。

import AppKit
import SwiftUI

struct WaitingLine: View {
  var body: some View {
    Label("等待中", systemImage: "clock").foregroundStyle(.secondary)
  }
}

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
        .textLink()
        .fixedSize()
    }
  }
}

struct FailLine: View {
  /// 点了「停止」的那一个写的原因（FileBatch、解压）：画灰色的停止图标，不用红色
  static let stopped = "已停止"
  let reason: String

  var body: some View {
    Label {
      Text(reason).foregroundStyle(.secondary).lineLimit(2)
    } icon: {
      if reason == Self.stopped {
        Image(systemName: "stop.circle").foregroundStyle(.secondary)
      } else {
        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
      }
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
        // 旁白只念百分比时不知道是什么在进行：带上「正在解压」这类名字
        ProgressView(value: value).frame(width: 100).accessibilityLabel(label)
        Text(value.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
      } else {
        ProgressView().controlSize(.mini)
        Text(label + "…")
      }
      Button("停止", action: stop).textLink()
    }
  }
}

extension NSApplication {
  /// 一件事（打包、一队解压、一批文件、视频导出）做完或没做成：旁白念一句（前台也念：结果只写在状态栏，
  /// 旁白用户不知道什么时候好、成没成）；App 在后台时程序坞图标跳一下（只跳一次，不一直喊）
  func finished(_ message: String) {
    AccessibilityNotification.Announcement(message).post()
    // 设置 › 通用「做完时程序坞图标跳一下」关了就不跳（没设过算开着）
    let wanted = UserDefaults.standard.object(forKey: Prefs.bounceWhenDone) as? Bool ?? true
    if wanted, !isActive { requestUserAttention(.informationalRequest) }
  }
}

extension ProcessInfo {
  /// 长活（打包、解压、一批文件、视频导出、下载模型）做的时候：Mac 不闲置睡眠，App 在后台也不被 App Nap 降速；body 做完就放开。
  /// 屏幕照常熄灭（.userInitiated 只管系统睡眠）
  func working<T>(_ reason: String, _ body: () async throws -> T) async rethrows -> T {
    let activity = beginActivity(options: .userInitiated, reason: reason)
    defer { endActivity(activity) }
    return try await body()
  }
}

/// 画布上的文件读不出来时铺在画布那里（画笔擦除、视频台标）：红圆叹号 + 原因 +「换一个…」「关掉」，不再一直转圈
struct LoadFailed: View {
  let reason: String
  /// 「换一张…」「换一个视频…」
  let again: String
  let close: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.circle.fill")
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
