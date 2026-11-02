#!/usr/bin/env swift
// 品牌图标生成脚本：照 Kitty Tools 的 brand-icons.swift（同一只小黑猫「探头」），这里小猫坐进一个打开的纸箱、
// 底色换成青绿（和 Kitty Tools 的粉、Kitty Clear 的天蓝分开，程序坞里一眼认得出）。
// 用法：swift macos/brand-icons.swift [预览目录]；环境变量 KITTY_ICON_ROOT 把输出根目录从 macos/ 换到别处（试跑用）。
// App 图标写成 Icon Composer 文档 KittyBox/Resources/AppIcon.icon（icon.json + Assets/ 里每层一个 SVG），Xcode 的
// actool 编成 macOS 26+ 的液态玻璃图标，另压平一份 AppIcon.icns 给 macOS 15。画布 1024 pt，整张就是图标：圆角、边距、
// 阴影、高光都由系统加，底色是 icon.json 里的青绿渐变，不画底板。后面两片箱盖竖在头后面，前盖往外翻，爪子搭在箱口。
// 四组从前到后：Paws（爪子、肉垫）/ Box（纸箱正面、前盖、胶带）/ Kitten（头、眼睛、五官）/ Back（后盖、箱子里面）；
// 半透明全关，卡通保持饱和、像 Safari 一样实心。深色模式换深一档的青绿底（不然系统换成近黑底，黑猫就没了）、纸箱暗一成；
// 单色（染色 / 透明，JSON 里都叫 tinted）只留亮度：头和爪子换白、挖出眼睛、藏起肉垫，纸箱换固定的灰，箱子里面变透明。
// 以前 16、32 像素手调的 PNG 没了：.icon 和 AppIcon.appiconset 同时在时，.icon 在所有系统上都赢（macOS 15 的回退图也由它
// 压平），appiconset 留着白放，这里顺手删掉；所以主图本身在 16 像素也要认得出。
// 另写 Config/dmg-background.tiff（DMG 窗口背景：设计区 600 × 400 pt 在左上角，奶油底、字标 Kitty Box、虚点弧线箭头、
// 「仍要打开」路径；整张画布 2560 × 1600 pt，窗口拉大也不露白；@1x + @2x，Deflate；改产品名或文案也改这里）。
// Kitty Box 不在菜单栏，不出 StatusIcon。
// 只用 AppKit / CoreGraphics / CoreText / ImageIO，几何都在这一个文件里：改角色就改这里再跑一遍。给了预览目录时
// 用 Xcode 带的 ictool 渲出六种外观（512 px，不带系统边距和阴影）和 DMG 背景。

import AppKit

// MARK: 颜色

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
    blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// SVG 里的颜色：#RRGGBB
func css(_ value: UInt32) -> String { String(format: "#%06X", value) }

/// icon.json 里的颜色只认 srgb:r,g,b,a 这种写法（#RRGGBB 会报错），各分量 5 位小数
func srgb(_ red: Double, _ green: Double, _ blue: Double) -> String {
  String(format: "srgb:%.5f,%.5f,%.5f,1.00000", red, green, blue)
}

func srgb(_ value: UInt32) -> String {
  srgb(
    Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255,
    Double(value & 0xFF) / 255)
}

let ink: UInt32 = 0x3A2530
let cream: UInt32 = 0xFFF5F0
let beans: UInt32 = 0xFF9FB8
let pink: UInt32 = 0xFF7FA0
let white: UInt32 = 0xFFFFFF
let black: UInt32 = 0x000000

/// 纸箱的一层：SVG 里的本色、深色模式的色（暗一成）、单色里的灰（亮度决定染色后留多少白）
struct Tone {
  let light: UInt32
  let dark: UInt32
  let mono: Double
}

