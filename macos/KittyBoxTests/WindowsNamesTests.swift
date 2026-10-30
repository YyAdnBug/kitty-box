// WindowsNames：非法字符、结尾空格或点、保留名；全角符号不算问题；同一个文件夹只报一次。

import Testing

@testable import KittyBox

struct WindowsNamesTests {
  @Test func badNames() {
    #expect(WindowsNames.problem(with: "真的要删吗?.txt") == "带 ?")
    #expect(WindowsNames.problem(with: "周报 a|b 对比.png") == "带 |")
    #expect(WindowsNames.problem(with: "2026:10:30 会议.png")?.hasPrefix("带 :") == true)
    #expect(WindowsNames.problem(with: "草稿 ") == "结尾是空格或点")
    #expect(WindowsNames.problem(with: "草稿.") == "结尾是空格或点")
    #expect(WindowsNames.problem(with: "NUL.txt") == "是 Windows 的保留名")
    #expect(WindowsNames.problem(with: "com1") == "是 Windows 的保留名")
    #expect(WindowsNames.problem(with: "a\u{7}b") == "带控制字符")
  }

  @Test func fineNames() {
    #expect(WindowsNames.problem(with: "会议：终稿？.docx") == nil)
    #expect(WindowsNames.problem(with: "CONSOLE.txt") == nil)
    #expect(WindowsNames.problem(with: ".DS_Store") == nil)
    #expect(WindowsNames.problem(with: "封面.heic") == nil)
  }

  @Test func reportsFolderOnce() {
    let found = WindowsNames.problems(in: ["相册/a?b/1.png", "相册/a?b/2.png", "相册/好的.png", "x|y.txt"])
    #expect(found.map(\.path) == ["相册/a?b", "x|y.txt"])
  }
}
