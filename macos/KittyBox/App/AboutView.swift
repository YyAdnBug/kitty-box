// 关于窗口（App 菜单「关于 Kitty Box」「检查更新…」）：品牌页（照 Kitty Tools 的关于页：奶油底、96 pt 图标、圆体字标、
// 品牌粉版本胶囊），下面检查更新 / 更新并重新打开，更新日志（Resources/changelog.json，一个版本一张卡），随包的第三方组件和仓库链接。

import AppKit
import SwiftUI
import os

struct Changelog: Decodable, Identifiable {
  struct Change: Decodable, Hashable {
    let type: String
    let scope: String
    let text: String
  }

  let version: String
  let date: String
  let summary: String
  let changes: [Change]

  var id: String { version }

  /// date（2026-10-30）读成日期，显示时按系统的写法
  var day: Date? {
    try? Date(date, strategy: Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
  }

  static func load() -> [Changelog] {
    do {
      guard let url = Bundle.main.url(forResource: "changelog", withExtension: "json") else {
        return []
      }
      return try JSONDecoder().decode([Changelog].self, from: Data(contentsOf: url))
    } catch {
      // 解不开时更新日志是空的：记一笔
      Updater.log.error("更新日志解不开：\(error, privacy: .public)")
      return []
    }
  }
}

struct AboutView: View {
  @Bindable private var updater = Updater.shared
  private let entries = Changelog.load()
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 10) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
          .accessibilityHidden(true)
        Text("Kitty Box").font(.system(size: 26, weight: .bold, design: .rounded))
        HStack(spacing: 8) {
          Text("版本 \(version)")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Style.onBrand)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Style.brand, in: .capsule)
          Link(
            "github.com/YyAdnBug/kitty-box",
            destination: URL(string: "https://github.com/YyAdnBug/kitty-box")!
          )
          .font(.system(size: 12))
        }
        update.frame(height: 28)
      }
      .padding(.top, 8)
      .padding(.bottom, 16)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text("更新日志").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
          ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .firstTextBaseline) {
                Text(entry.version).font(.headline)
                Text(entry.day?.formatted(date: .long, time: .omitted) ?? entry.date)
                  .font(.caption).foregroundStyle(.secondary)
              }
              Text(entry.summary).font(.callout)
              ForEach(entry.changes, id: \.self) { change in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text(change.scope).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                  Text(change.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
              }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(onCream: true)
          }
          // verbatim：别把名字里的符号当 Markdown
          Text(
            verbatim:
              "随包的第三方组件：7-Zip（LGPL 2.1）、Gemini 去水印的 α 图（MIT）；模型用到时才下载：补图的 LaMa、Big LaMa 2048（Apache-2.0）、MI-GAN（MIT），抠图的 BiRefNet（MIT）。去背景的「系统」抠法和找文字用系统自带的 Vision。许可证全文在 App 包的 Resources 里。"
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Link(
            "第三方组件的出处和源码",
            destination: URL(string: "https://github.com/YyAdnBug/kitty-box/blob/macos/NOTICE.md")!
          )
          .font(.caption)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
      }
    }
    .frame(width: 520, height: 560)
    .background(Style.brandCream)
  }

  @ViewBuilder private var update: some View {
    HStack(spacing: 10) {
      switch updater.state {
      case .idle:
        Button("检查更新") { Task { await updater.check() } }
      case .checking:
        ProgressView().controlSize(.small)
        Text("正在检查…").foregroundStyle(.secondary)
      case .upToDate:
        // 只染图标：系统绿、红当字在奶油底上对比度不够
        Label {
          Text("已经是最新版")
        } icon: {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        Button("再查一次") { Task { await updater.check() } }.buttonStyle(.link)
      case .available(let release):
        Text("有新版本 \(release.version)")
        Link("看看改了什么", destination: release.page)
        Button("更新并重新打开") { Task { await updater.install() } }
          .buttonStyle(BrandButtonStyle())
      case .installing(let release):
        if let progress = updater.progress, progress < 1 {
          ProgressView(value: progress) {
            Text("正在下载 \(release.version) · \(Int((progress * 100).rounded()))%").font(.caption)
          }
        } else {
          ProgressView().controlSize(.small)
          Text("正在安装 \(release.version)…").foregroundStyle(.secondary)
        }
      case .failed(let reason):
        Label {
          Text(reason).lineLimit(2)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        Button("再试一次") { Task { await updater.check() } }.buttonStyle(.link)
        Link("去发布页", destination: Updater.releasesPage).font(.caption)
      }
    }
    .font(.callout)
  }
}
