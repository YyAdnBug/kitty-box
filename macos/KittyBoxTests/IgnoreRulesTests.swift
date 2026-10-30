// IgnoreRules / IgnoreList：通配符、任意层级、/ 结尾只认文件夹、不分大小写、加规则前的检查、清单的默认值和记住。

import Foundation
import Testing

@testable import KittyBox

struct IgnoreRulesTests {
  private let rules = IgnoreRules([
    ".DS_Store", "._*", "*.log", "草稿/", "node_modules", "IMG_??.heic",
  ])

  @Test func anyLevel() {
    #expect(rules.match(".DS_Store", isDirectory: false) == ".DS_Store")
    #expect(rules.match("相册/照片/.DS_Store", isDirectory: false) == ".DS_Store")
    #expect(rules.match("网站/node_modules/react/index.js", isDirectory: false) == "node_modules")
    #expect(rules.match("相册/封面.heic", isDirectory: false) == nil)
  }

  @Test func wildcards() {
    #expect(rules.match("._封面.heic", isDirectory: false) == "._*")
    #expect(rules.match("网站/debug.log", isDirectory: false) == "*.log")
    #expect(rules.match("debug.log.txt", isDirectory: false) == nil)
    #expect(rules.match("IMG_01.heic", isDirectory: false) == "IMG_??.heic")
    #expect(rules.match("IMG_001.heic", isDirectory: false) == nil)
    // * 不跨层
    #expect(IgnoreRules(["a*b"]).match("a/b", isDirectory: false) == nil)
  }

  @Test func foldersOnly() {
    #expect(rules.match("网站/草稿", isDirectory: true) == "草稿/")
    #expect(rules.match("网站/草稿/想法.md", isDirectory: false) == "草稿/")
    #expect(rules.match("网站/草稿", isDirectory: false) == nil)
  }

  @Test func caseAndNormalization() {
    #expect(rules.match("thumbs/.ds_store", isDirectory: false) == ".DS_Store")
    // 访达给的名字常是分解形式：é = e + ́
    #expect(IgnoreRules(["café"]).match("cafe\u{301}", isDirectory: false) == "café")
  }

  @Test func problems() {
    #expect(IgnoreRules.problem(with: "", existing: []) != nil)
    #expect(IgnoreRules.problem(with: "/", existing: []) != nil)
    #expect(IgnoreRules.problem(with: "网站/草稿", existing: []) != nil)
    #expect(IgnoreRules.problem(with: ".ds_store", existing: [".DS_Store"]) != nil)
    #expect(IgnoreRules.problem(with: "草稿/", existing: []) == nil)
    #expect(IgnoreRules.problem(with: "*.log", existing: []) == nil)
  }

  @Test func listDefaultsAndMemory() throws {
    let suite = "kittybox-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let list = IgnoreList(defaults: defaults)
    #expect(list.isOn(".DS_Store"))
    #expect(!list.isOn("node_modules"))
    #expect(list.rules.match("a/.DS_Store", isDirectory: false) != nil)
    #expect(list.rules.match("a/node_modules", isDirectory: true) == nil)

    list.set("node_modules", on: true)
    list.set(".DS_Store", on: false)
    #expect(list.add("*.log") == nil)
    #expect(list.add("*.LOG") != nil)
    #expect(list.add("a/b") != nil)

    let again = IgnoreList(defaults: defaults)
    #expect(again.isOn("node_modules"))
    #expect(!again.isOn(".DS_Store"))
    #expect(again.custom == ["*.log"])
    #expect(again.rules.match("x/debug.log", isDirectory: false) == "*.log")

    again.set("*.log", on: false)
    #expect(again.rules.match("x/debug.log", isDirectory: false) == nil)
    again.remove("*.log")
    #expect(again.custom.isEmpty)
    #expect(!again.off.contains("*.log"))
  }
}
