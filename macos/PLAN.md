# Kitty Box 方案

把常用的文件处理放在一个原生 App 里：打包、解压、图片转换、去水印（Gemini 角标、任意框选擦除、视频固定台标）。
结构照 Kitty Tools（`~/Desktop/yy/Codes/Tauri/kitty-tools-macos/macos`，`macos` 分支）：规矩以它的 `.cursor/rules/mac-native.mdc` 为底，下面只写 Kitty Box 自己的取舍。

**状态：2026-10-30 拍板，31 项「全部按推荐」**。拍板页 https://claude.ai/artifact/HtJqQ4iFqqpFnS1ZoZ5Gxw（本地 `macos/build/research/plan-2026-10-30/decisions.html`，不入库）。M0 骨架已做，进度见 §5。

## 1. 技术栈

- Swift 6 语言模式，默认 `MainActor` + approachable concurrency；`@concurrent` 只给重活：解压 / 打包的子进程等待、图片编解码、模型推理、视频导出。
- macOS 15.0，`ARCHS = arm64`；Xcode 工程，构建设置全在 `Config/*.xcconfig`，pbxproj 的 target / project 层保持为空。
- Apple 框架：SwiftUI、AppKit、ImageIO、Core Image、Core ML、AVFoundation、UniformTypeIdentifiers。不写 Metal：Xcode 26 起 Metal 工具链要单独下载，每台编译的机器都得装（M3 实测）。
- 系统命令（经 `Shell/Subprocess.swift`，进程外）：`/usr/bin/tar`（bsdtar 3.5 / libarchive 3.7）。
- **第三方：只有一个例外 `7zz`**（2026-10-30 拍板）。另有两份随包的数据文件，都不是代码依赖：LaMa 模型和 Gemini alpha 图。不建 SPM 包，不链接第三方库。

| 随包的东西 | 版本 / 来源 | 许可 | 怎么进包 |
|---|---|---|---|
| `7zz` | 7-Zip 26.05，`github.com/ip7z/7zip/releases/download/26.05/7z2605-mac.tar.xz`，SHA256 `12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570`（与 GitHub release 的 digest 一致） | LGPL-2.1 + unRAR 限制 | 不入库（E3）：`fetch-vendor.sh` 按 SHA256 拉下来，原包是 universal、没签名，脚本里 `lipo -thin arm64` 后放到被忽略的 `Vendor/7zz`；Copy Files 到 Executables 并勾 Code Sign On Copy；`7zz-License.txt` 进 Resources |
| LaMa Core ML 模型（**不随包**） | Hugging Face `mlboydaisuke/LaMa-CoreML` 的 revision `5ed76e3`（FP32，输入 800×800 的 BGRA 图 + 8 位灰度遮罩）；Manifest.json / model.mlmodel / weight.bin 三个文件各自固定 SHA256，写在 `Watermark/LaMaModel.swift` | Apache-2.0 | 下载约 216 MB。2026-10-30 用户改成「用时下载」：画笔擦除第一次用时 App 自己下载、校验、`MLModel.compileModel` 编译，放进 `~/Library/Application Support/Kitty Box/Models/LaMa.mlmodelc`（正式版和开发版共用）；许可证全文 `Resources/lama-LICENSE.txt` 入库 |
| Gemini α 图 | GargantuaX/gemini-watermark-remover commit `ddd67a7` 的 `src/core/embeddedAlphaMaps.js` 里内嵌的 4 张（36-v2、48、96、96-20260520），原样解成 Float32 小端 | MIT | 入库：`Resources/gemini-alpha-*.bin`（共约 88 KB），附 `gemini-watermark-LICENSE.txt` |

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
- 7z / rar / rar5 / iso 等交给 7zz，带密码的 7z（包括连文件名也加密的）和 RAR 都能解。tar 一族（.tar、.tar.gz、.tgz 等）也交给系统 tar：7zz 解 .tar.gz 只解出一层 .tar。
- 有密码时在解压页那一行里就地问，错了说「密码不对」再问，不留记录。
- **没给密码也要传一个占位的**（2026-10-30 实测）：tar 不给 `--passphrase` 会对着空的标准输入连问上万次，给空字符串它拒收；7zz 不给 `-p` 会卡在问密码。不加密的包会忽略它。按报错里的 `Incorrect passphrase`（tar）/ `Wrong password`（7zz）分出「要密码」和「密码不对」。
- 解到压缩包旁边、与压缩包同名的文件夹里；如果包里只有一样东西（文件夹或文件），就直接放出来，不再多套一层（比 B8 多了「单个文件」：`报告.docx.zip` 解出 `报告.docx`，同访达）。重名加「 2」。
- 先解到旁边一个隐藏的临时文件夹（`.<名字> 解压中`），去掉杂文件、做完再挪成正式名字；失败时删掉，不留半截。
- **隔离标记跟着走**：包带着「从网上下载」的隔离标记时，解出来的每样东西都带上（同系统的归档实用工具），不然包里的 App 打开时不会再被检查。

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
- **一套匹配，看到的就是打进去的**：`Archive/IgnoreRules.swift` 是纯函数，单测锁住。打包时自己遍历文件夹，用它筛一遍，把剩下的清单通过 `@listfile` 交给 7zz（在 `plan.base` 下跑，清单里是相对路径；`-snl` 链接存成链接），不用 7zz 自己的 `-xr!`，免得两套匹配对不上。面板底部写「打包 N 个，忽略 M 项」（被排掉的文件夹算一项），点开能看到忽略了哪些、各是哪条规则排掉的。
  - 清单里写文件夹的话，7zz 会把它整个递归打进去，连被忽略的一起（`-r-` 也拦不住，实测）。所以只列本来就空的文件夹；里面只剩被忽略的东西的文件夹不列，它在包里就没了。
  - `._` 开头的附加信息文件，系统遍历文件夹时就跳过了（实测），不进清单，也不出现在「忽略了」里。
  - 匹配不分大小写，名字先统一成合成形式（访达给的常是分解形式）。
