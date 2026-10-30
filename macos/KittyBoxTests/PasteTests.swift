// ⌘V 粘贴：剪贴板里的文件原样交出去；只有图片数据时原样存成一个文件；什么都没有是空的；粘贴到工具页交给这个工具。
// 用一块自己起名的剪贴板，不碰用户的。

import AppKit
import Testing

@testable import KittyBox

struct PasteTests {
  private let folder = FileManager.default.temporaryDirectory.appending(
    path: "kittybox-paste-\(UUID())")

  private func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
    let pasteboard = NSPasteboard(name: .init("kittybox-test-\(UUID())"))
    pasteboard.clearContents()
    fill(pasteboard)
    return pasteboard
  }

  @Test func filesComeOutAsIs() {
    let urls = [URL(filePath: "/tmp/a.zip"), URL(filePath: "/tmp/图.png")]
    let pasteboard = board { $0.writeObjects(urls as [NSURL]) }
    defer { pasteboard.releaseGlobally() }
    #expect(Paste.files(from: pasteboard, savingTo: folder) == urls)
  }

  @Test func imageDataIsSavedWithItsOwnFormat() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    let pasteboard = board { $0.setData(jpeg, forType: .init("public.jpeg")) }
    defer { pasteboard.releaseGlobally() }

    let first = try #require(Paste.files(from: pasteboard, savingTo: folder).first)
    #expect(first.lastPathComponent.hasPrefix("粘贴的图片 "))
    #expect(first.pathExtension == "jpeg")
    #expect(try Data(contentsOf: first) == jpeg)
    // 同一秒再贴一次不覆盖，名字加「 2」
    let second = try #require(Paste.files(from: pasteboard, savingTo: folder).first)
    #expect(second != first)
  }

  @Test func textAloneGivesNothing() {
    let pasteboard = board { $0.setString("你好", forType: .string) }
    defer { pasteboard.releaseGlobally() }
    #expect(Paste.files(from: pasteboard, savingTo: folder).isEmpty)
  }

  @Test func pasteGoesToTheOpenTool() {
    let photo = URL(filePath: "/tmp/kittybox-nav/IMG_0001.heic")
    let navigator = Navigator()
    navigator.path = [.convert]
    navigator.paste([photo])
    #expect(navigator.path == [.convert])
    #expect(navigator.convert.items.map(\.source) == [photo])

    // 在首页：照拖进来的分派（有图片就等你点一格）
    let home = Navigator()
    home.paste([photo])
    #expect(home.pending == [photo])
  }
}
