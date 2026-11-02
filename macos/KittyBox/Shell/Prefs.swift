// 偏好的键名都在这里（照 Kitty Tools 的 Prefs.swift），别的地方不写字符串字面量的键。

enum Prefs {
  /// 忽略清单（IgnoreList）：关掉的系统项和自己加的项、勾上的开发目录、自己加的规则
  static let ignoreOff = "ignoreOff"
  static let ignoreDeveloperOn = "ignoreDeveloperOn"
  static let ignoreCustom = "ignoreCustom"
  /// 打包：上次选的格式、「让 Windows 自带解压也能打开」（B10）
  static let packFormat = "packFormat"
  static let packWindowsCompatible = "packWindowsCompatible"
  /// 主窗口侧边栏上次选的工具（Tool.rawValue）
  static let lastTool = "lastTool"
  /// 图片转换：上次选的格式和质量
  static let convertFormat = "convertFormat"
  static let convertQuality = "convertQuality"
  /// 图片转换：长边上限（0 = 原尺寸）、去不去定位
  static let convertMaxSide = "convertMaxSide"
  static let convertStripLocation = "convertStripLocation"
  /// 视频转换：转成什么、缩到多大
  static let videoTarget = "videoTarget"
  static let videoSize = "videoSize"
  /// 补图用哪个模型（AIModel.rawValue）：画笔擦除、AI 水印
  static let inpaintModel = "inpaintModel"
  /// 设置 › 通用：自动检查更新、做完时程序坞图标跳一下、外观（跟随系统 / 浅色 / 深色）
  static let autoCheckUpdates = "autoCheckUpdates"
  static let bounceWhenDone = "bounceWhenDone"
  static let appearance = "appearance"
  /// 去背景：背景、裁不裁、用哪种抠法（Cutout.Engine）、保留文字
  static let cutoutBackground = "cutoutBackground"
  static let cutoutCrop = "cutoutCrop"
  static let cutoutEngine = "cutoutEngine"
  static let cutoutKeepText = "cutoutKeepText"
  /// AI 水印：也去掉这些字（用户自己加的，逗号隔开）
  static let aiMarkWords = "aiMarkWords"
  /// 打包：压缩级别（Archiver.Level）
  static let packLevel = "packLevel"
  /// 解压：解完把压缩包移到废纸篓
  static let unpackTrashArchive = "unpackTrashArchive"
  /// 访达右键「用 X 打开」的 App（bundle id，按加进来的顺序）；访达扩展读同一个键（FinderMenu.openWithApps）
  static let openWithApps = "openWithApps"
}