let frontPanel = Tone(light: 0xE8B878, dark: 0xD3A266, mono: 0.42)
let frontFlap = Tone(light: 0xF2CC90, dark: 0xDDB57A, mono: 0.55)
// 两段胶带的灰比设计稿（0.62 / 0.70）提亮了：TintedDark 里箱子整体压暗，胶带和正面糊成一片。
// 单色在 JSON 里只有一种 tinted，所以 TintedLight 和两种 Clear 里胶带也跟着亮一点
let tape = Tone(light: 0xF4D7A8, dark: 0xDEC08E, mono: 0.72)
let flapTape = Tone(light: 0xFADFB4, dark: 0xE4C89A, mono: 0.80)
let backFlap = Tone(light: 0xD69A58, dark: 0xBC8446, mono: 0.34)
// 箱子里面在单色里是黑，也就是透明：白猫始终是最亮的，纸箱退成灰的陪衬
let inside = Tone(light: 0xA86C34, dark: 0x84522A, mono: 0)

// MARK: 几何（新画布 1024 pt；旧图底板的主体 100…924 就是现在的整张画布）

let rim = 630.0  // 箱口：纸箱正面的上沿
/// 小猫：kitten() 的原坐标整体缩放平移，旧箱口 y 614 对到新箱口上；比按旧底板 1:1 移植（× 1024 / 824）
/// 小 3%，头顶给后面两片箱盖留地方
let kittenScale = 0.97 * (1024.0 / 824)
let kittenX = 512 - kittenScale * 512
let kittenY = rim - kittenScale * 614
let pawGap = 12.0  // 旧坐标：单色里沿爪子挖的缝
let boxLeft = 144.0
let boxRight = 880.0
let boxBottom = 898.0
let boxCorner = 44.0  // 正面下面两个圆角
let openBack = 556.0  // 箱口后沿：后沿到箱口之间露出箱子里面
let insetBack = 14.0  // 后沿两头比箱口往里收（从斜上方看下去）
let flapDrop = 92.0  // 前盖往外翻，盖住正面上面这么高
let flapFlare = 22.0  // 前盖下沿往两边张开
let tapeWidth = 124.0
let backFlapWidth = 158.0
let backFlapLength = 284.0  // 后沿以上露出来的长度
let backFlapTilt = 16.0  // 往外斜的角度
let backFlapFoot = 2.0  // 外侧的脚离后沿那头的距离
let backFlapRound = 30.0

// MARK: SVG

/// 一层一个 SVG，都是整张 1024 画布（ictool 按 width / height 摆在画布正中，小了就缩在中间）
func svg(_ body: String) -> String {
  #"<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">"#
    + body + "</svg>"
}