- **zip 的密码只能是 ASCII**：7zz 打 zip 时不收中文这类密码（报 `E_INVALIDARG`，实测），7z 没这个限制。打包页当场提示「要用中文密码请选 7z」，按钮不让点。
- **解压时也跳过**：`__MACOSX`、`._*`、`.DS_Store`（B7）。

### 图片转换
- 只用 ImageIO：
  - 读取（本机实测）：HEIC、WebP、AVIF、JXL、RAW、PSD、ICO 等；
  - 写出：JPEG、PNG、HEIC、AVIF、TIFF、GIF、BMP、ICO、ICNS、PDF。
- 支持批量转换（一张一张转）；JPEG、HEIC、AVIF 有质量滑块（默认 85%）。换了格式或质量，转好的那些回到「等着」。
- 结果放在原图旁边、换扩展名，重名加「 2」；拍摄时间、相机、定位这些信息原样带过去（C3）。
- 照片的「旋转方向」标记 PNG、GIF、BMP 这些格式不认：一律按方向转正了再写，标记改成 1。解码走缩略图接口（为了转正），16 位、HDR 会变成 8 位（`ponytail:`）。
- 动图、多页的图转 GIF、TIFF、PDF 时保留每一帧，转别的只取第一帧。
- 2026-10-30 实测：JPEG 自己会把透明处垫成白色；ICO 只收边长 ≤ 256 的正方形、ICNS 只收标准尺寸的正方形，所以这两种先等比放进透明的正方形画布，出几种尺寸（ICO 16/32/48/256，ICNS 16–1024）；PDF 能写不能读。
- 不支持 WebP 输出（系统不能写 WebP）。

