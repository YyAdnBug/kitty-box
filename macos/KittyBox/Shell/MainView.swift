// 主窗口（A1、A2，2026-10-30 改成侧边栏）：左边侧边栏按「压缩」「转换」「修图」分组列出八个工具（家族色块 + 名字，还有没处理完的
// 数一个角标；色块按组上色：棕、蓝、靛蓝一族，组里一个工具一个邻近色，Style.Family），右边是选中的工具页（ToolPage）。照 Kitty Tools 的设置窗：侧边栏不能收起（没有收起按钮），选中自己画成品牌粉；
// 窗口工具栏什么都不放、不画底色、不显示标题，标题和操作都在各页的页头里——这样顶上一条只有侧边栏和窗口底两种颜色。
// 侧边栏也拖不收、⌃⌘S 也不收（SidebarLock）：页头和红绿灯在同一排，收起来红绿灯就压在页头的色块上（2026-11-03 用户报）。
// 侧栏选中自己画（SidebarRow）：AppKit 画侧栏选中会把强调色压深（品牌粉变暗红），同 Kitty Tools 关掉原生高亮
// （NativeHighlightOff）再按系统同样的几何画一块。
// 文件拖到侧边栏的某一项就交给那个工具；收到不知道给谁的文件时弹出来问（Navigator.pending）。
// 「添加文件…」统一在这里弹选文件（Navigator.importing），选好交给当前工具。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable, Hashable {
  case pack, unpack, convert, videoConvert, cutout, aiMark, erase, video

  var id: Self { self }

  var title: String {
    switch self {
    case .pack: "打包"
    case .unpack: "解压"
    case .convert: "图片转换"
    case .videoConvert: "视频转换"
    case .cutout: "去背景"
    case .aiMark: "AI 水印"
    case .erase: "画笔擦除"
    case .video: "视频台标"
    }
  }

  /// 描边的基础名：菜单里就是描边版，色块（KindTile）里套成实心。都是 macOS 15 就有的名字
  var symbol: String {
    switch self {
    case .pack: "archivebox"
    case .unpack: "arrow.up.bin"
    case .convert: "photo.on.rectangle.angled"
    case .videoConvert: "play.rectangle.on.rectangle"
    // 访达「去除背景」快速操作用的同一个
    case .cutout: "circle.rectangle.filled.pattern.diagonalline"
    case .aiMark: "sparkles"
    // 「照片」的「清理」也是橡皮擦
    case .erase: "eraser"
    // 画面右上角填实一块：角上的台标
    case .video: "inset.filled.topright.rectangle"
    }
  }

  var color: Color {
    switch self {
    case .pack: Style.Family.pack
    case .unpack: Style.Family.unpack
    case .convert: Style.Family.convert
    case .videoConvert: Style.Family.videoConvert
    case .cutout: Style.Family.cutout
    case .aiMark: Style.Family.aiMark
    case .erase: Style.Family.erase
    case .video: Style.Family.video
    }
  }

  /// 选文件时能选什么、能不能一次选好几个
  var contentTypes: [UTType] {
    switch self {
    case .pack: [.item, .folder]
    case .unpack: [.item]
    case .convert, .cutout, .aiMark, .erase: [.image]
    case .video, .videoConvert: [.movie]
    }
  }

  var takesMany: Bool { self != .erase && self != .video }

  /// 页头标题下面的一句话：最小窗口（940 宽）里也放得下，不被截掉
  var summary: String {
    switch self {
    case .pack: "打成 zip 或 7z，可设密码，自动去掉系统杂文件"
    case .unpack: "zip、7z、RAR 等都能解，中文名不乱码"
    case .convert: "HEIC、WebP、RAW 等互转，拍摄信息带过去"
    case .videoConvert: "转成 MP4、HEVC、GIF，或只取声音"
    case .cutout: "自动抠出主体，背景换成透明或白色"
    case .aiMark: "一批图自动去掉 AI 水印，也能去掉指定的字"
    case .erase: "涂住水印、路人或杂物，或点选图上的字，松手就自动补上周围的样子"
    case .video: "在画面上框住固定的台标，导出时逐帧补上"
    }
  }

  /// 侧边栏的分组
  enum Shelf: String, CaseIterable, Identifiable {
    case archive = "压缩"
    case convert = "转换"
    case retouch = "修图"

    var id: Self { self }

    var tools: [Tool] {
      switch self {
      case .archive: [.pack, .unpack]
      case .convert: [.convert, .videoConvert]
      case .retouch: [.cutout, .aiMark, .erase, .video]
      }
    }
  }
}

