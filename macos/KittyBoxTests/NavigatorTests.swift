// Navigator：拖进来的文件往哪送——里面有图片就回首页让你选，没有图片的交给打包；哪几格能收这批文件。
// （全是压缩包直接解压那一支会真的开始解，留给 ArchiverTests 和手测。）

import Foundation
import Testing

@testable import KittyBox

struct NavigatorTests {
  private let photo = URL(filePath: "/tmp/kittybox-nav/IMG_0001.heic")
  private let note = URL(filePath: "/tmp/kittybox-nav/说明.txt")
  private let archive = URL(filePath: "/tmp/kittybox-nav/资源.7z")

  @Test func imagesWaitOnHome() {
    let navigator = Navigator()
    navigator.path = [.unpack]
    navigator.route([photo, note])
    #expect(navigator.pending == [photo, note])
    #expect(navigator.path.isEmpty)

    navigator.open(.convert, with: navigator.pending)
    #expect(navigator.pending.isEmpty)
    #expect(navigator.path == [.convert])
    // 不是图片的没加进转换
    #expect(navigator.convert.items.map(\.source) == [photo])
  }

  @Test func otherFilesGoToPack() {
    let navigator = Navigator()
    navigator.route([note])
    #expect(navigator.pending.isEmpty)
    #expect(navigator.path == [.pack])
    #expect(navigator.pack.items == [note])
  }

  @Test func whoAccepts() {
    let navigator = Navigator()
    #expect(navigator.accepts(.pack, [note]))
    #expect(!navigator.accepts(.unpack, [photo, note]))
    #expect(navigator.accepts(.unpack, [photo, archive]))
    #expect(navigator.accepts(.convert, [photo, note]))
    #expect(!navigator.accepts(.convert, [note]))
    #expect(!navigator.accepts(.watermark, [photo]))
  }
}
