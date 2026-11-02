// Navigator：收进来的文件往哪送——当前工具全收得了就给它，有图片或视频就问交给谁，别的交给打包；拖进工具页 / 粘贴先给当前工具；
// 哪些工具能收这批文件；文件夹交给打包；拖到侧边栏某一项就给那一项；上次选的工具记在偏好里（用临时偏好域，不写用户的）；
// 访达「服务」菜单交给指明的工具；App 自己的网址交来的压缩包不自己开始解；退出前问的「有活在做」和停下等收尾
// （真解一个大包，停下后隐藏的「.名字 解压中」没了、7zz 也没留下）。
// （全是压缩包直接解压那一支会真的开始解，留给 ArchiverTests 和手测。）

import AppKit
import Testing

@testable import KittyBox

final class NavigatorTests {
  /// 临时偏好域：每个测试一份，做完删掉
  private let suite = "kittybox-test-\(UUID())"
  private let photo = URL(filePath: "/tmp/kittybox-nav/IMG_0001.heic")
  private let note = URL(filePath: "/tmp/kittybox-nav/说明.txt")
  private let archive = URL(filePath: "/tmp/kittybox-nav/资源.7z")
  private let movie = URL(filePath: "/tmp/kittybox-nav/录屏.mov")

  deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

  private func make(on tool: Tool = .pack) -> Navigator {
    let navigator = Navigator(defaults: UserDefaults(suiteName: suite)!)
    navigator.tool = tool
    return navigator
  }

  @Test func imagesAskWhichTool() {
    let navigator = make(on: .unpack)
    navigator.route([photo, note])
    #expect(navigator.pending == [photo, note])
    #expect(navigator.tool == .unpack)

    navigator.open(.convert, with: navigator.pending)
    #expect(navigator.pending.isEmpty)
    #expect(navigator.tool == .convert)
    // 不是图片的没加进转换
    #expect(navigator.convert.items.map(\.source) == [photo])
  }

  @Test func currentToolTakesWhatItCan() {
    let navigator = make(on: .aiMark)
    navigator.route([photo])
    #expect(navigator.pending.isEmpty)
    #expect(navigator.aiMark.items.map(\.source) == [photo])
    // 打包什么都收，但从程序坞来的图片还是要问
    let packing = make(on: .pack)
    packing.route([photo])
    #expect(packing.pending == [photo])
  }

  @Test func videosAskToo() {
    let navigator = make()
    navigator.route([movie])
    #expect(navigator.pending == [movie])
  }

  @Test func otherFilesGoToPack() {
    let navigator = make(on: .convert)
    navigator.route([note])
    #expect(navigator.pending.isEmpty)
    #expect(navigator.tool == .pack)
    #expect(navigator.pack.items == [note])
  }

