# Kitty Box 方案

把常用的文件处理放在一个原生 App 里：打包、解压、图片转换、去水印（Gemini 角标、任意框选擦除、视频固定台标）。
结构照 Kitty Tools（`~/Desktop/yy/Codes/Tauri/kitty-tools-macos/macos`，`macos` 分支）：规矩以它的 `.cursor/rules/mac-native.mdc` 为底，下面只写 Kitty Box 自己的取舍。

**状态：2026-10-30 拍板，31 项「全部按推荐」**。拍板页 https://claude.ai/artifact/HtJqQ4iFqqpFnS1ZoZ5Gxw（本地 `macos/build/research/plan-2026-10-30/decisions.html`，不入库）。M0 骨架已做，进度见 §5。

## 1. 技术栈

- Swift 6 语言模式，默认 `MainActor` + approachable concurrency；`@concurrent` 只给重活：解压 / 打包的子进程等待、图片编解码、模型推理、视频导出。
- macOS 15.0，`ARCHS = arm64`；Xcode 工程，构建设置全在 `Config/*.xcconfig`，pbxproj 的 target / project 层保持为空。
- Apple 框架：SwiftUI、AppKit、ImageIO、Core Image（含一个 Metal CI kernel）、Core ML、AVFoundation、UniformTypeIdentifiers。
- 系统命令（经 `Shell/Subprocess.swift`，进程外）：`/usr/bin/tar`（bsdtar 3.5 / libarchive 3.7）。
- **第三方：只有一个例外 `7zz`**（2026-10-30 拍板）。另有两份随包的数据文件，都不是代码依赖：LaMa 模型和 Gemini alpha 图。不建 SPM 包，不链接第三方库。

| 随包的东西 | 版本 / 来源 | 许可 | 怎么进包 |
|---|---|---|---|
| `7zz` | 7-Zip 26.05，`github.com/ip7z/7zip/releases/download/26.05/7z2605-mac.tar.xz`，SHA256 `12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570`（与 GitHub release 的 digest 一致） | LGPL-2.1 + unRAR 限制 | 不入库（E3）：`fetch-vendor.sh` 按 SHA256 拉下来，原包是 universal、没签名，脚本里 `lipo -thin arm64` 后放到被忽略的 `Vendor/7zz`；Copy Files 到 Executables 并勾 Code Sign On Copy；`7zz-License.txt` 进 Resources |
| LaMa Core ML 模型 | Hugging Face 上 CoreMLaMa 转好的 800×800 版，M4 动手前选定一份并固定 SHA256 | Apache-2.0 | 约 100 MB，不入库：同一个 `fetch-vendor.sh` 拉，`build-dmg.sh` 打包前检查 |
| Gemini alpha 图 | GargantuaX/gemini-watermark-remover 的 `src/assets/bg_48.png`、`bg_96.png`、`bg_96_20260520.png`，固定到某个 commit | MIT | 入库进 Resources，附 `gemini-alpha-LICENSE.txt` |

## 2. 各功能的做法

### 解压
- **zip 一律交给 bsdtar，其它格式交给 7zz**（2026-10-30 实测）：
  - 7zz 26.05 的 macOS 版解 Windows 打的 GBK 文件名 zip，会把名字弄坏并且丢字节（`报告/中文文件.txt` 变成 `/ļ.txt`），`-mcp=936` 不起作用；
  - bsdtar 加 `--options hdrcharset=GBK` 能解对。它也能用 `--passphrase` 解 AES-256 和 ZipCrypto 两种带密码的 zip。
- **编码判断**：`Archive/ZipNames.swift` 自己读 zip 中央目录（纯函数，单测锁住）。
  - 有 UTF-8 标志、或文件名字节本身是合法 UTF-8 的条目，按 UTF-8；
  - 没有标志、又不是合法 UTF-8 的，按 GBK；
  - 每次都把 `hdrcharset` 显式传给 bsdtar，不依赖子进程的 locale。
  - 不能一律按 GBK：系统 `ditto` 和访达打的 zip 写的是 UTF-8 字节，却不标 UTF-8 标志，实测如此。
