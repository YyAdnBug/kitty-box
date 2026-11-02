// ZipNames：三种 zip 的字节夹具（有 UTF-8 标志、没标志写的是 UTF-8、没标志写的是 GBK），判断该按哪种编码解。

import Foundation
import Testing

@testable import KittyBox

/// 只有名字、内容为空、不压缩的 zip；名字字节和 UTF-8 标志由测试给（ArchiverTests 也用它造 GBK 名字的包）
func zipData(_ entries: [(name: [UInt8], utf8: Bool)]) -> Data {
  func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
  func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16(value >> 16 & 0xFFFF) }
  var local: [UInt8] = []
  var central: [UInt8] = []
  for entry in entries {
    let offset = local.count
    let flags = le16(entry.utf8 ? 0x0800 : 0)
    // 版本、标志、方法（存储）、时间、日期（1980-01-01）、CRC、压缩后 / 前大小
    let common = le16(10) + flags + le16(0) + le16(0) + le16(0x21) + le32(0) + le32(0) + le32(0)
    local += le32(0x0403_4B50) + common + le16(entry.name.count) + le16(0) + entry.name
    central +=
      le32(0x0201_4B50) + le16(0x031E) + common + le16(entry.name.count) + le16(0) + le16(0)
      + le16(0) + le16(0) + le32(0o100644 << 16) + le32(offset) + entry.name
  }
  let end =
    le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
    + le32(central.count) + le32(local.count) + le16(0)
  return Data(local + central + end)
}

let gbkName =
  [UInt8]([0xB1, 0xA8, 0xB8, 0xE6]) + Array("/".utf8)
  + [0xD6, 0xD0, 0xCE, 0xC4, 0xCE, 0xC4, 0xBC, 0xFE] + Array(".txt".utf8)  // 报告/中文文件.txt

struct ZipNamesTests {
  private func charset(_ entries: [(name: [UInt8], utf8: Bool)]) throws -> ZipNames.Charset? {
    let url = FileManager.default.temporaryDirectory.appending(path: "kittybox-\(UUID()).zip")
    try zipData(entries).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(ZipNames.isZip(url))
    return ZipNames.charset(of: url)
  }

  @Test func flaggedUTF8() throws {
    #expect(try charset([(Array("报告/中文文件.txt".utf8), true)]) == .utf8)
  }

  /// 访达、ditto 打的包：UTF-8 字节、不标志
  @Test func unflaggedUTF8() throws {
    #expect(
      try charset([(Array("报告/中文文件.txt".utf8), false), (Array("a.txt".utf8), false)]) == .utf8)
  }

  /// Windows 打的包：GBK 字节、不标志
  @Test func unflaggedGBK() throws {
    #expect(try charset([(Array("readme.txt".utf8), false), (gbkName, false)]) == .gb18030)
  }

  @Test func asciiOnlyAndEmpty() throws {
    #expect(try charset([(Array("a/b.txt".utf8), false)]) == .utf8)
    #expect(try charset([]) == .utf8)
  }

  @Test func notAZip() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "kittybox-\(UUID()).zip")
    try Data("hello".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(!ZipNames.isZip(url))
    #expect(ZipNames.charset(of: url) == nil)
  }

  /// 坏的 / 恶意的 ZIP64：中央目录的位置是 UInt64.max，加上大小会溢出，以前整个 App 崩掉；现在读不出、按 nil 处理
  @Test func zip64OverflowIsRejected() throws {
    func le(_ value: UInt64, _ count: Int) -> [UInt8] {
      (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }
    let head: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 60)
    let record =
      le(0x0606_4B50, 4) + le(44, 8) + le(45, 2) + le(45, 2) + le(0, 4) + le(0, 4) + le(1, 8)
      + le(1, 8) + le(0x10, 8) + le(.max, 8)
    let locator = le(0x0706_4B50, 4) + le(0, 4) + le(UInt64(head.count), 8) + le(1, 4)
    let end =
      le(0x0605_4B50, 4) + le(0, 4) + le(0xFFFF, 2) + le(0xFFFF, 2) + le(0xFFFF_FFFF, 4)
      + le(0xFFFF_FFFF, 4) + le(0, 2)
    let url = FileManager.default.temporaryDirectory.appending(path: "kittybox-\(UUID()).zip")
    try Data(head + record + locator + end).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(ZipNames.isZip(url))
    #expect(ZipNames.entries(of: url) == nil)
  }

  /// 结尾记录后面跟着注释时，也要从后往前找到它
  @Test func archiveComment() throws {
    var data = zipData([(gbkName, false)])
    let comment = Data(repeating: 0x41, count: 300)
    data.replaceSubrange(data.count - 2..<data.count, with: [UInt8(300 & 0xFF), UInt8(300 >> 8)])
    data.append(comment)
    let url = FileManager.default.temporaryDirectory.appending(path: "kittybox-\(UUID()).zip")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(ZipNames.charset(of: url) == .gb18030)
  }
}
