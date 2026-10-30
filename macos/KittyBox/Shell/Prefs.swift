// 偏好的键名都在这里（照 Kitty Tools 的 Prefs.swift），别的地方不写字符串字面量的键。

enum Prefs {
  /// 忽略清单（IgnoreList）：关掉的系统项和自己加的项、勾上的开发目录、自己加的规则
  static let ignoreOff = "ignoreOff"
  static let ignoreDeveloperOn = "ignoreDeveloperOn"
  static let ignoreCustom = "ignoreCustom"
  /// 打包：上次选的格式、「让 Windows 自带解压也能打开」（B10）
  static let packFormat = "packFormat"
  static let packWindowsCompatible = "packWindowsCompatible"
}