### Gemini 角标
- 把反向 alpha 混合算法移植成 Swift（`Watermark/GeminiMark.swift`）：`原图 = (水印图 − α·255) / (1 − α)`。α 用上游内嵌的原始数据；α 先减 3/255 的噪底、剩下不到 0.002 的不动，α 上限 0.99（同上游 blendModes.js）。
- 候选（星标边长 / 右下边距 / α 图），取自上游的 Gemini 尺寸表：48/32/48、96/64/96、96/192/96-20260520、48/96/48、36/96/36-v2、48/89/48（2752×1536）、46/32/96 双线性缩放（1408×768）。
- 判定照上游的「直接认定」：该区域亮度（Rec. 709）和 α 图的归一化互相关 ≥ 0.3 且 Sobel 梯度的互相关 ≥ 0.12（或 ≥ 0.295 且 ≥ 0.45），过了的里头取亮度分最高的。
- 按图本身的色彩空间展开像素，不做色彩转换（换了空间，反解的数就不对了）；结果同格式另存成「原名-去水印」，JPEG 质量 0.95，照片信息带过去。
- 认不出就不出文件，那一行写「没认出 Gemini 角标」；M4 起提供转到画笔擦除。
- 上游的残影修补、FDnCNN 降噪、深色描边变体、多层叠加、自适应搜位置都不移植（`ponytail:`）。Gemini 出了新版本认不出时，从上游同步 α 图和候选位置。
- **还没拿真的 Gemini 图验过**，单测用的是照 Gemini 公式合成的星标。

### 画笔擦除
- **模型选型（M4，2026-10-30 实测）**：比了两份。`Jia-Liu/big-lama-coreml` 只有 95 MB，但实际是半精度，补出来的地方明显偏色；`mlboydaisuke/LaMa-CoreML`（FP32，约 207 MB）几乎看不出来，速度一样。选后者。
- **用时下载（D2 改，2026-10-30 用户拍板）**：模型随包时安装包约 200 MB，用户嫌大，改成画笔擦除第一次用时下载，安装包只剩几 MB。没下时画笔擦除页顶上一条「下载」（带进度），下好之前能涂、不能擦；下载用 App 自己的 URLSession（`Shell/DownloadWatcher` 报进度），三个文件按 SHA256 校验，对不上不装。先从 Hugging Face 下，连不上（比如在国内）或下到一半失败，自动换镜像 hf-mirror.com 从头再下（2026-10-30 实测同一个 revision 的文件哈希一样；反正逐个校验，镜像给错了也装不上）。
- 计算单元只用 CPU + GPU（`.cpuAndGPU`）：800×800 一次约 0.7 s；`.all` 带上神经网络引擎反而 3–4 s，第一次还要先编译将近两分钟。模型第一次用时加载（约 1 s），之后留在 `Inpainter` 这个 actor 里。
- 画笔涂出遮罩（笔画存原图像素坐标，笔刷粗细按屏幕上看着的换算），⌘Z 先撤笔画、再撤上一次擦除；擦完能接着涂；满意了「存成」另存「原名-去水印」（同格式、照片信息带过去、方向转正）。
- 补：遮罩外接框四周留一圈上下文（至少 32，多则框边长的一半），裁一块尽量正方形、至少 256、不出图，拉成 800×800 推理，放大回那块的尺寸，只按遮罩贴回原图，原图分辨率不变。模型自己会把遮罩外原样带过，所以输入不用先清零。
- 贴回用的遮罩边缘按缩放比例羽化（σ = 块宽 / 800 × 3，至少 1.5）：硬边贴回去在真照片上能看出一圈轮廓。涂得很大（块超过 800、要缩小）时补出来的地方少了原图的细颗粒，仔细看仍有一圈很淡的轮廓（`ponytail:`，要更好再加颗粒匹配）。
- Gemini 认不出的那一行有「改用画笔擦除」，点了切到画笔擦除并载入那张图；没有替你预先框好右下角（星标的位置随版本变，框大了会多擦）。

