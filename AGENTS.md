# AGENTS.md

`macos` 分支（mac 原生版主线）的 agent 项目指引（Cursor / Codex 直接读；Claude Code 经 `CLAUDE.md` 导入）。常驻红线在 `.cursor/rules/box-native.mdc`。

## 项目概述

**Kitty Box**：纯原生 macOS 文件工具箱，Kitty 家族的一员（结构照 Kitty Tools：`~/Desktop/yy/Codes/Tauri/kitty-tools-macos`，`macos` 分支）。基本自用，只支持 Apple 芯片（arm64），最低 macOS 15.0。

- **功能**（第一版）：打包（zip / 7z，忽略清单）、解压（GBK 文件名不乱码，带密码的 zip / 7z / RAR）、图片转换（ImageIO）、去水印（Gemini 角标、画笔擦除、视频台标）。
- **形态**：普通窗口 App（有程序坞图标，文件能拖上去），左边侧边栏列出工具（压缩 / 图片 / 去水印，品牌粉选中），右边是工具页（页头带操作和品牌粉主按钮 + 表格 + 右边一栏选项卡片 + 底下状态栏，照 Kitty Tools 设置窗），见 PLAN §2「界面」。
- **方案**：`macos/PLAN.md` 是行为和做法的唯一来源；2026-10-30 拍板页 https://claude.ai/artifact/HtJqQ4iFqqpFnS1ZoZ5Gxw（31 项，「全部按推荐」），本地副本 `macos/build/research/plan-2026-10-30/decisions.html`（不入库）。
- **进度**：分批做，一批一个提交，见 PLAN §5。
- **Windows 版**：以后照 Kitty Tools 另写一套（C# + WinUI 3），放 `windows` 分支，差异记 `windows/MAC-DIFF.md`；`main` 只放 README 和截图。
- Bundle ID `com.yy.kitty-box`（Debug `com.yy.kitty-box.dev`），不再改；产品名 `Kitty Box`（Debug `Kitty Box Dev`）。

## 技术栈

- Swift 6 语言模式，默认 `MainActor` 隔离 + approachable concurrency。
- SwiftUI + AppKit；ImageIO、Core Image、Core ML、AVFoundation。
- 系统命令：`/usr/bin/tar`（zip 解压）。
- 第三方：只有随包的 `7zz`（7-Zip 26.05，`fetch-vendor.sh` 按 SHA256 拉，不入库）；数据文件：Gemini α 图（随包）、LaMa 模型（不随包，画笔擦除第一次用时下载到 Application Support，`Watermark/LaMaModel.swift`）。
- Xcode 27 工程，构建设置全在 xcconfig；`hdiutil` 打 DMG；Apple Development 签名（Team `HTX9F4KG39`），不公证。

## 目录结构

```
macos/
├── KittyBox.xcodeproj/      # 共享 scheme：KittyBox；KittyBox/ 是同步文件夹
├── KittyBox/                # App/ Shell/ Resources/（以后 Archive/ ImageConvert/ Watermark/，见 PLAN §3）
├── Config/                  # Base / Debug / Release.xcconfig、Info.plist（局部）、dmg-background.tiff
├── Vendor/                  # fetch-vendor.sh 拉下来的 7zz（不入库）
├── fetch-vendor.sh          # 拉 7zz，按 SHA256 校验（LaMa 模型 App 用时自己下）
├── build-dmg.sh             # 打包：archive → 自检 → DMG + 更新用 zip → notes
├── brand-icons.swift        # 品牌图标（小黑猫扒着纸箱）+ DMG 背景
├── .swift-format
└── PLAN.md
.cursor/rules/box-native.mdc # 常驻红线
```

一个概念一个文件，不预建空目录。

## 常用命令（仓库根目录执行）

```bash
# 第一次构建前：拉 7zz
macos/fetch-vendor.sh

# 构建
xcodebuild -project macos/KittyBox.xcodeproj -scheme KittyBox build

# 格式：lint 无输出才算通过；format 就地改写
xcrun swift-format lint --strict -r macos/KittyBox
xcrun swift-format format -i -r macos/KittyBox

# 签名自检：输出要含 anchor apple generic 和 bundle id，不能是 cdhash
codesign -d -r- "<App 路径>"

# 改了图标或产品名
swift macos/brand-icons.swift

# 打包（要先在 changelog.json 里加本版条目）
macos/build-dmg.sh
```
