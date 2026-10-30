#!/usr/bin/env swift
// 品牌图标生成脚本：照 Kitty Tools 的 brand-icons.swift（同一只小黑猫「探头」），把它扒着的剪贴板卡片换成纸箱、
// 底板换成青绿（和 Kitty Tools 的粉、Kitty Clear 的天蓝分开，程序坞里一眼认得出）。
// 用法：swift macos/brand-icons.swift [预览目录]
// 写入 KittyBox/Resources/Assets.xcassets 的 AppIcon 10 张 PNG（1024 画布、主体 824、四边留 100、超椭圆圆角约 185、
// 烘焙阴影 y 10 / σ 10 / 黑 30%；16、32 像素用手调的简化版），和 Config/dmg-background.tiff（DMG 窗口背景：设计区
// 600 × 400 pt 在左上角，奶油底、字标 Kitty Box、虚点弧线箭头、「仍要打开」路径；整张画布 2560 × 1600 pt，窗口拉大也不露白；
// @1x + @2x，Deflate；改产品名或文案也改这里）。Kitty Box 不在菜单栏，不出 StatusIcon。
// 只用 AppKit / CoreGraphics / CoreText / ImageIO，几何都在这一个文件里：改角色就改这里再跑一遍。给了预览目录时另存放大的预览图。

import AppKit

// MARK: 画布

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
    blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

let ink = hex(0x3A2530)
let cream = hex(0xFFF5F0)
let beans = hex(0xFF9FB8)
let box = hex(0xE8B878)
let boxEdge = hex(0xC98E52)
let tape = hex(0xF4D7A8)

/// 像素画布，坐标原点左上、y 向下，`unit` 个设计单位 = 画布边长
func render(pixels: Int, unit: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x: 0, y: CGFloat(pixels))
  ctx.scaleBy(x: CGFloat(pixels) / unit, y: -CGFloat(pixels) / unit)
  draw(ctx)
  return ctx.makeImage()!
}

func ellipse(
  _ ctx: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor
) {
  ctx.setFillColor(color)
  ctx.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}

func roundRect(
  _ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat,
  _ color: CGColor
) {
  ctx.setFillColor(color)
  ctx.addPath(
    CGPath(
      roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r,
      transform: nil))
  ctx.fillPath()
}

/// 圆角三角形：填充 + 同色圆角描边（耳朵、鼻子）
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

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// 左右对称：给左边的点，镜像出右边（画布中线 = unit / 2）
func mirrored(_ points: [CGPoint], unit: CGFloat) -> [CGPoint] {
  points.map { CGPoint(x: unit - $0.x, y: $0.y) }
}

/// macOS 图标外形：超椭圆（n = 5）近似连续圆角，主体 824、四边留 100 时圆角约 185。
func squircle(center: CGFloat, radius: CGFloat) -> CGPath {
  let path = CGMutablePath()
  let n: CGFloat = 5
  let steps = 256
  for i in 0..<steps {
    let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
    let x = cos(t)
    let y = sin(t)
    let px = center + radius * (x < 0 ? -1 : 1) * pow(abs(x), 2 / n)
    let py = center + radius * (y < 0 ? -1 : 1) * pow(abs(y), 2 / n)
    if i == 0 { path.move(to: point(px, py)) } else { path.addLine(to: point(px, py)) }
  }
  path.closeSubpath()
  return path
}