/// 小猫的层：里面照写 kitten() 的原坐标，外面套一层变换
func kittenSVG(_ body: String) -> String {
  let transform = String(
    format: #"<g transform="translate(%.4f %.4f) scale(%.7f)">"#, kittenX, kittenY, kittenScale)
  return svg(transform + body + "</g>")
}

/// 原样的数（%g 不带多余的 0）：kitten() 的数、整数尺寸；算出来的坐标在 polygon 里统一两位小数
func num(_ value: Double) -> String { String(format: "%g", value) }

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// 左右对称：给左边的点，镜像出右边（新旧画布的中线都是 512）
func mirrored(_ points: [CGPoint]) -> [CGPoint] { points.map { point(1024 - $0.x, $0.y) } }

func ellipse(
  _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ color: UInt32, opacity: Double? = nil
) -> String {
  #"<ellipse cx="\#(num(cx))" cy="\#(num(cy))" rx="\#(num(rx))" ry="\#(num(ry))""#
    + #" fill="\#(css(color))""# + (opacity.map { #" fill-opacity="\#(num($0))""# } ?? "") + "/>"
}

/// 多边形；给了 round 就加同色圆角描边，把尖角磨圆（耳朵、鼻子、箱盖）
func polygon(_ points: [CGPoint], _ color: UInt32, round: Double = 0) -> String {
  let list = points.map { String(format: "%.2f,%.2f", $0.x, $0.y) }.joined(separator: " ")
  let stroke =
    round > 0
    ? #" stroke="\#(css(color))" stroke-width="\#(num(round))" stroke-linejoin="round""# : ""
  return #"<polygon points="\#(list)" fill="\#(css(color))"\#(stroke)/>"#
}

/// 整张画布的遮罩：height 以上留下，再挖掉 cut 里的黑形状
func mask(_ id: String, keepAbove height: Double, cut: String) -> String {
  #"<defs><mask id="\#(id)" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">"#
    + #"<rect x="0" y="0" width="1024" height="\#(num(height))" fill="\#(css(white))"/>"#
    + cut + "</mask></defs>"
}

// MARK: 小猫（kitten() 的原坐标，旧 1024 画布）

// 耳朵（外黑内粉）：耳尖往外撇，和脸颊之间留出一个缺口（不然头像顶头盔）
let ear = [point(352, 392), point(296, 204), point(478, 330)]
let innerEar = [point(366, 354), point(338, 260), point(426, 320)]
let eyeX: [Double] = [424, 600]  // 眼睛中心，y 都是 500
let pawX: [Double] = [386, 638]  // 爪子中心，y 都是 616

/// 头（耳朵 + 脸，一块墨色）：挖出眼睛（比眼白小一圈，边被眼白盖住）；箱口往下一点切掉，藏在箱子后面的部分
/// 在单色里会透出来。gap > 0 时再沿爪子挖一圈缝：单色里头和爪子都是白的，不挖就粘成一块
func head(pawGap gap: Double) -> String {
  let holes =
    eyeX.map { ellipse($0, 500, 52, 56, black) }.joined()
    + (gap > 0 ? pawX.map { ellipse($0, 616, 76 + gap, 46 + gap, black) }.joined() : "")
  return mask("m", keepAbove: 614 + 24, cut: holes) + #"<g mask="url(#m)">"#
    + polygon(ear, ink, round: 32) + polygon(mirrored(ear), ink, round: 32)
    + ellipse(512, 522, 256, 208, ink) + "</g>"
}

// 眼睛：奶油色眼白，瞳孔往下看箱子
let eyes = eyeX.map { ellipse($0, 500, 56, 60, cream) + ellipse($0 + 6, 524, 34, 35, ink) }.joined()
// 一大一小两个高光：单独一层、不上玻璃
let glints = eyeX.map {
  ellipse($0 + 21, 507, 11.5, 11.5, white) + ellipse($0 - 8, 541, 5.5, 5.5, white, opacity: 0.9)
}.joined()
// 内耳、腮红、鼻子和 ω 嘴
let details =
  polygon(innerEar, pink, round: 12) + polygon(mirrored(innerEar), pink, round: 12)
  + ellipse(352, 568, 30, 16, pink, opacity: 0.8) + ellipse(672, 568, 30, 16, pink, opacity: 0.8)
  + polygon([point(496, 566), point(528, 566), point(512, 585)], pink, round: 10)
  + #"<path d="M490 594 Q500 612 512 596 Q524 612 534 594" fill="none" stroke="\#(css(beans))""#
  + #" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>"#
// 爪子和肉垫（肉垫单独一层、不上玻璃）
let paws = pawX.map { ellipse($0, 616, 76, 46, ink) }.joined()
let pawBeans = pawX.flatMap { cx in
  [(-26.0, 14.0), (0, 21), (26, 14)].map { ellipse(cx + $0.0, 616 + $0.1, 10, 9, beans) }
}.joined()

// MARK: 纸箱（新画布坐标）

/// 正面：上沿是直的（被前盖盖住），下面两个圆角
let panel = String(
  format: "M%g,%g H%g V%g Q%g,%g %g,%g H%g Q%g,%g %g,%g Z", boxLeft, rim, boxRight,
  boxBottom - boxCorner, boxRight, boxBottom, boxRight - boxCorner, boxBottom,
  boxLeft + boxCorner, boxLeft, boxBottom, boxLeft, boxBottom - boxCorner)
// 正面那段胶带从前盖下沿开始，裁在正面里
let tapeStrip =
  #"<defs><clipPath id="c"><path d="\#(panel)"/></clipPath></defs>"#
  + String(
    format: #"<rect x="%g" y="%g" width="%g" height="%g" fill="%@" clip-path="url(#c)"/>"#,
    512 - tapeWidth / 2, rim + flapDrop - 4, tapeWidth, boxBottom - rim - flapDrop + 4,
    css(tape.light))
// 前盖：箱口往外翻下来的一条，下沿往两边张开；四角靠同色描边磨圆（半宽 14），所以点往里收
let flapCorner = 14.0
let frontFlapPoints = [
  point(boxLeft + flapCorner - 2, rim + flapCorner - 2),
  point(boxRight - flapCorner + 2, rim + flapCorner - 2),
  point(boxRight + flapFlare - flapCorner, rim + flapDrop - flapCorner),
  point(boxLeft - flapFlare + flapCorner, rim + flapDrop - flapCorner),
]
// 前盖上那段胶带跟着前盖一起张开
let flare = 1 + 2 * flapFlare / (boxRight - boxLeft)
let flapTapePoints = [
  point(512 - tapeWidth / 2, rim + 2), point(512 + tapeWidth / 2, rim + 2),
  point(512 + tapeWidth / 2 * flare, rim + flapDrop - 2),
  point(512 - tapeWidth / 2 * flare, rim + flapDrop - 2),
]

// MARK: 后面（后盖、箱子里面）

/// 头底下不画后面这组（往里收 12）：单色里头是白的，后面的灰会从头后面透出来
let underHead = String(
  format: #"<ellipse cx="%.2f" cy="%.2f" rx="%.2f" ry="%.2f" fill="%@"/>"#,
  kittenX + kittenScale * 512, kittenY + kittenScale * 522, kittenScale * 256 - 12,
  kittenScale * 208 - 12, css(black))
// 后盖：长方形往外斜，外侧的脚站在后沿那头；往下多画一截再沿后沿切平，后沿以下露出箱子里面
let tilt = backFlapTilt * .pi / 180
let up = (x: -sin(tilt), y: -cos(tilt))  // 顺着箱盖往上
let across = (x: cos(tilt), y: -sin(tilt))  // 横过箱盖往里
let extra = backFlapWidth * tan(tilt) + 40  // 后沿以下多画的长度（切掉）
let foot = (x: boxLeft + insetBack + backFlapFoot - up.x * extra, y: openBack - up.y * extra)
/// 后盖上的点：从外侧的脚横过 a、往上 b
func onFlap(_ a: Double, _ b: Double) -> CGPoint {
  point(foot.x + across.x * a + up.x * b, foot.y + across.y * a + up.y * b)
}
let backFlapPoints = [
  onFlap(0, 0), onFlap(backFlapWidth, 0), onFlap(backFlapWidth, backFlapLength + extra),
  onFlap(0, backFlapLength + extra),
]
// 箱子里面：从后沿到箱口往下一点（被正面盖住），后沿两头往里收
let insidePoints = [
  point(boxLeft + insetBack, openBack), point(boxRight - insetBack, openBack),
  point(boxRight, rim + 30), point(boxLeft, rim + 30),
]

let assets = [
  "paws.svg": kittenSVG(paws),
  "beans.svg": kittenSVG(pawBeans),
  "flap-tape.svg": svg(polygon(flapTapePoints, flapTape.light)),
  "front-flap.svg": svg(polygon(frontFlapPoints, frontFlap.light, round: 2 * flapCorner)),
  "tape.svg": svg(tapeStrip),
  "front.svg": svg(#"<path d="\#(panel)" fill="\#(css(frontPanel.light))"/>"#),
  "glints.svg": kittenSVG(glints),
  "details.svg": kittenSVG(details),
  "eyes.svg": kittenSVG(eyes),
  "head.svg": kittenSVG(head(pawGap: 0)),
  // 单色专用的头：同一个剪影沿爪子挖了缝（在默认外观里挖缝再垫一层会留一圈接缝，所以单色换一整张图）
  "head-mono.svg": kittenSVG(head(pawGap: pawGap)),
  "back-flaps.svg": svg(
    mask("f", keepAbove: openBack + 3, cut: underHead) + #"<g mask="url(#f)">"#
      + polygon(backFlapPoints, backFlap.light, round: backFlapRound)
      + polygon(mirrored(backFlapPoints), backFlap.light, round: backFlapRound) + "</g>"),
  "inside.svg": svg(
    mask("i", keepAbove: rim + 24, cut: underHead) + #"<g mask="url(#i)">"#
      + polygon(insidePoints, inside.light, round: 16) + "</g>"),
]

// MARK: icon.json

typealias JSON = [String: Any]

/// 一层，图片是 Assets/<名字>.svg
func layer(_ name: String, _ keys: JSON = [:]) -> JSON {
  keys.merging(["name": name, "image-name": "\(name).svg"]) { $1 }
}

/// 只在单色外观生效的值（染色、透明都读 tinted）
func tinted(_ value: Any) -> [JSON] { [["appearance": "tinted", "value": value]] }

/// 纸箱的一层在深色、单色外观里整层换成一个颜色（形状不变）
func recolored(_ tone: Tone) -> JSON {
  [
    "fill-specializations": [
      ["appearance": "dark", "value": ["solid": srgb(tone.dark)]],
      ["appearance": "tinted", "value": ["solid": srgb(tone.mono, tone.mono, tone.mono)]],
    ]
  ]
}

/// 一组：半透明关掉、中性阴影。combined = 整组一个玻璃外壳、一圈倒角，小五官不会各自鼓成果冻
func group(_ name: String, shadow: Decimal, combined: Bool = true, _ layers: [JSON]) -> JSON {
  var group: JSON = [
    "name": name, "layers": layers, "shadow": ["kind": "neutral", "opacity": shadow] as JSON,
    "translucency": ["enabled": false, "value": 0.5] as JSON,
  ]
  if combined { group["lighting"] = "combined" }
  return group
}

let whiteFill = ["solid": srgb(white)]
let icon: JSON = [
  // 底色：旧底板三段渐变的两头；深色模式换深一档的青绿
  "fill-specializations": [
    ["value": ["linear-gradient": [srgb(0x63E0D2), srgb(0x12958B)]]],
    ["appearance": "dark", "value": ["linear-gradient": [srgb(0x17877E), srgb(0x0B4540)]]],
  ] as [JSON],
  // 从前到后，最多 4 组（第 5 组 actool 直接报错）
  "groups": [
    group(
      "Paws", shadow: 0.5, combined: false,
      [
        layer("beans", ["glass": false, "hidden-specializations": tinted(true)]),
        layer("paws", ["fill-specializations": tinted(whiteFill)]),
      ]),
    group(
      "Box", shadow: 0.5,
      [
        layer("flap-tape", recolored(flapTape)), layer("front-flap", recolored(frontFlap)),
        layer("tape", recolored(tape)), layer("front", recolored(frontPanel)),
      ]),
    group(
      "Kitten", shadow: 0.45,
      [
        layer("glints", ["glass": false]), layer("details"),
        layer("eyes", ["hidden-specializations": tinted(true)]),
        [
          "name": "head", "fill-specializations": tinted(whiteFill),
          "image-name-specializations": [
            ["value": "head.svg"], ["appearance": "tinted", "value": "head-mono.svg"],
          ],
        ],
      ]),
    group(
      "Back", shadow: 0.35,
      [layer("back-flaps", recolored(backFlap)), layer("inside", recolored(inside))]),
  ],
  "supported-platforms": ["squares": ["macOS"]],
]

// MARK: DMG 窗口背景（600 × 400 pt；访达里 App 在 (150, 205)、「应用程序」在 (450, 205)，见 build-dmg.sh）

/// 圆角三角形：填充 + 同色圆角描边（箭头）
func triangle(_ ctx: CGContext, _ points: [CGPoint], _ color: CGColor, round: CGFloat) {
  let path = CGMutablePath()
  path.addLines(between: points)
  path.closeSubpath()
  ctx.setFillColor(color)
  ctx.setStrokeColor(color)
  ctx.setLineWidth(round)
  ctx.setLineJoin(.round)
  ctx.addPath(path)
  ctx.drawPath(using: .fillStroke)
}

func dmgBackground(scale: Int) -> CGImage {
  let brand = hex(0xFF4D7E)
  let ctx = CGContext(
    data: nil, width: 600 * scale, height: 400 * scale, bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x: 0, y: CGFloat(400 * scale))
  ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
  // 奶油底，左上一团品牌粉、右下一团淡蓝紫
  ctx.setFillColor(hex(cream))
  ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
  for (color, center, radii) in [
    (hex(0xFF4D7E, 0.15), point(30, 0), (20.0, 355.0)),
    (hex(0xC8D8FF, 0.3), point(600, 400), (0, 340)),
  ] {
    let glow = CGGradient(
      colorsSpace: sRGB, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(
      glow, startCenter: center, startRadius: radii.0, endCenter: center, endRadius: radii.1,
      options: .drawsBeforeStartLocation)
  }
  // 字标和两行说明：水平居中，y 是基线（上下翻转的画布里字形要再翻回来）
  func text(_ string: String, _ font: NSFont, _ color: CGColor, y: CGFloat) {
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: string,
        attributes: [
          .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = point((600 - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y)
    CTLineDraw(line, ctx)
  }
  text("Kitty Box", .systemFont(ofSize: 24, weight: .bold), hex(0xD12A5F), y: 62.5)
  // 系统字体回退到的 .PingFangUITextSC 会把「」挤成半宽，这行直接用 PingFang SC 保持全宽
  text(
    "把左边的图标拖到「应用程序」文件夹，就装好了", NSFont(name: "PingFangSC-Regular", size: 13)!,
    hex(0x000000, 0.55), y: 86)
  text(
    "首次打开被拦下时：系统设置 › 隐私与安全 › 仍要打开", .systemFont(ofSize: 11), hex(0x000000, 0.45),
    y: 366)
  // 中间的虚点弧线：零长虚线 + 圆头 = 等弧长的圆点（直径 4、间距 11.1），末端圆角三角箭头
  let arc = CGMutablePath()
  arc.move(to: point(235, 211))
  arc.addQuadCurve(to: point(355, 213.5), control: point(302, 178))
  ctx.saveGState()
  ctx.setStrokeColor(brand)
  ctx.setLineWidth(4)
  ctx.setLineCap(.round)
  ctx.setLineDash(phase: 0, lengths: [0, 11.1])
  ctx.addPath(arc)
  ctx.strokePath()
  ctx.restoreGState()
  triangle(ctx, [point(362.4, 212.6), point(354.9, 204.3), point(351.1, 213.5)], brand, round: 4)
  return ctx.makeImage()!
}

/// 整张背景：访达按 1 pt 对 1 pt 从窗口左上角贴、不缩放，用户把窗口拉大时图外露白，所以画布做大。
/// 设计区（上面 600 × 400 那张）逐像素原样贴在左上角——直接画在大画布上，CG 渐变的抖动按设备坐标走，会差 1 个色阶；
/// 外面是奶油底 + 右下那团淡蓝紫光的自然延续（圆心就在设计区右下角），逐像素算、不抖动，纯色段长，压缩后只多一百来 KB。
/// ponytail: 画布 2560 × 1600 pt 盖住 Apple 各屏默认分辨率下的全屏窗口（Pro Display XDR 的 3008 × 1692 除外），
/// 再大的窗口右 / 下还会露白；要盖就加大这里（访达 @2x 解码内存按面积涨，现在约 65 MB）
let dmgCanvas = (width: 2560, height: 1600)

func dmgCanvasImage(scale: Int) -> CGImage {
  let (width, height) = (dmgCanvas.width * scale, dmgCanvas.height * scale)
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!  // 本来就全不透明：不存 alpha，TIFF 小一截
  ctx.setFillColor(hex(cream))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  // 和 dmgBackground 里那团光同参数：圆心 (600, 400)、半径 340、#C8D8FF 不透明度 0.3 → 0，叠在奶油底上
  let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)  // 第 0 行是最上面一行
  let (base, tint): ([Double], [Double]) = ([0xFF, 0xF5, 0xF0], [0xC8, 0xD8, 0xFF])
  let s = Double(scale)
  for y in Int(60 * s)..<Int(740 * s) {
    for x in Int(260 * s)..<Int(940 * s) {
      let r = hypot((Double(x) + 0.5) / s - 600, (Double(y) + 0.5) / s - 400)
      let alpha = 0.3 * max(0, 1 - r / 340)
      for c in 0..<3 {
        let value = base[c] + (tint[c] - base[c]) * alpha
        pixels[y * ctx.bytesPerRow + x * 4 + c] = UInt8(value.rounded())
      }
    }
  }
  // CG 坐标原点在左下：设计区贴到最上面
  ctx.draw(
    dmgBackground(scale: scale),
    in: CGRect(x: 0, y: height - 400 * scale, width: 600 * scale, height: 400 * scale))
  return ctx.makeImage()!
}

// MARK: 写文件

func writePNG(_ image: CGImage, to url: URL) {
  let rep = NSBitmapImageRep(cgImage: image)
  rep.size = NSSize(width: image.width, height: image.height)
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root =
  ProcessInfo.processInfo.environment["KITTY_ICON_ROOT"].map { URL(fileURLWithPath: $0) }
  ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let resources = root.appending(path: "KittyBox/Resources")
let iconURL = resources.appending(path: "AppIcon.icon")
let files = FileManager.default
// 整个重写：去掉的层不留旧 SVG
try? files.removeItem(at: iconURL)
try! files.createDirectory(at: iconURL.appending(path: "Assets"), withIntermediateDirectories: true)
// 键排序 + 缩进，和 Icon Composer 存盘的写法一样：在 Icon Composer 里打开再存不会改出一片 diff
try! JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
  .write(to: iconURL.appending(path: "icon.json"))
for (name, content) in assets {
  try! content.write(
    to: iconURL.appending(path: "Assets/\(name)"), atomically: true, encoding: .utf8)
}
// 旧的 PNG 图标：和 .icon 同时在时整个被忽略
let appIconSet = resources.appending(path: "Assets.xcassets/AppIcon.appiconset")
if files.fileExists(atPath: appIconSet.path(percentEncoded: false)) {
  try! files.removeItem(at: appIconSet)
  print("已删掉旧的 AppIcon.appiconset")
}
// DMG 背景：@1x、@2x 两张合进一个 TIFF（dpi 72 / 144，访达按屏幕倍率挑）。用 ImageIO 写 Deflate：
// 画布大半是纯色，NSBitmapImageRep 只有 LZW，每条带都从头建字典，同一张图大 60%
let dmg = CGImageDestinationCreateWithURL(
  root.appending(path: "Config/dmg-background.tiff") as CFURL, "public.tiff" as CFString, 2, nil)!
for scale in [1, 2] {
  CGImageDestinationAddImage(
    dmg, dmgCanvasImage(scale: scale),
    [
      kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 8],  // 8 = Adobe Deflate
    ] as CFDictionary)
}
precondition(CGImageDestinationFinalize(dmg))
print("已写入 AppIcon.icon（\(assets.count) 层 SVG）、DMG 背景 @1x / @2x")

// 预览：ictool 渲出六种外观，和 Xcode 里 Icon Composer 的预览同一套渲染；DMG 背景原样
if CommandLine.arguments.count > 1 {
  let preview = URL(fileURLWithPath: CommandLine.arguments[1])
  try! files.createDirectory(at: preview, withIntermediateDirectories: true)
  writePNG(dmgBackground(scale: 2), to: preview.appending(path: "dmg-background@2x.png"))
  for rendition in ["Default", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark"] {
    let ictool = Process()
    ictool.executableURL = URL(
      fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Icon Composer.app"
        + "/Contents/Executables/ictool")
    ictool.arguments = [
      iconURL.path(percentEncoded: false), "--export-image", "--output-file",
      preview.appending(path: "icon-\(rendition).png").path(percentEncoded: false),
      "--platform", "macOS", "--rendition", rendition, "--width", "512", "--height", "512",
      "--scale", "1",
    ]
    let output = Pipe()
    ictool.standardOutput = output
    try! ictool.run()
    // 没问题时只打一个空的 {}；有诊断（组太多、图片找不到……）就原样打出来
    let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ictool.waitUntilExit()
    if ictool.terminationStatus != 0 || report.filter({ !$0.isWhitespace }) != "{}" {
      print("ictool \(rendition)：", report)
    }
  }
}
