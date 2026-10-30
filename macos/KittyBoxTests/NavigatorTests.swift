// Navigator：收进来的文件往哪送——当前工具全收得了就给它，有图片或视频就问交给谁，别的交给打包；拖进工具页 / 粘贴先给当前工具；
// 哪些工具能收这批文件；上次选的工具记在偏好里（用临时偏好域，不写用户的）。
// （全是压缩包直接解压那一支会真的开始解，留给 ArchiverTests 和手测。）

import Foundation
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
    let navigator = make(on: .gemini)
    navigator.route([photo])
    #expect(navigator.pending.isEmpty)
    #expect(navigator.gemini.items.map(\.source) == [photo])
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
    #expect(navigator.accepts(.gemini, [photo]))
    #expect(navigator.accepts(.erase, [photo]))
    #expect(navigator.accepts(.video, [movie]))
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
}