/// 底板：青绿渐变 + 左上一点柔光 + 烘焙阴影；之后的内容都裁在底板里
func plate(_ ctx: CGContext, unit: CGFloat, pixelsPerUnit: CGFloat, shadow: Bool = true) {
  let shape = squircle(center: unit / 2, radius: unit * 412 / 1024)
  if shadow {
    ctx.saveGState()
    // 阴影参数不跟 CTM 走，按像素给：y 10、σ 10（CG 的 blur 约等于 2σ）
    ctx.setShadow(
      offset: CGSize(width: 0, height: -10 * pixelsPerUnit * unit / 1024),
      blur: 20 * pixelsPerUnit * unit / 1024, color: hex(0x000000, 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(hex(0x1FB5A8))
    ctx.fillPath()
    ctx.restoreGState()
  }
  ctx.addPath(shape)
  ctx.clip()
  let fill = CGGradient(
    colorsSpace: sRGB, colors: [hex(0x63E0D2), hex(0x1FB5A8), hex(0x12958B)] as CFArray,
    locations: [0, 0.55, 1])!
  ctx.drawLinearGradient(
    fill, start: point(0, unit * 100 / 1024), end: point(0, unit * 924 / 1024), options: [])
  let glow = CGGradient(
    colorsSpace: sRGB, colors: [hex(0xFFFFFF, 0.22), hex(0xFFFFFF, 0)] as CFArray,
    locations: [0, 1])!
  ctx.drawRadialGradient(
    glow, startCenter: point(unit * 0.3, unit * 0.2), startRadius: 0,
    endCenter: point(unit * 0.3, unit * 0.2), endRadius: unit * 0.55, options: [])
}

// MARK: 探头（1024 设计单位）

func kitten(_ ctx: CGContext) {
  let u: CGFloat = 1024
  // 耳朵（外黑内粉）：耳尖往外撇，和脸颊之间留出一个缺口（不然头像顶头盔）
  let ear = [point(352, 392), point(296, 204), point(478, 330)]
  triangle(ctx, ear, ink, round: 32)
  triangle(ctx, mirrored(ear, unit: u), ink, round: 32)
  let inner = [point(366, 354), point(338, 260), point(426, 320)]
  triangle(ctx, inner, hex(0xFF7FA0), round: 12)
  triangle(ctx, mirrored(inner, unit: u), hex(0xFF7FA0), round: 12)
  // 头
  ellipse(ctx, 512, 522, 256, 208, ink)
  // 腮红
  ellipse(ctx, 352, 568, 30, 16, hex(0xFF7FA0, 0.8))
  ellipse(ctx, 672, 568, 30, 16, hex(0xFF7FA0, 0.8))
  // 眼睛：奶油色眼白，瞳孔往下看卡片，一大一小两个高光
  for cx: CGFloat in [424, 600] {
    ellipse(ctx, cx, 500, 56, 60, cream)
    ellipse(ctx, cx + 6, 524, 34, 35, ink)
    ellipse(ctx, cx + 21, 507, 11.5, 11.5, hex(0xFFFFFF))
    ellipse(ctx, cx - 8, 541, 5.5, 5.5, hex(0xFFFFFF, 0.9))
  }
  // 鼻子和 ω 嘴
  triangle(ctx, [point(496, 566), point(528, 566), point(512, 585)], hex(0xFF7FA0), round: 10)
  let mouth = CGMutablePath()
  mouth.move(to: point(490, 594))
  mouth.addQuadCurve(to: point(512, 596), control: point(500, 612))
  mouth.addQuadCurve(to: point(534, 594), control: point(524, 612))
  ctx.setStrokeColor(hex(0xFF9FB8))
  ctx.setLineWidth(8)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  ctx.addPath(mouth)
  ctx.strokePath()
  // 纸箱：箱口一圈深色的边、正面、正中一条封箱胶带
  roundRect(ctx, 168, 614, 688, 440, 40, boxEdge)
  roundRect(ctx, 168, 646, 688, 408, 28, box)
  roundRect(ctx, 452, 646, 120, 408, 0, tape)
  // 爪子在箱口压出的一点影子，再画爪子和肉垫
  for cx: CGFloat in [386, 638] {
    ellipse(ctx, cx, 652, 70, 13, hex(0x8A5A2B, 0.35))
    ellipse(ctx, cx, 616, 76, 46, ink)
    for (dx, dy) in [(-26.0, 14.0), (0.0, 21.0), (26.0, 14.0)] as [(CGFloat, CGFloat)] {
      ellipse(ctx, cx + dx, 616 + dy, 10, 9, beans)
    }
  }
}

/// 32 像素手调：头、耳、眼白、纸箱、爪子都对到像素格上（设计单位 = 像素）
func kitten32(_ ctx: CGContext) {
  let u: CGFloat = 32
  let ear = [point(9.3, 14.4), point(9.9, 6.9), point(14.6, 10.6)]
  triangle(ctx, ear, ink, round: 1.2)
  triangle(ctx, mirrored(ear, unit: u), ink, round: 1.2)
  ellipse(ctx, 16, 16, 8.2, 6.6, ink)
  for cx: CGFloat in [13.2, 18.8] {
    ellipse(ctx, cx, 15.3, 1.9, 2, cream)
    ellipse(ctx, cx + 0.2, 16, 1.1, 1.1, ink)
  }
  roundRect(ctx, 5.2, 19.2, 21.6, 14, 1.4, boxEdge)
  roundRect(ctx, 5.2, 20.4, 21.6, 12.8, 1, box)
  roundRect(ctx, 14.2, 20.4, 3.6, 12.8, 0, tape)
  for cx: CGFloat in [12, 20] { ellipse(ctx, cx, 19.3, 2.5, 1.5, ink) }
}

/// 16 像素手调：只留黑头、两只耳朵、两点眼睛和纸箱的上沿
func kitten16(_ ctx: CGContext) {
  let u: CGFloat = 16
  let ear = [point(4.7, 6.6), point(4.8, 3.1), point(7.1, 5)]
  triangle(ctx, ear, ink, round: 0.7)
  triangle(ctx, mirrored(ear, unit: u), ink, round: 0.7)
  ellipse(ctx, 8, 8.4, 4.2, 3.4, ink)
  ellipse(ctx, 6.5, 8, 1, 1, cream)
  ellipse(ctx, 9.5, 8, 1, 1, cream)
  roundRect(ctx, 2.5, 10.5, 11, 7, 0.8, box)
}

func appIcon(pixels: Int) -> CGImage {
  switch pixels {
  case ...16:
    return render(pixels: pixels, unit: 16) {
      plate($0, unit: 16, pixelsPerUnit: CGFloat(pixels) / 16)
      kitten16($0)
    }
  case ...32:
    return render(pixels: pixels, unit: 32) {
      plate($0, unit: 32, pixelsPerUnit: CGFloat(pixels) / 32)
      kitten32($0)
    }
  default:
    return render(pixels: pixels, unit: 1024) {
      plate($0, unit: 1024, pixelsPerUnit: CGFloat(pixels) / 1024)
      kitten($0)
    }
  }
}

// MARK: DMG 窗口背景（600 × 400 pt；访达里 App 在 (150, 205)、「应用程序」在 (450, 205)，见 build-dmg.sh）

func dmgBackground(scale: Int) -> CGImage {
  let brand = hex(0xFF4D7E)
  let ctx = CGContext(
    data: nil, width: 600 * scale, height: 400 * scale, bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x: 0, y: CGFloat(400 * scale))
  ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
  // 奶油底，左上一团品牌粉、右下一团淡蓝紫
  ctx.setFillColor(cream)
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
  ctx.setFillColor(cream)
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

let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let assets = macos.appending(path: "KittyBox/Resources/Assets.xcassets")
let appIconSet = assets.appending(path: "AppIcon.appiconset")
for (points, scale) in [
  (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
] {
  let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
  writePNG(appIcon(pixels: points * scale), to: appIconSet.appending(path: name))
}
// DMG 背景：@1x、@2x 两张合进一个 TIFF（dpi 72 / 144，访达按屏幕倍率挑）。用 ImageIO 写 Deflate：
// 画布大半是纯色，NSBitmapImageRep 只有 LZW，每条带都从头建字典，同一张图大 60%
let dmg = CGImageDestinationCreateWithURL(
  macos.appending(path: "Config/dmg-background.tiff") as CFURL, "public.tiff" as CFString, 2, nil)!
for scale in [1, 2] {
  CGImageDestinationAddImage(
    dmg, dmgCanvasImage(scale: scale),
    [
      kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 8],  // 8 = Adobe Deflate
    ] as CFDictionary)
}
precondition(CGImageDestinationFinalize(dmg))
print("已写入 AppIcon 10 张、DMG 背景 @1x / @2x")

// 预览：大图原样，小图按像素放大 8 倍（不插值），菜单栏放在浅 / 深两条栏上
if CommandLine.arguments.count > 1 {
  let preview = URL(fileURLWithPath: CommandLine.arguments[1])
  try! FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
  writePNG(appIcon(pixels: 1024), to: preview.appending(path: "icon-1024.png"))
  writePNG(dmgBackground(scale: 2), to: preview.appending(path: "dmg-background@2x.png"))
  func magnify(_ image: CGImage, _ factor: Int, background: CGColor?) -> CGImage {
    let ctx = CGContext(
      data: nil, width: image.width * factor, height: image.height * factor, bitsPerComponent: 8,
      bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let background {
      ctx.setFillColor(background)
      ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    return ctx.makeImage()!
  }
  writePNG(
    magnify(appIcon(pixels: 16), 16, background: hex(0xF4EFF1)),
    to: preview.appending(path: "icon-16-x16.png"))
  writePNG(
    magnify(appIcon(pixels: 32), 8, background: hex(0xF4EFF1)),
    to: preview.appending(path: "icon-32-x8.png"))
  writePNG(
    magnify(appIcon(pixels: 64), 4, background: hex(0xF4EFF1)),
    to: preview.appending(path: "icon-64-x4.png"))
}