struct MainView: View {
  /// 平时就是 Navigator.shared；截图自检传自己的进来
  @Bindable var navigator = Navigator.shared
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        ForEach(Tool.Shelf.allCases) { shelf in
          Section(shelf.rawValue) {
            ForEach(shelf.tools) { tool in
              SidebarRow(tool: tool, isSelected: navigator.tool == tool, badge: badge(tool)) {
                navigator.open(tool, with: $0)
              }
              .tag(tool)
            }
          }
        }
      }
      // 标题栏是透明的（KittyBoxApp）：侧边栏顶上红绿灯那一排按住能拖窗口、双击缩放
      .overlay(alignment: .top) { Color.clear.frame(height: 28).windowDragArea() }
      .background(SidebarLock())
      .toolbar(removing: .sidebarToggle)
      .safeAreaInset(edge: .bottom) {
        if let release = Updater.shared.available { updateCard(release) }
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    } detail: {
      page
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileDrop(navigator.tool.color) { navigator.give($0) }
    }
    .fileImporter(
      isPresented: $navigator.importing, allowedContentTypes: navigator.tool.contentTypes,
      allowsMultipleSelection: navigator.tool.takesMany
    ) {
      if case .success(let urls) = $0 { navigator.open(navigator.tool, with: urls) }
    }
    .confirmationDialog(pendingTitle, isPresented: asking, titleVisibility: .visible) {
      ForEach(Tool.allCases.filter { navigator.accepts($0, navigator.pending) }) { tool in
        Button(tool.title) { navigator.open(tool, with: navigator.pending) }
      }
      Button("取消", role: .cancel) { navigator.pending = [] }
    }
    .toolbar(removing: .sidebarToggle)
    .toolbar(removing: .title)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .frame(minWidth: 940, minHeight: 560)
    .onAppear { navigator.openWindow = openWindow }
  }

  @ViewBuilder private var page: some View {
    switch navigator.tool {
    case .pack: PackView(model: navigator.pack)
    case .unpack: UnpackView(model: navigator.unpack)
    case .convert: ConvertView(model: navigator.convert)
    case .videoConvert: VideoConvertView(model: navigator.videoConvert)
    case .cutout: CutoutView(batch: navigator.cutout)
    case .aiMark: AIMarkView(batch: navigator.aiMark) { navigator.open(.erase, with: [$0]) }
    case .erase: EraseCanvas(model: navigator.erase)
    case .video: VideoMarkView(model: navigator.video)
    }
  }

  private var selection: Binding<Tool?> {
    Binding(get: { navigator.tool }, set: { if let tool = $0 { navigator.tool = tool } })
  }

  private var asking: Binding<Bool> {
    Binding(get: { !navigator.pending.isEmpty }, set: { if !$0 { navigator.pending = [] } })
  }

  private var pendingTitle: String {
    navigator.pending.count == 1
      ? "把「\(navigator.pending[0].lastPathComponent)」交给哪个工具？"
      : "把这 \(navigator.pending.count) 个文件交给哪个工具？"
  }

  /// 侧边栏的角标：还没处理的有几个（0 不显示）
  private func badge(_ tool: Tool) -> Int {
    switch tool {
    // 打好了就不算没处理的（表格里的还留着，看得到打了哪些）
    case .pack: if case .success = navigator.pack.result { 0 } else { navigator.pack.items.count }
    case .unpack: navigator.unpack.jobs.count { !$0.isFinished }
    case .convert: navigator.convert.items.count { $0.result == nil }
    case .videoConvert: navigator.videoConvert.items.count { $0.result == nil }
    case .cutout: navigator.cutout.items.count { $0.result == nil }
    case .aiMark: navigator.aiMark.items.count { $0.result == nil }
    case .erase, .video: 0
    }
  }

  /// 有新版本时侧边栏底下的一张小卡，点了打开关于窗口
  private func updateCard(_ release: Updater.Release) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
      Text("有新版本 \(release.version)").lineLimit(1)
      Spacer(minLength: 4)
      Button("看看") { openWindow(id: KittyBoxApp.aboutID) }
    }
    .font(.system(size: 12))
    .controlSize(.small)
    .padding(10)
    .cardSurface()
    .padding(10)
  }
}

/// 侧边栏的一项：家族色块 + 名字 + 还没处理的数目；文件拖上来交给它，拖着经过时垫一层家族色。
/// 选中：窗口是 key 时品牌粉填充 + 白字，不是 key 时中性 selectedFill + 侧栏原来的字色（同 Kitty Tools 设置窗）。
/// 选中块画在行里（去掉行的内缩，左右各留 10）：27 上侧栏的 listRowBackground 不画（2026-10-30 实测），角标也自己画，好在粉底上变白
private struct SidebarRow: View {
  let tool: Tool
  let isSelected: Bool
  let badge: Int
  let drop: ([URL]) -> Void
  @State private var targeted = false
  @Environment(\.controlActiveState) private var activeState
  /// 系统设置 › 外观「侧边栏图标大小」：字跟着系统变，色块和行高也跟着
  @Environment(\.sidebarRowSize) private var rowSize