### 视频固定台标
- 在第一帧（`AVAssetImageGenerator`，按视频方向转正）上拖出台标，可以框几处，框角的 × 删掉一处。框存第一帧的像素坐标。
- 导出：`AVMutableVideoComposition.videoComposition(with:applyingCIFiltersWithHandler:)` 逐帧处理，交给 `AVAssetExportSession`，有进度条。编码跟原视频走：HEVC 用 HEVCHighestQuality，其余 HighestQuality（H.264）。
- 补像素：每帧只把框外 band + 1 圈的小块读回 CPU（`CIContext.render(toBitmap:)`），`VideoDelogo.fill` 按到框外左右上下四条边的距离对边上的像素加权（越近越重），羽化带 4 像素从「全换」过渡到「不换」，再贴回画面。思路同 ffmpeg 的 delogo，代码自己写。
  - 原计划写 Metal 的 Core Image 核，2026-10-30 实测 Xcode 27 没装 Metal 工具链（要 `xcodebuild -downloadComponent MetalToolchain` 另下），为了不给编译多加前提改成这样；只补一小块，CPU 够快。
- 音频：导出会话会重新编码成 AAC（高质量），不是原样带过（`ponytail:`；要原样得换成 AVAssetReader / Writer）。

### 界面（2026-10-30 用户要求「当作成熟的产品来做」，推翻 A2 的「首页四格 + 返回」）
- **对标**（2026-10-30 看过各家的产品图）：媒体转换工具（每个文件一张卡：缩略图 + 大小 · 尺寸 · 格式，底边一条「N 个 · M 个在做 · K 个做完」）；批量压图工具（缩略图 + 格式 / 大小角标，右边一栏选项卡片：格式、质量滑块、开关）；压缩包工具（侧边栏 + 可排序的表格：名称、大小、种类、压缩率 + 右边检查器，工具栏一排图标按钮）；系统照片的「清理」（一笔一擦、能放大、按住对比）。界面文案里不写这些产品的名字。
- **主窗口 = 侧边栏 + 工具页**（`MainView`）：工具多了用侧边栏（同系统设置、邮件），不要首页格子 + 返回（那是手机的样子）。侧边栏按「压缩」（打包、解压）「图片」（图片转换）「去水印」（Gemini 角标、画笔擦除、视频台标）分组，20 pt 家族色块 + 名字，还没处理完的数一个数；记住上次选的工具（偏好 `lastTool`）。去水印的三个模式就是侧边栏的三项。默认 1040×680，最小 940×560。
- **自己的样子（照 Kitty Tools 设置窗，2026-10-30 用户要求「要有我们自己应用的风格」）**：
  - 侧边栏不能收起（没有收起按钮）；选中自己画：窗口是 key 时品牌粉填充 + 白字（数字也变白），不是 key 时中性灰。系统画的选中会把品牌粉压成暗红，27 上侧栏的 `listRowBackground` 又不画，所以关掉原生高亮（`NativeHighlightOff`）、选中块和数字画在行里。
  - 窗口工具栏什么都不放、不画底色、不显示标题：顶上一条只有侧边栏和窗口底两种颜色（原来操作放工具栏，窗口一窄就收进「»」，内容、检查器上面的工具栏底色也不一样，2026-10-30 用户报）。
  - 每页一个页头（`ToolPage`）：40 pt 家族色块 + 标题（title2）+ 一句说明（callout），右边这一页的操作（系统按钮）和最右一个品牌粉胶囊主按钮（`BrandButtonStyle`：打包、转成 JPEG、去掉角标、存储、导出）。解压是放进来就解，没有主按钮。
  - 有选项的页（打包、图片转换）右边固定一栏 300 宽的选项：一组一张卡片（11 pt 组名、卡片表面、下面说明小字）。不用系统的检查器：窗口不够宽时它会先把侧边栏收起来再展开自己，还会把工具栏挤出「»」（2026-10-30 用户报）。
  - 整页同一个底色（窗口底），表格、列表也不另画底，各块之间只用发丝线分开。
  - 一打开焦点在侧边栏（↑↓ 换工具），不落进页里的第一个输入框（打包页的密码框会亮起一圈，⌘V 也会贴进去）。
  - 关于窗口是品牌页：奶油底、96 pt 图标、圆体字标、品牌粉版本胶囊、更新日志一个版本一张卡。
