// Navigator：收进来的文件往哪送——当前工具全收得了就给它，有图片或视频就问交给谁，别的交给打包；拖进工具页 / 粘贴先给当前工具；
// 哪些工具能收这批文件；文件夹交给打包；拖到侧边栏某一项就给那一项；上次选的工具记在偏好里（用临时偏好域，不写用户的）；
// 访达「服务」菜单交给指明的工具。
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
}
