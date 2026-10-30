<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Kitty Box 图标">
</p>

<h1 align="center">Kitty Box</h1>

<p align="center">
  纯原生的文件工具箱：打包 · 解压 · 图片转换 · 去水印
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-000?logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/%E9%9A%8F%E5%8C%85%E7%AC%AC%E4%B8%89%E6%96%B9-7--Zip-E8577A" alt="随包第三方：7-Zip">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
</p>

把常用的文件处理放进一个原生窗口：文件拖到程序坞图标或窗口上，选一个工具就处理好，结果另存在原文件旁边，不碰原文件。macOS 版用 Swift 6 + SwiftUI / AppKit 写成，除了随包的 7-Zip，只用系统自带的能力。

> 个人项目，**还在开发中，暂时没有可下载的版本**。只支持 Apple 芯片、macOS 15 及以上。以后会再写一套 Windows 版。

## 分支

`main` 只放这份介绍，代码按平台分在各自的分支里：

| 分支 | 内容 | 发布 |
|---|---|---|
| [`macos`](https://github.com/YyAdnBug/kitty-box/tree/macos) | macOS 版（Swift 6 + SwiftUI / AppKit） | tag `macos-v*` |
| `windows` | Windows 版，以后再建 | — |

## 第一版要做的

### 📦 打包

- 打成 zip 或 7z，可以设密码；7z 设了密码连文件名也一起加密
- **忽略清单**：默认去掉 `.DS_Store`、`._*`、`__MACOSX`、`Thumbs.db` 这类系统杂文件；`.git`、`node_modules` 等开发目录一键勾上；也能自己加规则（`*.log`、`草稿/`）。打包前会显示忽略了哪些
- 照顾 Windows：提示哪些文件名 Windows 不认；带密码的 zip 可以选成 Windows 自带解压也能打开的方式

### 🗂️ 解压

- zip、7z、RAR、tar、iso 等，带密码的 zip / 7z / RAR 都能解
- **Windows 打的 zip 中文文件名不乱码**：自己判断文件名是 GBK 还是 UTF-8
- 解到压缩包旁边的同名文件夹；包里只有一个文件夹时不再多套一层；`__MACOSX`、`._*` 不解出来

### 🖼️ 图片转换

- HEIC、WebP、AVIF、JXL、RAW、PSD 等都能读，转成 JPEG、PNG、HEIC、AVIF、TIFF、GIF、BMP、ICO、ICNS、PDF
- 批量转换，可以调质量；照片里的拍摄信息原样保留

### 🧽 去水印

- **Gemini 角标**：用反向 alpha 混合把 Gemini 生成图右下角的标志还原掉，不靠 AI 猜
- **画笔擦除**：涂哪擦哪，本机的 LaMa 模型补全，原图分辨率不变
- **视频台标**：在第一帧上框出台标位置，逐帧补掉，可以框好几处

## 从源码构建

代码在 `macos` 分支，需要 Xcode 27 和 Apple 芯片的 Mac。

```bash
git clone -b macos https://github.com/YyAdnBug/kitty-box.git
cd kitty-box
macos/fetch-vendor.sh   # 按 SHA256 下载随包的 7zz
xcodebuild -project macos/KittyBox.xcodeproj -scheme KittyBox build
```

- **签名**：`macos/Config/Base.xcconfig` 里的 `DEVELOPMENT_TEAM` 改成你自己的 Team ID。
- 开发约定见 `macos` 分支的 [AGENTS.md](https://github.com/YyAdnBug/kitty-box/blob/macos/AGENTS.md)，方案见 [macos/PLAN.md](https://github.com/YyAdnBug/kitty-box/blob/macos/macos/PLAN.md)。

## 致谢

- 打包和解压 7z、RAR 用的是 [7-Zip](https://github.com/ip7z/7zip)（LGPL 2.1，随包分发，见 `macos` 分支的 [NOTICE.md](https://github.com/YyAdnBug/kitty-box/blob/macos/NOTICE.md)）
- Gemini 去水印的算法参考了 [GargantuaX/gemini-watermark-remover](https://github.com/GargantuaX/gemini-watermark-remover) 和 [allenk/GeminiWatermarkTool](https://github.com/allenk/GeminiWatermarkTool)（都是 MIT）
- 画笔擦除用的是 [LaMa](https://github.com/advimman/lama) 转成 Core ML 的模型（Apache-2.0）

## 许可证

[MIT](LICENSE)