- **中间是表格**（打包、解压、图片转换）：可调列宽，列名称（带缩略图 / 图标）、种类、大小、尺寸、转换后的大小和差多少（−72% 染绿）、状态；右键在访达中显示 / 打开 / 重试 / 移除，双击打开，⌫ 移除选中的。Gemini 角标是左边一列缩略图、右边预览。
- **底下状态栏**（28 pt、11 pt 字，同访达窗口底边）：「4 张 · 已转 2 · 1 张没转成」「2 项 · 打包 120 个文件 · 忽略 8 项 查看 · 1 个文件名 Windows 不认 查看」（查看弹出清单）、做完的结果和「在访达中显示」、进度。
- **空着时**整页是拖放区：家族色圆底符号、标题、说明、「添加文件…」和「或拖进来、按 ⌘V 粘贴」；文件拖着经过整页描一圈家族色。
- **收文件**（Navigator）：拖到侧边栏某一项交给那一项；拖进工具页、⌘V 粘贴先给当前工具，它一个都收不了再分派；程序坞 / 打开方式：全是压缩包就解压，当前工具（打包除外）全收得了就给它，里面有图片或视频就弹出来问「交给哪个工具？」（只列收得了的），别的交给打包。
- **菜单和快捷键**：文件「添加文件…」⌘O（弹选文件，选好交给当前工具）；「工具」菜单 ⌘1–⌘6 切工具；编辑「粘贴」⌘V（见下）。
- **解压要密码**：弹框问（系统的提示框 + 密码框，「解压」「跳过」），密码不对写「密码不对，再试一次」；跳过的那一行留着「输入密码…」。
- **⌘V 粘贴**：编辑菜单的「粘贴」换成自己的（同组的剪切、拷贝、全选照系统的发给响应链）。剪贴板里是访达拷贝的文件时一律交给当前工具（光标在输入框里也是：往密码框里贴文件没有意义）；光标在输入框里、剪贴板是文字就照常贴字；别处有图片数据也交给工具。访达里拷贝的文件原样交出去；只有图片数据（截图到剪贴板、浏览器里「拷贝图像」）时，按原格式存成「下载」里的「粘贴的图片 日期 时间.扩展名」（重名加「 2」）再交出去，结果就放在它旁边。剪贴板里什么都收不了时响一声。
- **画笔擦除**（照系统照片的「清理」）：一笔一擦，松手就补，不用再点「擦除」；补的时候那一笔一明一暗地闪；⌘Z 一次退回一笔；画布能放大（捏合、⌘= / ⌘-、⌘0 适合窗口，放大后触控板 / 滚轮挪），底下浮着一条控制栏（笔刷大小、[ ] 调笔刷、撤销、对比、缩放），26 起是玻璃；页头「存储」⌘S。模型没下好之前不能涂。
- **前后对比**（`CompareSlider`）：两张叠在一起，线左边是原图、右边是去掉之后的，在图上任意处按下左右拖都能挪线；左上「原图」、右上「去水印后」两个小标签。Gemini 角标右边预览去好的那张；画笔擦除、视频台标（原视频和导出的第一帧）用「对比」开关打开，关掉才能接着涂 / 框。预览按长边 2400 解（`ponytail:`，要看 1:1 细节再加缩放）。

## 3. 架构与文件表

一个 App target `KittyBox`，加一个测试 target `KittyBoxTests`。

**仓库照 Kitty Tools 分（A3）**：
- `macos` 分支：mac 版，工程在 `macos/` 下，下表的路径都相对 `macos/KittyBox/`，tag 用 `macos-v*`；
- `windows` 分支：以后的 Windows 版，放在 `windows/` 下；
- `main`：默认分支，只放 README 和截图。
**和 Kitty Tools 的唯一区别：不是只在菜单栏显示（不设 `LSUIElement`）**，Kitty Box 是普通窗口 App，文件可以拖到程序坞图标或窗口上。

