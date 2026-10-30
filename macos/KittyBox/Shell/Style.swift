// Whisker 设计刻度：从 Kitty Tools 的 Shell/Style.swift 摘出 Kitty Box 用得上的部分，刻度值保持一致（mac-whisker.mdc §2–4、§7）：
// 圆角、命名弹簧曲线、动态色、悬停色、选中色、发丝线（Hairline）、卡片表面、种类色块、品牌粉主按钮（BrandButtonStyle），
// 加四类工具的家族色。强调色跟随系统：系统是「多色」时就是 AccentColor.colorset 的品牌粉（不拷 Kitty Tools 的 Accent.swift）。
// 界面里的圆角、曲线、颜色一律从这里取，不硬编码；Kitty Tools 那边有、这里还没用到的（输入框、空状态、危险色…）用到时再照搬。

import AppKit
import SwiftUI

enum Style {
  // MARK: 圆角（一律 continuous）

  enum Radius {
    /// 工具页的拖放区、拖着经过时整页的描边、对比图的外框
    static let panel: CGFloat = 16
    /// 卡片、输入框、选中高亮
    static let card: CGFloat = 10
    /// 缩略图、对比图上的小标签
    static let control: CGFloat = 6
    /// 色块（App 图标比例）：18 → 4、24 → 5.5、30 → 7、40 → 9
    static func tile(_ side: CGFloat) -> CGFloat { side * 0.225 }
  }

  // MARK: 动效

  /// 「减弱动态效果」（AppKit 侧；SwiftUI 视图读 `@Environment(\.accessibilityReduceMotion)`）
  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// 七条命名曲线（和 Kitty Tools 同参数：SwiftUI `Spring(duration:bounce:)`）
  enum Motion {
    /// 不做动画
    case instant
    /// 键盘驱动的选中高亮
    case snap
    /// 指针驱动的位移、悬停
    case glide
    /// 高度变化、内容交叉淡变、列表插入删除、折叠
    case settle
    /// 小东西出现：对勾、色块
    case pop
    /// 从小长大（Kitty Tools 的刘海岛长出来）
    case island
    /// 缩回
    case retract

    /// (duration, bounce)；instant 为 nil
    var parameters: (duration: Double, bounce: Double)? {
      switch self {
      case .instant: nil
      case .snap: (0.16, 0.15)
      case .glide: (0.26, 0.10)
      case .settle: (0.24, 0)
      case .pop: (0.32, 0.25)
      case .island: (0.42, 0.22)
      case .retract: (0.34, 0)
      }
    }

    /// 减弱动态效果时：snap / glide 变成不做动画，其余变成 0.2 s easeInOut（调用方只改透明度）
    func animation(reduced: Bool = Style.reduceMotion) -> Animation? {
      guard let (duration, bounce) = parameters else { return nil }
      if reduced { return self == .snap || self == .glide ? nil : .easeInOut(duration: 0.2) }
      return .spring(duration: duration, bounce: bounce)
    }
  }

  // MARK: 颜色

  /// 浅色取 light、深色取 dark 的动态色；「增强对比度」时换成 contrast（没给就不变）
  /// nonisolated：取色闭包由 AppKit 在解析颜色的线程上调，SwiftUI 异步渲染动画时也会在显示链接线程上调；
  /// 闭包默认继承主线程隔离的话，一到后台就触发执行器断言闪退（Kitty Tools 2026-09-27 实测）。闭包里只读传进来的颜色和系统开关
  nonisolated static func dynamic(
    light: NSColor, dark: NSColor, contrast: (light: NSColor, dark: NSColor)? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark =
          appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua])
          != nil
        // 高对比外观按名字匹配不到（NSAppearance 会归到普通外观），直接读系统开关；开关一变系统会重画
        if let contrast, NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
          return isDark ? contrast.dark : contrast.light
        }
        return isDark ? dark : light
      })
  }

  /// 强调色（品牌粉 #FF4D7E，系统选了别的强调色就跟它）：主按钮、侧边栏选中、当前该操作的东西
  static let brand = Color.accentColor
  /// 强调色填充上的字和符号
  static let onBrand = Color.white
  /// 品牌奶油底（#FFF5F0 / 深 #2A1D22）：关于窗口的底色
  static let brandCream = dynamic(
    light: NSColor(red: 1, green: 0.961, blue: 0.941, alpha: 1),
    dark: NSColor(red: 0.165, green: 0.114, blue: 0.133, alpha: 1))
  /// 列表选中（一块灰色高亮，文字不反白）：侧边栏在窗口不是 key 时
  static let selectedFill = dynamic(
    light: .black.withAlphaComponent(0.07), dark: .white.withAlphaComponent(0.10),
    contrast: (.black.withAlphaComponent(0.16), .white.withAlphaComponent(0.22)))
  /// 停用时自绘控件乘的透明度
  static let disabledOpacity: Double = 0.35
  /// 悬停
  static let hoverFill = dynamic(
    light: .black.withAlphaComponent(0.04), dark: .white.withAlphaComponent(0.05))
  /// 发丝线的颜色（增强对比度时 0.25，线宽由 hairlineBorder 换成 1 pt）
  static let hairline = dynamic(
    light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.10),
    contrast: (.black.withAlphaComponent(0.25), .white.withAlphaComponent(0.25)))
  /// 发丝线宽：平时 0.5 pt，增强对比度 1 pt
  static func hairlineWidth(_ contrast: ColorSchemeContrast) -> CGFloat {
    contrast == .increased ? 1 : 0.5
  }
  /// 降低透明度时自绘的卡片垫 0.9 不透明底：只给 15 的毛玻璃；macOS 26 起玻璃自己变实，不再垫
  static func opaqueUnderlay(reduceTransparency: Bool) -> Bool {
    if #available(macOS 26, *) { return false }
    return reduceTransparency
  }

  /// 四类工具的家族色：侧边栏和页头的色块、拖放区、拖着经过时的描边共用（去水印的三项同一个色）
  enum Family {
    static let pack = Color(nsColor: .systemOrange)
    static let unpack = Color(nsColor: .systemGreen)
    static let convert = Color(nsColor: .systemBlue)
    static let watermark = Color(nsColor: .systemPurple)
  }
}

