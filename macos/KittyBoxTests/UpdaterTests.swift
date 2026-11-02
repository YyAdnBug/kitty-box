// Updater：GitHub release 列表的 JSON 怎么认（挑版本号最大的 macos-v*，带 https 的 *_arm64.zip；windows-v*、预发布不看，
// 列表空着算没有新版）、版本号按数字比；换 App 之前卡得住别人的包和没签名的包（原来的 App 一点不动）；随包的更新日志解得开、
// 有这一版的条目。真去 GitHub 查一次平时跳过，TEST_RUNNER_KITTY_LIVE_UPDATE=1 时跑。

import Foundation
import Testing

@testable import KittyBox

struct UpdaterTests {
  private func release(
    _ tag: String, asset: String = "Kitty.Box_arm64.zip", url: String = "https://example.com/b.zip",
    prerelease: Bool = false
  ) -> String {
    """
    {"tag_name": "\(tag)", "html_url": "https://github.com/YyAdnBug/kitty-box/releases/tag/\(tag)",
     "prerelease": \(prerelease),
     "assets": [{"name": "Kitty.Box_arm64.dmg", "browser_download_url": "https://example.com/a.dmg"},
                {"name": "\(asset)", "browser_download_url": "\(url)"}]}
    """
  }

  private func list(_ releases: String...) throws -> Updater.Release? {
    try Updater.release(from: Data("[\(releases.joined(separator: ","))]".utf8))
  }

  @Test func readsRelease() throws {
    let release = try #require(try list(release("macos-v0.2.0")))
    #expect(release.version == "0.2.0")
    #expect(release.archive.absoluteString == "https://example.com/b.zip")
    #expect(release.page.lastPathComponent == "macos-v0.2.0")
  }

  /// Windows 版发在同一个仓库：列表里排在最前面也不看；挑版本号最大的 mac 版，不管列表怎么排
  @Test func picksNewestMacRelease() throws {
    let newest = try list(
      release("windows-v0.3.0"), release("macos-v0.1.9"), release("macos-v0.1.10"),
      release("macos-v0.2.0", prerelease: true))
    #expect(newest?.version == "0.1.10")
  }

  @Test func ignoresOtherReleases() throws {
    // 还没发过（GitHub 回空列表）：没有新版，不是出错
    #expect(try list() == nil)
    #expect(try list(release("windows-v0.2.0")) == nil)
    #expect(try list(release("macos-v0.2.0", url: "http://example.com/b.zip")) == nil)
    #expect(try list(release("macos-v0.2.0", asset: "x.zip")) == nil)
  }

  @Test func comparesVersions() {
    #expect(Updater.isNewer("0.1.10", than: "0.1.9"))
    #expect(Updater.isNewer("0.2.0", than: "0.1.0"))
    #expect(!Updater.isNewer("0.1.0", than: "0.1.0"))
    #expect(!Updater.isNewer("0.0.9", than: "0.1.0"))
  }

  /// 换掉正在用的 App 之前：bundle id 不对的、id 对但没签名的都卡住，原来的 App 一点不动
  @Test func keepsTheAppWhenTheUpdateIsForeignOrUnsigned() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-update-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "Kitty Box.app")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("旧版".utf8).write(to: target.appending(path: "marker"))
    // 各卡在哪一关：别的 id 卡在 bundle id，id 对的卡在验签（不是更早的哪一步碰巧抛了错）
    for (id, reason) in [
      ("com.example.other", "更新包不对（App 或版本号对不上）"), (Updater.bundleID, "更新包的签名校验没通过"),
    ] {
      let contents = root.appending(path: "\(id)/Kitty Box.app/Contents")
      try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
      try (["CFBundleIdentifier": id, "CFBundleShortVersionString": "9.9.9"] as NSDictionary)
        .write(to: contents.appending(path: "Info.plist"))
      let zip = root.appending(path: "\(id)_arm64.zip")
      let app = contents.deletingLastPathComponent()
      #expect(
        try await Subprocess.run(
          "/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]
        )
        .status == 0)
      let error = await #expect(throws: UpdateError.self) {
        try await Updater.replace(target, with: .init(version: "9.9.9", archive: zip, page: zip)) {
          _ in
        }
      }
      #expect(error?.errorDescription == reason)
      #expect(try String(contentsOf: target.appending(path: "marker"), encoding: .utf8) == "旧版")
    }
  }

  /// 关于窗口的更新日志：随包的 changelog.json 解得开（解不开时界面上是空的）、有这一版的条目、type 只用四种
  @Test func changelogHasThisVersion() throws {
    let version = try #require(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    let entries = Changelog.load()
    #expect(entries.contains { $0.version == version })
    #expect(entries.allSatisfy { $0.day != nil })
    #expect(
      entries.flatMap(\.changes).allSatisfy { ["feat", "fix", "perf", "ui"].contains($0.type) })
  }

  /// 真去 GitHub 查一次：回的是列表、解得开（还没发 mac 版时是 nil，「已经是最新版」）
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_UPDATE"] != nil))
  func checksGitHub() async throws {
    let latest = try await Updater.latest()
    if let latest { #expect(Updater.isNewer(latest.version, than: "0.0.0")) }
  }
}