| 目录 | 文件 |
|---|---|
| `App/` | `KittyBoxApp.swift`（`@main`，主窗口）、`AppDelegate.swift`（`application(_:open:)`：拖到程序坞图标上、「打开方式」选了本 App 的文件交给 Navigator；能收哪些写在 `Config/Info.plist` 的 `CFBundleDocumentTypes`：压缩包 Alternate，其余 None） |
| `Shell/` | `MainView.swift`（主窗口：侧边栏 + 工具页，`Tool` 六个工具和分组，侧边栏自己画的品牌粉选中，「添加文件…」弹选文件、收到文件问交给谁）、`ToolPage.swift`（工具页的骨架：页头、右边选项栏和选项卡片、状态栏，空着时的拖放区、整页收拖放的描边）、`Paste.swift`（⌘V：剪贴板里的文件或图片数据交给 Navigator）、`FileThumb.swift`（缩略图和表格里的种类、大小、尺寸、转换后差多少）、`ResultLine.swift`（做完 / 没做成的那一行字）、`Navigator.swift`（选中哪个工具 + 收进来的文件往哪送，见 §2「界面」；各工具页的状态放这里）、`FreeName.swift`（重名加「 2」、名字后加「-去水印」，各工具共用）、`ImageBatch.swift`（一批图一张一张处理的列表模型和一行的样子：图片转换和 Gemini 角标共用）、`Style.swift`（从 Kitty Tools 的同名文件摘出用得上的刻度：品牌粉、奶油底、选中色、发丝线、品牌粉主按钮，加四类工具的家族色和画布上浮着的控制栏）、`Subprocess.swift`（从 Kitty Tools 拷来，加了 `directory`）、`Prefs.swift`（偏好键名）。强调色跟随系统（`AccentColor.colorset` 是品牌粉），没有设置页，不拷 `Accent.swift` |
| `Archive/` | `ZipNames.swift`（中央目录读取和编码判断）、`IgnoreRules.swift`（忽略规则匹配）、`WindowsNames.swift`（Windows 不认的文件名）、`Archiver.swift`（选引擎、拼参数、跑子进程、解完的清理和挪位置）、`PackView.swift`（打包页和它的 PackModel）、`UnpackView.swift`（解压页和它的 UnpackModel：一个接一个解、就地问密码） |
| `ImageConvert/` | `ImageConverter.swift`（ImageIO 读写、转正方向、图标格式）、`ConvertView.swift`（转换页和它的 ConvertModel） |
| `Watermark/` | `GeminiMark.swift`（找星标、反解、另存）、`VideoDelogo.swift`（第一帧、补像素、导出）、`Inpainter.swift`（LaMa：裁、补、羽化贴回）、`EraseCanvas.swift`（画笔擦除：一笔一擦、撤销、缩放、对比、存储）、`GeminiView.swift`（Gemini 角标页：一批图 + 预览对比）、`VideoMarkView.swift`（视频台标：第一帧上拖框、导出）、`CompareSlider.swift`（前后对比：拖中间的线） |
| `Resources/` | `Assets.xcassets`（小猫图标）、`gemini-alpha-*.bin`、`7zz-LICENSE.txt`、`gemini-watermark-LICENSE.txt`；`changelog.json` 第一次发版时加 |
| `macos/` | `Config/{Base,Debug,Release}.xcconfig`（`Tests.xcconfig` M1 加）、`build-dmg.sh`、`fetch-vendor.sh`（拉 7zz 和模型到被忽略的 `Vendor/`，7zz 的许可证写到 `Resources/7zz-LICENSE.txt` 入库）、`brand-icons.swift`（同一只小黑猫扒着纸箱，青绿底板） |
| 仓库根目录 | `AGENTS.md`、`CLAUDE.md`、`.cursor/rules/box-native.mdc`、`.gitignore` |