- 7z / rar / rar5 / tar.* / iso 等交给 7zz，带密码的 7z（包括连文件名也加密的）和 RAR 都能解。
- 密码错误时弹窗重新输入，不留记录。
- 解到压缩包旁边、与压缩包同名的文件夹里；如果包里只有一个顶层文件夹，就不再多套一层。

### 打包
- 用 7zz，只出 zip 和 7z 两种格式，默认 zip：
  - zip：中文名会自动带 UTF-8 标志（已实测），7-Zip、WinRAR 都能正确显示；Windows 自带解压认不认这个标志，微软没有写明，M1 要在真 Windows 上试；
  - 7z：设密码时加 `-mhe=on`，连文件名一起加密。
- tar.gz 第一版不做。

#### 发给 Windows（B10、B11）
- **能不能开**（调研结果）：
  - 不带密码的 zip：Windows 自带解压能开；
  - 带密码的 zip：只有老式 ZipCrypto 自带能开，AES-256 的打不开；
  - 7z：Windows 11（2023-10 起，底层是 libarchive）自带能开不带密码的；Windows 10 要装软件；带密码的 7z 自带都打不开。
- **zip 的密码**：默认 AES-256。设了密码时，面板里多一个开关「让 Windows 自带解压也能打开」，打开后改用 ZipCrypto（`-mem=ZipCrypto`），并写明它容易被破解、重要的东西用 7z。开关状态存在偏好里。
- **Windows 不认的文件名**：`Archive/WindowsNames.swift` 是纯函数。检查三种情况：名字带 `\ : * ? " < > |`；结尾是空格或点；是 CON、PRN、AUX、NUL、COM1–9、LPT1–9 这类保留名。打包前在面板底部列出哪些文件有问题、为什么，不拦着打包，也不自动改名。

#### 忽略清单（B3–B6）
- **系统杂文件，默认勾上**：`.DS_Store`、`._*`、`__MACOSX`、`.Spotlight-V100`、`.Trashes`、`.fseventsd`、`.TemporaryItems`、`Icon␍`、`Thumbs.db`、`desktop.ini`、`$RECYCLE.BIN`。
- **开发目录，列着但默认不勾**（一键全勾）：`.git`、`.svn`、`node_modules`、`.venv`、`__pycache__`、`.idea`、`.vscode`。
- **自己加的规则**：按名字写通配符，可以用 `*` 和 `?`，路径里任意一层都算；以 `/` 结尾的只匹配文件夹；中间带 `/` 的不收。
- **存法**：一份全局清单，存在偏好里。打包面板和设置里都能勾、加、删，改了就记住。
- **一套匹配，看到的就是打进去的**：`Archive/IgnoreRules.swift` 是纯函数，单测锁住。打包时自己遍历文件夹，用它筛一遍，把剩下的清单通过 `@listfile` 交给 7zz，不用 7zz 自己的 `-xr!`，免得两套匹配对不上。面板底部写「打包 N 个，忽略 M 个」，点开能看到忽略了哪些、各是哪条规则排掉的。
- **解压时也跳过**：`__MACOSX`、`._*`、`.DS_Store`（B7）。

### 图片转换
- 只用 ImageIO：
  - 读取（本机实测）：HEIC、WebP、AVIF、JXL、RAW、PSD、ICO 等；
  - 写出：JPEG、PNG、HEIC、AVIF、TIFF、GIF、BMP、ICO、ICNS、PDF。
- 支持批量转换和质量滑块。
- 不支持 WebP 输出（系统不能写 WebP）。

### Gemini 角标
- 把反向 alpha 混合算法移植成 Swift：`原图 = (水印图 − α·255) / (1 − α)`。α 取 alpha 图每个像素 RGB 三个通道的最大值除以 255；去噪底 3/255，α 上限 0.99。
- 候选位置（logo 尺寸 / 右下边距）：48/32、96/64、96/192（用 20260520 版的 alpha 图）、48/96。逐个计算该区域灰度和 alpha 图的归一化互相关，取分数最高、并且超过阈值的那个。
- 没有候选超过阈值时，提示“没认出来”，并提供用框选擦除处理右下角。
- 上游的候选筛选、残影修补、FDnCNN 降噪都不移植（`ponytail:`）。Gemini 出了新版本，就从上游同步 alpha 图和候选位置，比如 36px 的 v2 版本。