/// 种类色块：视觉重量和 App 图标一致（Kitty Tools 同名视图，只留系统符号）
struct KindTile: View {
  let symbol: String
  let color: Color
  var size: CGFloat = 24

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.tile(size), style: .continuous)
    Image(systemName: symbol)
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        shape.fill(
          LinearGradient(
            colors: [color.opacity(0.95), color.mix(with: .black, by: 0.18)], startPoint: .top,
            endPoint: .bottom))
      )
      .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
      .accessibilityHidden(true)
  }
}

/// 发丝线（分隔线）：横线（vertical 时竖线），0.5 pt `Style.hairline`，增强对比度时 1 pt。长度由外面定
struct Hairline: View {
  var vertical = false
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let width = Style.hairlineWidth(contrast)
    Style.hairline.frame(width: vertical ? width : nil, height: vertical ? nil : width)
      .accessibilityHidden(true)
  }
}

/// 品牌粉主按钮（照 Kitty Tools）：胶囊、强调色底、白字，高度和旁边的系统按钮一样（15 上 20、26 起 24），
/// 按下缩一点。每页一个，放在页头最右（打包、转成 JPEG、去掉角标、存储、导出）
struct BrandButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  /// 常规档的高和字往上让多少：15 上系统按钮的字在 20 高里偏上 1 pt，让 2 pt 并排时基线才齐；26 起居中
  private static let regular: (height: CGFloat, lift: CGFloat) = {
    if #available(macOS 26, *) { (24, 0) } else { (20, 2) }
  }()

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .lineLimit(1)
      .fontWeight(.medium)
      .foregroundStyle(Style.onBrand)
      .padding(.horizontal, 12)
      .padding(.bottom, Self.regular.lift)
      .frame(minHeight: Self.regular.height)
      .background(Style.brand, in: .capsule)
      .contentShape(.capsule)
      .opacity(isEnabled ? 1 : Style.disabledOpacity)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

extension InsettableShape {
  /// 沿形状内侧描一圈发丝线：0.5 pt（增强对比度 1 pt）
  func hairlineBorder(_ color: Color = Style.hairline) -> some View {
    HairlineBorder(shape: self, color: color)
  }
}

private struct HairlineBorder<S: InsettableShape>: View {
  let shape: S
  let color: Color
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    shape.strokeBorder(color, lineWidth: Style.hairlineWidth(contrast)).allowsHitTesting(false)
  }
}

/// 内容卡片表面（Whisker §2）：圆角 card；浅色 white 0.55、深色 white 0.06 底 + 发丝线描边 + 深色的顶部高光；
/// 不加阴影（§3 层级：卡片不加阴影）。降低透明度时底换成 windowBackground 0.9（只在 15；26 交给玻璃）
struct CardSurface: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    let dark = scheme == .dark
    let opaque = Style.opaqueUnderlay(reduceTransparency: reduceTransparency)
    content
      .background {
        shape.fill(
          opaque
            ? Color(nsColor: .windowBackgroundColor).opacity(0.9)
            : .white.opacity(dark ? 0.06 : 0.55))
      }
      .overlay {
        shape.hairlineBorder()
        if dark {
          shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            .mask(
              LinearGradient(
                stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.4)],
                startPoint: .top, endPoint: .bottom)
            )
            .allowsHitTesting(false)
        }
      }
  }
}

extension View {
  /// 内容卡片表面，见 `CardSurface`
  func cardSurface() -> some View { modifier(CardSurface()) }
}

extension View {
  /// 画布上浮着的一条控制栏（画笔擦除、视频台标）：胶囊形，26 起是玻璃，15 是厚材质 + 发丝线 + 阴影
  @ViewBuilder func floatingBar() -> some View {
    let padded = padding(.horizontal, 14).padding(.vertical, 8)
    if #available(macOS 26, *) {
      padded.glassEffect(.regular, in: Capsule())
    } else {
      padded
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().hairlineBorder() }
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
  }
}