  /// 图片和视频一起来：问交给谁，只列收得了的（解压收不了）
  @Test func mixedImagesAndVideosAsk() {
    let navigator = make(on: .unpack)
    navigator.route([photo, movie])
    #expect(navigator.pending == [photo, movie])
    #expect(
      Tool.allCases.filter { navigator.accepts($0, navigator.pending) }
        == Tool.allCases.filter { $0 != .unpack })
  }

  /// 文件夹不是图片、视频、压缩包：拖进别的工具页、从程序坞来，都交给打包
  @Test func foldersGoToPack() {
    let folder = URL(filePath: "/tmp/kittybox-nav/资料", directoryHint: .isDirectory)
    let navigator = make(on: .convert)
    navigator.give([folder])
    #expect(navigator.tool == .pack)
    #expect(navigator.pack.items == [folder])
    let docked = make(on: .aiMark)
    docked.route([folder, note])
    #expect(docked.pending.isEmpty)
    #expect(docked.pack.items == [folder, note])
  }

  /// 拖到侧边栏某一项：给那一项，收不了的数一下（不另外分派）
  @Test func droppedOnASidebarRowGoesToThatRow() {
    let navigator = make(on: .pack)
    navigator.open(.convert, with: [photo, note])
    #expect(navigator.tool == .convert)
    #expect(navigator.convert.items.map(\.source) == [photo])
    #expect(navigator.convert.skipped == 1)
    #expect(navigator.pack.items.isEmpty)
  }

  @Test func droppedOnAPageGoesToThatTool() {
    let navigator = make(on: .convert)
    navigator.give([photo, note])
    #expect(navigator.tool == .convert)
    #expect(navigator.convert.items.map(\.source) == [photo])
    // 当前工具一个都收不了：照程序坞的分派
    navigator.give([note])
    #expect(navigator.tool == .pack)
    #expect(navigator.pack.items == [note])
  }

  @Test func whoAccepts() {
    let navigator = make()
    #expect(navigator.accepts(.pack, [note]))
    #expect(!navigator.accepts(.unpack, [photo, note]))
    #expect(navigator.accepts(.unpack, [photo, archive]))
    #expect(navigator.accepts(.convert, [photo, note]))
    #expect(!navigator.accepts(.convert, [note]))
    #expect(navigator.accepts(.aiMark, [photo]))
    #expect(navigator.accepts(.cutout, [photo]))
    #expect(!navigator.accepts(.cutout, [movie]))
    #expect(navigator.accepts(.erase, [photo]))
    #expect(navigator.accepts(.video, [movie]))
    #expect(navigator.accepts(.videoConvert, [movie]))
    #expect(!navigator.accepts(.videoConvert, [photo]))
    #expect(!navigator.accepts(.video, [photo]))
    #expect(!navigator.accepts(.convert, [movie]))
  }

  @Test func remembersTheLastTool() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    let first = Navigator(defaults: defaults)
    #expect(first.tool == .pack)
    first.tool = .video
    #expect(Navigator(defaults: defaults).tool == .video)
  }

  @Test func servicesHandToTheNamedTool() {
    let navigator = make(on: .video)
    let services = Services(navigator: navigator)
    let pasteboard = NSPasteboard(name: .init("kittybox-test-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([photo as NSURL])
    var message: NSString?
    withUnsafeMutablePointer(to: &message) {
      services.convert(pasteboard, userData: nil, error: AutoreleasingUnsafeMutablePointer($0))
    }
    #expect(navigator.tool == .convert)
    #expect(navigator.convert.items.map(\.source) == [photo])
  }

  /// 访达扩展交过来的网址：scheme 是 App 的 bundle id，工具名、文件路径（中文、空格）都还原得出来；别人的网址、缺东西的不认
  @Test func finderLinkNamesToolAndFiles() throws {
    let scheme = try #require(Bundle.main.bundleIdentifier)
    var link = URLComponents()
    link.scheme = scheme
    link.host = "open"
    link.queryItems = [
      URLQueryItem(name: "tool", value: "videoConvert"),
      URLQueryItem(name: "file", value: "/tmp/假期 视频.mov"),
      URLQueryItem(name: "file", value: "/tmp/a&b=c.mp4"),
      URLQueryItem(name: "file", value: "/tmp/1+1 #2 50%?.mp4"),
    ]
    let url = try #require(link.url)
    let request = try #require(Services.request(from: url))
    #expect(request.tool == .videoConvert)
    #expect(
      request.files.map(\.path) == ["/tmp/假期 视频.mov", "/tmp/a&b=c.mp4", "/tmp/1+1 #2 50%?.mp4"])
    #expect(Services.request(from: URL(string: "other://open?tool=pack&file=/tmp/a")!) == nil)
    #expect(Services.request(from: URL(string: "\(scheme)://open?tool=nope&file=/tmp/a")!) == nil)
    #expect(Services.request(from: URL(string: "\(scheme)://open?tool=pack")!) == nil)
    #expect(Services.request(from: URL(filePath: "/tmp/a.zip")) == nil)
  }

  /// 网址谁都能打开（网页、别的 App）：压缩包只放进解压页、写「还没开始」，不自己解；再来一次也不动它
  @Test func linkRequestsWaitForAClick() {
    let navigator = make(on: .convert)
    navigator.take(.unpack, [archive], autostart: false)
    navigator.take(.unpack, [archive], autostart: false)
    #expect(navigator.tool == .unpack)
    #expect(navigator.unpack.jobs.count == 1)
    guard case .held = navigator.unpack.jobs.first?.state else {
      Issue.record("网址交来的压缩包应该等着：\(String(describing: navigator.unpack.jobs.first?.state))")
      return
    }
    #expect(navigator.unpack.jobs.first?.canRetry == true)
    #expect(!navigator.unpack.running)
    #expect(!navigator.busy)
    // 拖到「解压」那一行的不是压缩包：没有要解的，不开工
    navigator.open(.unpack, with: [photo])
    #expect(!navigator.unpack.running)
  }

  /// 退出前：有活在做就是 busy；stopAll 等收尾走完才回来——正在解的停下、隐藏的「.名字 解压中」删掉、7zz 不留，
  /// 排着队的不再开始，一批图正在做的写「已停止」
  @Test func stopAllWaitsForCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kittybox-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "源")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let noise = try #require(FileHandle(forReadingAtPath: "/dev/urandom"))
    try noise.readData(ofLength: 40_000_000).write(to: source.appending(path: "1.bin"))
    // PPMd 解得慢（每秒几十 MB），停得下来（同 ArchiverTests）
    let sevenZip = try #require(Bundle.main.url(forAuxiliaryExecutable: "7zz"))
    let out = root.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let big = out.appending(path: "大.7z")
    let small = out.appending(path: "小.7z")
    for (archive, method) in [(big, "-m0=PPMd"), (small, "-mx0")] {
      let made = try await Subprocess.run(
        sevenZip.path, ["a", "-t7z", method, archive.path, "源"], directory: root)
      #expect(made.status == 0)
    }

    let navigator = make()
    navigator.take(.unpack, [big, small], autostart: false)
    #expect(!navigator.busy)
    // 点了「开始解压」：一个接一个
    for job in navigator.unpack.jobs { navigator.unpack.retry(job.id) }
    navigator.convert.add([photo])
    navigator.convert.start { _ in
      try await Task.sleep(for: .seconds(60))
      return URL(filePath: "/tmp/不会有.png")
    }
    let hidden = ".大 解压中"
    for _ in 0..<100 {
      if try FileManager.default.contentsOfDirectory(atPath: out.path).contains(hidden) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).contains(hidden))
    #expect(navigator.busy)

    await navigator.stopAll()
    #expect(!navigator.busy)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["大.7z", "小.7z"])
    guard case .failed("已停止") = navigator.unpack.jobs[0].state else {
      Issue.record("正在解的应该写「已停止」：\(navigator.unpack.jobs[0].state)")
      return
    }
    // 排着队的没开始
    guard case .waiting = navigator.unpack.jobs[1].state else {
      Issue.record("排着队的不该开始：\(navigator.unpack.jobs[1].state)")
      return
    }
    guard case .failed("已停止") = navigator.convert.items[0].state else {
      Issue.record("一批图正在做的应该写「已停止」：\(navigator.convert.items[0].state)")
      return
    }
    // 7zz 停掉了，没被丢下接着跑（pgrep 找不到时退出码是 1）
    let left = try await Subprocess.run("/usr/bin/pgrep", ["-f", big.path], captures: true)
    #expect(left.status == 1)
    #expect(left.output.isEmpty)
  }
}