### 框选擦除
- 画笔涂出遮罩，支持撤销。
- 模型输入固定为 800×800。在遮罩外接框四周加一圈边距，裁成正方形，缩放到 800，推理后再缩放回原尺寸，只把遮罩里的像素贴回原图，所以原图分辨率不变。
- 推理用 `@concurrent`，计算单元交给 Core ML 自己选。

### 视频固定台标
- 在第一帧（`AVAssetImageGenerator`）上拖出一个框。
- 导出：`AVVideoComposition(asset:applyingCIFiltersWithHandler:)` 逐帧处理，交给 `AVAssetExportSession`；音频直接带过。
- 填补框内像素用一个自写的 Metal CI kernel `Delogo.ci.metal`，思路和 ffmpeg delogo 一样：每个像素按到上下左右四条边的距离，对边上的像素加权插值，边缘做羽化。只照思路自己写，不拷 ffmpeg 的代码。
- xcconfig 加 `MTL_COMPILER_FLAGS = -fcikernel` 和 `MTLLINKER_FLAGS = -cikernel`。

## 3. 架构与文件表

一个 App target `KittyBox`，加一个测试 target `KittyBoxTests`。

**仓库照 Kitty Tools 分（A3）**：
- `macos` 分支：mac 版，工程在 `macos/` 下，下表的路径都相对 `macos/KittyBox/`，tag 用 `macos-v*`；
- `windows` 分支：以后的 Windows 版，放在 `windows/` 下；
- `main`：默认分支，只放 README 和截图。
**和 Kitty Tools 的唯一区别：不是只在菜单栏显示（不设 `LSUIElement`）**，Kitty Box 是普通窗口 App，文件可以拖到程序坞图标或窗口上。

| 目录 | 文件 |
|---|---|
| `App/` | `KittyBoxApp.swift`（`@main`，主窗口）、`AppDelegate.swift`（`application(_:open:)`：拖到程序坞图标上的文件按类型分给对应工具） |
| `Shell/` | `HomeView.swift`（四格首页，照 Kitty Tools 的 HomePanel；拖放区 M1 加）、`Style.swift`（从 Kitty Tools 的同名文件摘出用得上的刻度，加四个工具的家族色）。M1 再拷 `Subprocess.swift`。强调色跟随系统（`AccentColor.colorset` 是品牌粉），没有设置页，不拷 `Accent.swift` |
| `Archive/` | `ZipNames.swift`（中央目录读取和编码判断）、`IgnoreRules.swift`（忽略规则匹配）、`WindowsNames.swift`（Windows 不认的文件名）、`Archiver.swift`（选引擎、拼参数、跑子进程、密码重试）、`ArchiveView.swift` |
| `ImageConvert/` | `ImageConverter.swift`、`ImageConvertView.swift` |
| `Watermark/` | `GeminiMark.swift`、`Inpainter.swift`、`EraseCanvas.swift`、`VideoDelogo.swift`、`Delogo.ci.metal`、`WatermarkView.swift` |
| `Resources/` | `Assets.xcassets`（小猫图标）、`changelog.json`、Gemini alpha 图和各份 LICENSE |
| `macos/` | `Config/{Base,Debug,Release}.xcconfig`（`Tests.xcconfig` M1 加）、`build-dmg.sh`、`fetch-vendor.sh`（拉 7zz 和模型到被忽略的 `Vendor/`，7zz 的许可证写到 `Resources/7zz-LICENSE.txt` 入库）、`brand-icons.swift`（同一只小黑猫扒着纸箱，青绿底板） |
| 仓库根目录 | `AGENTS.md`、`CLAUDE.md`、`.cursor/rules/box-native.mdc`、`.gitignore` |

- 一个概念一个文件，不预建空目录。
- 应用内更新（`Updater.swift`）和关于页，等第一次发版时再从 Kitty Tools 拷过来。