- 一个概念一个文件，不预建空目录。
- 应用内更新 `App/Updater.swift`：从 Kitty Tools 摘核心（读 latest release、比版本号、下载 `_arm64.zip`、ditto 解包、按本团队签名验签、换掉、重新打开），去掉刘海岛和菜单栏角标那些；下载进度的 KVO 令牌放进 `Mutex`（不用 `nonisolated(unsafe)`）。打开 App 10 秒后查一次，App 菜单「检查更新…」、关于窗口也能查；有新版本时侧边栏底下一张小卡。
- 关于窗口 `App/AboutView.swift`：图标、版本、检查更新 / 更新并重新打开、更新日志（`Resources/changelog.json`）、随包第三方组件和 NOTICE 链接。App 菜单「关于 Kitty Box」换成它。

**单测**（Swift Testing，不写真实偏好）：
- `ZipNamesTests`：三种 zip 的字节夹具——有 UTF-8 标志、没标志但写的是 UTF-8、没标志写的是 GBK；
- `IgnoreRulesTests`：通配符、任意层级、`/` 结尾只认文件夹、中间带 `/` 的拒收；
- `WindowsNamesTests`：非法字符、结尾空格或点、保留名，以及全角符号（比如「：」）不算问题；
- `GeminiMarkTests`：照 Gemini 公式在有纹理的图上盖星标，几种候选都认得对，去掉后每个像素误差不超过 3（α 不到 3/255 的边缘上游不动，那里本来差 2–3）；没盖的认不出、不出文件；
- `VideoDelogoTests`：补像素的纯函数；用 AVAssetWriter 造一段带白色台标的小视频，框上导出后台标那里变回底色；
- `InpainterTests`：裁哪一块、笔画画成的遮罩和外接框；真跑一次 LaMa 把平滑底色上的红方块补掉（涂的范围外一个像素不动，模型下载过才跑）；撤销的顺序；
- `LaMaModelTests`：用 `file://` 模拟下载（按 SHA256 校验、照目录结构放好、进度报到 1；对不上不放）；真从 Hugging Face 下一遍平时跳过，`TEST_RUNNER_KITTY_LIVE_MODEL=1` 时跑（约 3 分钟）；
- `ArchiverTests`：在临时目录里真调 7zz 和 tar 各跑一遍往返：zip 和 7z、带密码和不带、ZipCrypto、中文密码的 zip 被拦下、GBK 名字的 zip、忽略清单和空文件夹、只有一样东西时不多套一层、隔离标记跟着走；外加名字的纯函数；
- `ImageConverterTests`：10 种格式各转一遍（类型、尺寸、JPEG 透明处是白的、图标是正方形）、拍摄信息带过去和转正方向、动图留着每一帧、能读什么；
- `NavigatorTests`：收进来的文件往哪送（当前工具收得了给它、有图片视频就问、别的打包；拖进工具页先给当前工具）、哪些工具能收、记住上次选的工具（临时偏好域）；
- `PasteTests`：剪贴板里的文件原样交出去、只有图片数据时按原格式存成文件（重名不覆盖）、只有文字时什么都不交、粘贴到工具页交给这个工具；用自己起名的剪贴板，不碰用户的；
- `UpdaterTests`：latest release 的 JSON 怎么认、版本号按数字比；
- `SnapshotProbeTests`：截图自检（照 Kitty Tools）：关于窗口屏外画成 PNG；主窗口（侧边栏、页头、右边的选项）屏外画不出来，开一扇真窗口（`NSHostingView` 桥接工具栏，按 key 窗口画），先截一张空着的打包页，再带着示例数据一个工具停 3.5 秒，窗口编号写进 `live-<工具>.txt` 由外面 `screencapture -l` 截；模型下载过的话在系统壁纸上真擦一处存 `erase-result.png`、再截一张对比；偏好用临时域；平时跳过，`TEST_RUNNER_KITTY_SNAPSHOT_DIR=<目录>` 时才跑。

## 4. 签名与打包

