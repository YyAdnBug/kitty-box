// 界面截图自检（照 Kitty Tools 的 SnapshotProbeTests）：把各工具页带着示例数据画在屏幕外的窗口里，存成 PNG 看一眼。
// 不弹窗、不抢键盘；只读偏好，不写。平时跳过，要看时：
// TEST_RUNNER_KITTY_SNAPSHOT_DIR=/tmp/kitty-box-shots xcodebuild -project macos/KittyBox.xcodeproj -scheme KittyBox \
//   test -only-testing:KittyBoxTests/SnapshotProbeTests

import AppKit
import SwiftUI
import Testing

@testable import KittyBox

@Suite(.enabled(if: ProcessInfo.processInfo.environment["KITTY_SNAPSHOT_DIR"] != nil))
struct SnapshotProbeTests {
  private let folder = URL(
    filePath: ProcessInfo.processInfo.environment["KITTY_SNAPSHOT_DIR"] ?? "/tmp")

  @Test func pages() async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = FileManager.default.temporaryDirectory.appending(path: "kittybox-shots-\(UUID())")
    defer { try? FileManager.default.removeItem(at: samples) }
    for name in ["猫咪相册/封面.heic", "猫咪相册/.DS_Store", "猫咪相册/文档/真的要删吗?.txt", "猫咪相册/网站/debug.log"] {
      let url = samples.appending(path: name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: url)
    }

    let convert = ConvertModel()
    convert.items = [
      .init(
        source: samples.appending(path: "IMG_0001.HEIC"),
        state: .done(samples.appending(path: "IMG_0001.jpg"))),
      .init(source: samples.appending(path: "IMG_0002.HEIC"), state: .running),
      .init(source: samples.appending(path: "截图 2026-10-30.png"), state: .waiting),
      .init(source: samples.appending(path: "坏的.webp"), state: .failed("读不出这张图。")),
    ]
    try await shoot(ConvertView(model: convert), "convert")

    let pack = PackModel()
    pack.add([samples.appending(path: "猫咪相册")])
    pack.plan = await Archiver.plan(pack.items, rules: pack.ignore.rules)
    try await shoot(PackView(model: pack), "pack", height: 760)

    let unpack = UnpackModel()
    unpack.jobs = [
      .init(
        archive: samples.appending(path: "报告.zip"), state: .done(samples.appending(path: "报告"))),
      .init(archive: samples.appending(path: "资源.7z"), state: .needsPassword(again: true)),
    ]
    try await shoot(UnpackView(model: unpack), "unpack")
  }

  private func shoot(_ page: some View, _ name: String, height: CGFloat = 480) async throws {
    let size = NSSize(width: 720, height: height)
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
      styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: NavigationStack { page }.frame(width: size.width, height: size.height))
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(600))
    let view = try #require(window.contentView)
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(
      to: folder.appending(path: name + ".png"))
  }
}