**单测**（Swift Testing，不写真实偏好）：
- `ZipNamesTests`：三种 zip 的字节夹具——有 UTF-8 标志、没标志但写的是 UTF-8、没标志写的是 GBK；
- `IgnoreRulesTests`：通配符、任意层级、`/` 结尾只认文件夹、中间带 `/` 的拒收；
- `WindowsNamesTests`：非法字符、结尾空格或点、保留名，以及全角符号（比如「：」）不算问题；
- `GeminiMarkTests`：在已知图片上合成水印，去掉后每个像素误差不超过 2，并且能选对候选位置；
- `ArchiverTests`：在临时目录里各跑一遍往返：zip 和 7z、带密码和不带密码、GBK zip；
- `ImageConverterTests`：各种输出格式往返转换一遍；
- 界面用 SnapshotProbeTests 做屏外截图检查，等 M1 有界面后再建。

## 4. 签名与打包

- Apple Development，`DEVELOPMENT_TEAM = HTX9F4KG39`，开 Hardened Runtime，不开沙盒，不公证，不用 adhoc 签名。
- Bundle ID：`com.yy.kitty-box`，Debug 版是 `com.yy.kitty-box.dev`；产品名：`Kitty Box`，Debug 版是 `Kitty Box Dev`。
- 版本号只在 `Base.xcconfig` 的 `MARKETING_VERSION` 里改，同时要在 `changelog.json` 加一条，否则 `build-dmg.sh` 会中止。
- `build-dmg.sh` 照搬 Kitty Tools 的路径 B，另外加两项检查：
  - `codesign -d -r-` 看 `7zz` 是用本团队证书签的；
  - LaMa 模型在，并且 SHA256 对得上。
- 预计包体：7zz 约 3 MB + LaMa 约 100 MB + 其余几 MB。

## 5. 里程碑

- **M0 骨架**（2026-10-30 做完）：`git init -b macos`；Xcode 工程（同步文件夹）和 xcconfig；`Style.swift`；小猫纸箱图标和 DMG 背景；`build-dmg.sh`、`fetch-vendor.sh`；AGENTS / CLAUDE / 规则文档；四格首页（点进去是「还没做好」）。测试 target 等 M1 有第一个单测时加。
- **M1 打包 / 解压**：`ZipNames` → `IgnoreRules` → `WindowsNames` → `Archiver` → 界面，单测先行。最后请你在 Windows 上双击打开几个包试一下：中文名的 zip、ZipCrypto 加密的、AES 加密的、7z。如果中文名乱码，再加「给中文 Windows 写 GBK 文件名」这一项。
- **M2 图片转换**。
- **M3 Gemini 角标 + 视频台标**。
- **M4 框选擦除**：选定模型并写进 `fetch-vendor.sh` → 推理和裁剪贴回 → 画笔界面。

## 6. 第一版不做

Windows 版（见 §8）、专给中文 Windows 写 GBK 文件名的 zip（等 M1 真机结果）、WebP 输出、tar.gz 打包、RAR 压缩（没有免费工具能做）、Finder 右键菜单、PDF / 音视频转换、Gemini 的降噪和残影修补。

## 7. 风险

- 不开沙盒，但 TCC 照样保护桌面、文稿、下载：第一次往这些文件夹写结果时，系统会弹窗问一次授权。
- Gemini 的位置规则一直在变（上游在 2026-05、06、08 都加过新变体），认不出来时要能退回到框选擦除。
- 7zz 和 bsdtar 的输出格式不是稳定接口：`Archiver` 只看退出码和少数几个固定的错误字样，比如 `Wrong password`。

## 8. 以后的 Windows 版（A6）

- 照 Kitty Tools，用 C# + WinUI 3 另写一套，放在 `windows` 分支。差异记在 `windows/MAC-DIFF.md`，开工时另起一张拍板页。
- **这份 PLAN 是行为的唯一来源。** 下面这些两边要一字不差：忽略清单的默认值和规则写法、结果文件的命名（`名字 2`、`-去水印`）、解压时跳过的杂文件。
- 各平台用自己的系统能力（待 Windows 版拍板时确认）：
  - 解压同样带 7-Zip（官方有 Windows 版）；
  - 图片用 WIC；
  - 模型用系统自带的 Windows ML 跑 ONNX 版 LaMa；
  - 视频用 Media Foundation。
- 中文 Windows 的默认代码页就是 936，7-Zip 解没标 UTF-8 的 zip 时自然按 GBK 处理，mac 这边的编码判断在 Windows 上用不着。
