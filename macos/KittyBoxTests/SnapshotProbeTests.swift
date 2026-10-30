// 界面截图自检（照 Kitty Tools 的 SnapshotProbeTests）：关于窗口画在屏幕外存成 PNG；主窗口（侧边栏、工具栏、右边的选项）屏外画不出来，
// 开一扇真窗口（在屏幕左下角，不当 key、不抢键盘），带着示例数据一个工具停 3.5 秒，每到一个工具把窗口编号写进
// live-<工具>.txt（先截一张空着的 live-empty-pack），由外面用 screencapture -l <编号> 截。侧边栏按 key 窗口画（品牌粉选中）。画笔擦除模型下载过的话，再在系统壁纸上真擦一处存 erase-result.png、
// 截一张对比（live-erase-compare）。偏好用临时域，不写用户的。平时跳过，要看时：
// TEST_RUNNER_KITTY_SNAPSHOT_DIR=/tmp/kitty-box-shots xcodebuild -project macos/KittyBox.xcodeproj -scheme KittyBox \
//   test -only-testing:KittyBoxTests/SnapshotProbeTests

import AppKit
import ImageIO
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
    for name in [
      "猫咪相册/封面.heic", "猫咪相册/.DS_Store", "猫咪相册/文档/真的要删吗?.txt", "猫咪相册/网站/debug.log", "周报.txt",
      "报告.zip", "资源.7z", "旧照片.rar",
    ] {
      let url = samples.appending(path: name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 7, count: 180_000).write(to: url)
    }
    for (name, marked) in [
      ("IMG_0001.png", false), ("IMG_0002.png", false), ("截图 2026-10-30.png", false),
      ("Gemini_Generated_Image_1.png", true), ("Gemini_Generated_Image_1-去水印.png", false),
    ] {
      try writeSample(samples.appending(path: name), marked: marked)
    }

    try await shoot(AboutView(), "about", height: 560)

    let suite = "kittybox-test-\(UUID())"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let navigator = Navigator(defaults: try #require(UserDefaults(suiteName: suite)))

    let window = NSWindow(
      contentRect: NSRect(x: 60, y: 60, width: 1040, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.toolbarStyle = .unifiedCompact
    // 当成 key 窗口画（侧边栏选中是品牌粉）：真窗口在测试里当不了 key，也不该抢用户的键盘
    let hosting = NSHostingView(
      rootView: MainView(navigator: navigator).environment(\.controlActiveState, .key))
    hosting.sceneBridgingOptions = [.toolbars, .title]
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    // 空着的页（拖放区）
    try await live(window, "empty-pack")

    navigator.pack.add([samples.appending(path: "猫咪相册"), samples.appending(path: "周报.txt")])
    navigator.pack.plan = await Archiver.plan(
      navigator.pack.items, rules: navigator.pack.ignore.rules)

    navigator.unpack.jobs = [
      .init(
        archive: samples.appending(path: "报告.zip"), state: .done(samples.appending(path: "报告"))),
      .init(archive: samples.appending(path: "旧照片.rar"), state: .running),
      .init(archive: samples.appending(path: "资源.7z"), state: .needsPassword(again: false)),
    ]

    let converted = try await ImageConverter.convert(
      samples.appending(path: "IMG_0001.png"), to: .jpeg, quality: 0.85)
    navigator.convert.items = [
      .init(source: samples.appending(path: "IMG_0001.png"), state: .done(converted)),
      .init(source: samples.appending(path: "IMG_0002.png"), state: .running),
      .init(source: samples.appending(path: "截图 2026-10-30.png"), state: .waiting),
      .init(source: samples.appending(path: "坏的.webp"), state: .failed("读不出这张图。")),
    ]

    navigator.gemini.items = [
      .init(
        source: samples.appending(path: "Gemini_Generated_Image_1.png"),
        state: .done(samples.appending(path: "Gemini_Generated_Image_1-去水印.png"))),
      .init(
        source: samples.appending(path: "截图 2026-10-30.png"), state: .failed("没认出 Gemini 角标。")),
    ]

    // 画笔擦除：系统自带的壁纸，涂一笔（还没擦）
    let photo = URL(filePath: "/System/Library/Desktop Pictures/Sonoma.heic")
    navigator.erase.load(photo)
    let movie = samples.appending(path: "录屏.mov")
    try await makeTestVideo(at: movie)
    navigator.video.load(movie)
    try await Task.sleep(for: .seconds(2))
    let image = try #require(navigator.erase.image)
    let (cx, cy) = (CGFloat(image.width) * 0.55, CGFloat(image.height) * 0.62)
    navigator.erase.strokes = [
      .init(points: [CGPoint(x: cx - 300, y: cy), CGPoint(x: cx + 300, y: cy)], width: 160)
    ]
    navigator.video.rects = [CGRect(x: 118, y: 6, width: 34, height: 20)]

    for tool in Tool.allCases {
      navigator.tool = tool
      try await live(window, tool.rawValue)
    }

    // 真的擦一处（同一条路：裁、缩、补、贴回），存成 PNG 看接缝；再截一张前后对比
    guard LaMaModel.isInstalled else { return }
    navigator.tool = .erase
    await navigator.erase.erase()
    let erased = try #require(navigator.erase.image)
    let crop = try #require(
      erased.cropping(to: CGRect(x: cx - 600, y: cy - 300, width: 1200, height: 600)))
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        folder.appending(path: "erase-result.png") as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, crop, nil)
    #expect(CGImageDestinationFinalize(destination))
    navigator.erase.comparing = true
    try await live(window, "erase-compare")
  }

  /// 等画面停下来，把窗口编号写进 live-<名字>.txt，停着等外面截
  private func live(_ window: NSWindow, _ name: String) async throws {
    try await Task.sleep(for: .seconds(1.5))
    try "\(window.windowNumber)".write(
      to: folder.appending(path: "live-\(name).txt"), atomically: true, encoding: .utf8)
    try await Task.sleep(for: .seconds(2))
  }

  private func writeSample(_ url: URL, marked: Bool) throws {
    let (width, height) = (640, 400)
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let gradient = try #require(
      CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
          CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
          CGColor(red: 0.9, green: 0.5, blue: 0.3, alpha: 1),
        ]
          as CFArray, locations: nil))
    context.drawLinearGradient(
      gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    if marked {
      context.setFillColor(CGColor(gray: 1, alpha: 0.9))
      context.fillEllipse(in: CGRect(x: width - 60, y: 20, width: 32, height: 32))
    }
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  private func shoot(_ page: some View, _ name: String, height: CGFloat = 480) async throws {
    let size = NSSize(width: 720, height: height)
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
      styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: NavigationStack { page }.frame(width: size.width, height: size.height))
    // 固定浅色：系统按日落自动切到深色时，屏外窗口画出来白底白字（2026-10-30 实测），截图要和系统设置无关
    window.appearance = NSAppearance(named: .aqua)
    window.backgroundColor = .windowBackgroundColor
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
