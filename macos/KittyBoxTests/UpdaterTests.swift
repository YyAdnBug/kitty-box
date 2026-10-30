// Updater：GitHub latest release 的 JSON 怎么认（只认 macos-v* 的 tag 和 https 的 *_arm64.zip）、版本号按数字比。

import Foundation
import Testing

@testable import KittyBox

struct UpdaterTests {
  private func json(tag: String, asset: String, url: String) -> Data {
    Data(
      """
      {"tag_name": "\(tag)", "html_url": "https://github.com/YyAdnBug/kitty-box/releases/tag/\(tag)",
       "assets": [{"name": "Kitty.Box_0.2.0_arm64.dmg", "browser_download_url": "https://example.com/a.dmg"},
                  {"name": "\(asset)", "browser_download_url": "\(url)"}]}
      """.utf8)
  }

  @Test func readsRelease() throws {
    let release = try #require(
      try Updater.release(
        from: json(
          tag: "macos-v0.2.0", asset: "Kitty.Box_0.2.0_arm64.zip", url: "https://example.com/b.zip")
      ))
    #expect(release.version == "0.2.0")
    #expect(release.archive.absoluteString == "https://example.com/b.zip")
  }

  @Test func ignoresOtherReleases() throws {
    #expect(
      try Updater.release(
        from: json(tag: "windows-v0.2.0", asset: "x_arm64.zip", url: "https://example.com/b.zip"))
        == nil)
    #expect(
      try Updater.release(
        from: json(tag: "macos-v0.2.0", asset: "x_arm64.zip", url: "http://example.com/b.zip"))
        == nil)
    #expect(
      try Updater.release(
        from: json(tag: "macos-v0.2.0", asset: "x.zip", url: "https://example.com/b.zip")) == nil)
  }

  @Test func comparesVersions() {
    #expect(Updater.isNewer("0.1.10", than: "0.1.9"))
    #expect(Updater.isNewer("0.2.0", than: "0.1.0"))
    #expect(!Updater.isNewer("0.1.0", than: "0.1.0"))
    #expect(!Updater.isNewer("0.0.9", than: "0.1.0"))
  }
}