- Apple Development，`DEVELOPMENT_TEAM = HTX9F4KG39`，开 Hardened Runtime，不开沙盒，不公证，不用 adhoc 签名。
- Bundle ID：`com.yy.kitty-box`，Debug 版是 `com.yy.kitty-box.dev`；产品名：`Kitty Box`，Debug 版是 `Kitty Box Dev`。
- 版本号只在 `Base.xcconfig` 的 `MARKETING_VERSION` 里改，同时要在 `changelog.json` 加一条，否则 `build-dmg.sh` 会中止。
- `build-dmg.sh` 照搬 Kitty Tools 的路径 B，另外加两项检查：
  - `codesign -d -r-` 看 `7zz` 是用本团队证书签的；
  - LaMa 模型**不在**包里（用时下载，别不小心打进来）。
- 包体：7zz 约 3 MB + 其余几 MB；LaMa 模型不随包，第一次用画笔擦除时下载约 216 MB。

## 5. 里程碑

- **M0 骨架**（2026-10-30 做完）：`git init -b macos`；Xcode 工程（同步文件夹）和 xcconfig；`Style.swift`；小猫纸箱图标和 DMG 背景；`build-dmg.sh`、`fetch-vendor.sh`；AGENTS / CLAUDE / 规则文档；四格首页（点进去是「还没做好」）。测试 target 等 M1 有第一个单测时加。
- **M1 打包 / 解压**（2026-10-30 做完，23 个单测）：`ZipNames` → `IgnoreRules` → `WindowsNames` → `Archiver` → 打包页、解压页、程序坞拖放。**待你手测**：在 Windows 上双击打开几个包——中文名的 zip、ZipCrypto 加密的、AES 加密的、7z。如果中文名乱码，再加「给中文 Windows 写 GBK 文件名」这一项。
  - ponytail: 没有进度条和取消（大包只转圈）；7zz 的 `-bsp1` 能给进度，要的时候再接。
- **M2 图片转换**（2026-10-30 做完，共 32 个单测）：`ImageConverter` → 转换页 → 首页「收到 N 个文件，点一格交给它」。
- **M3 Gemini 角标 + 视频台标**（2026-10-30 做完，共 38 个单测）：`GeminiMark` → `VideoDelogo` → 去水印页（画笔擦除那一格先空着）。**待你手测**：拿真的 Gemini 生成图、带台标的真视频各试一次。
- **M4 画笔擦除**（2026-10-30 做完，共 42 个单测）：选定模型并写进 `fetch-vendor.sh` → `Inpainter` → 画笔界面 → Gemini 认不出时一键改用画笔擦除。**待你手测**：在真图上涂一处水印擦一下。
- **0.1.0 打好包、没发布**（2026-10-30）：Updater + 关于窗口 + changelog → `build-dmg.sh`（DMG 约 200 MB，带背景和摆位）。GitHub release `macos-v0.1.0` 发了又删了（连 tag）：你还没手测，不该发；main 的 README 也改回「暂时没有可下载的版本」。**等你用本地的 DMG 手测完、明确说发，再重新出包发布。**
  - 同日用户嫌安装包大（约 200 MB，几乎全是模型），改成模型用时下载，重新出了本地包。
- **界面重做**（2026-10-30 做完三轮）：第一轮紧凑工具栏、首页卡片、拖放区、⌘V 粘贴、前后对比；用户说「一点都不成熟」，第二轮照成熟产品改成侧边栏 + 表格 + 右边选项 + 工具栏操作 + 状态栏，画笔擦除一笔一擦能放大（见 §2「界面」）。第三轮（同日，用户报检查器把侧边栏挤收起、出现「»」、顶上颜色不一致，要「自己应用的风格」）照 Kitty Tools 设置窗改：操作挪进页头、选项改成页里固定一栏卡片、工具栏清空、侧边栏品牌粉选中、关于窗口品牌页。**待你手测**：⌘V 粘贴文件和截图、拖动对比线、画笔擦除的捏合放大和一笔一擦、解压的密码框（这些只能真按键 / 真拖，自检没覆盖）。

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