  var body: some View {
    let emphasized = isSelected && activeState == .key
    let (tile, height): (CGFloat, CGFloat) =
      switch rowSize {
      case .small: (16, 24)
      case .large: (24, 36)
      default: (20, 30)
      }
    HStack(spacing: 8) {
      KindTile(symbol: tool.symbol, color: tool.color, size: tile)
      // 只在品牌粉上设字色：显式设了前景会盖掉侧栏自己的字色（后台窗口变灰那套）
      if emphasized {
        Text(tool.title).foregroundStyle(Style.onBrand)
      } else {
        Text(tool.title)
      }
      Spacer(minLength: 4)
      if badge > 0 {
        Text(badge.formatted())
          .font(.system(size: 11, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(emphasized ? Style.onBrand : Color.secondary)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: height)
    .background { highlight(emphasized: emphasized) }
    .contentShape(Rectangle())
    .background(NativeHighlightOff())
    .padding(.horizontal, 10)
    .listRowInsets(EdgeInsets())
    .accessibilityElement(children: .combine)
    // 角标不并进名字（旁白只念「打包，2」），当成值念出来是什么
    .accessibilityValue(badge > 0 ? "\(badge) 个没做完" : "")
    .dropDestination(for: URL.self) { urls, _ in
      drop(urls)
      return true
    } isTargeted: {
      targeted = $0
    }
  }

  @ViewBuilder private func highlight(emphasized: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    if targeted {
      shape.fill(tool.color.opacity(0.3))
    } else if isSelected {
      shape.fill(emphasized ? Style.brand : Style.selectedFill)
    }
  }
}

/// 侧边栏收不起来：拖分隔线拖到头就停在最窄，「隐藏边栏」也不动（NSSplitViewItem.canCollapse 管这两样）。
/// 只去掉收起按钮不够：拖过头照样收起来，各页的页头就顶到最左边、压在红绿灯下面（hiddenTitleBar，页头和红绿灯一排）。
/// SwiftUI 每次更新（比如换工具）都把 canCollapse 改回 true，所以盯着它，一改回来就再关上。
/// 不用 columnVisibility 收起后马上放回来：放回来时窗口会被撑宽一个侧边栏（2026-11-03 实测 1040 → 1250）。
/// ponytail: 依赖 NavigationSplitView 由 NSSplitViewController 实现（同 NativeHighlightOff）；哪天找不到又收得起来，
/// 那时改成收起时页头让开红绿灯
private struct SidebarLock: NSViewRepresentable {
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {}

  final class Probe: NSView {
    private var watch: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard watch == nil,
        let sidebar = sequence(first: self as NSView, next: \.superview).lazy
          .compactMap({ ($0 as? NSSplitView)?.delegate as? NSSplitViewController }).first?
          .splitViewItems.first
      else { return }
      sidebar.canCollapse = false
      watch = sidebar.observe(\.canCollapse) { item, _ in
        if item.canCollapse { item.canCollapse = false }
      }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// 关掉外面那个 NSTableView（SwiftUI 的侧栏 List 在 macOS 上就是它）的原生选中高亮（照 Kitty Tools），顺带让它当窗口一打开的焦点。
/// 每行挂一个，行建出来时设一次。
/// ponytail: 依赖 List 由 NSTableView 实现；哪天不是了就找不到，原生高亮回来垫在自绘那块下面，那时改成自己画行 + 键盘导航
private struct NativeHighlightOff: NSViewRepresentable {
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) { view.apply() }

  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    /// 不接鼠标：点选照旧交给表格
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply() {
      guard
        let table = sequence(first: self as NSView, next: \.superview).lazy
          .compactMap({ $0 as? NSTableView }).first
      else { return }
      table.selectionHighlightStyle = .none
      // 一打开焦点在侧边栏（↑↓ 换工具，同系统设置），不落进页里的第一个输入框：打包页的密码框会亮起一圈，
      // ⌘V 也会贴进去。SwiftUI 的 defaultFocus 管不住（2026-10-30 实测），用 AppKit 的 initialFirstResponder
      if let window = table.window, window.initialFirstResponder == nil {
        window.initialFirstResponder = table
        if window.firstResponder === window || window.firstResponder is NSText {
          window.makeFirstResponder(table)
        }
      }
    }
  }
}
