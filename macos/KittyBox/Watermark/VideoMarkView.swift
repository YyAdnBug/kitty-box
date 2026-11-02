// 视频台标（D4–D6）：拖进一段视频，第一帧铺在中间，在上面拖出台标的位置（可以框几处，框角的 × 删掉一处），点「导出」。
// 导出好了画面换成前后对比（原视频和导出的第一帧，拖中间的线看），页头「对比」关掉接着框。
// 页头：换一个视频、清空框、对比、导出（导出时换成「停止」，导了一半的不留）；底下状态栏写框了几处、导出进度和结果。
// 框存的是第一帧的像素坐标（左上为原点），画面按比例缩放显示，拖的时候换算回去。

import AppKit
import Observation
import SwiftUI

@Observable final class VideoMarkModel {
  enum State {
    case idle
    case loading
    case exporting(Double)
    case done(URL)
    case failed(String)
  }

  private(set) var source: URL?
  private(set) var frame: CGImage?
  /// 导出好的视频的第一帧：和 frame 拖线对比
  private(set) var resultFrame: CGImage?
  /// 画面上是不是在前后对比（导出好了自动打开；关掉才能接着框）
  var comparing = false
  /// 第一帧上的像素坐标，左上为原点
  var rects: [CGRect] = []
  private(set) var state = State.idle
  /// 正在导出的那一次（「停止」取消它）
  @ObservationIgnored private var exporting: Task<Void, Never>?

  var busy: Bool {
    switch state {
    case .loading, .exporting: true
    default: false
    }
  }

  /// 关掉这一段（读不出时回到空着的样子）
  func clear() {
    source = nil
    frame = nil
    resultFrame = nil
    comparing = false
    rects = []
    state = .idle
  }

  func load(_ url: URL) {
    // 导出时换视频，进度和结果会落到新视频上：先「停止」（页头「换一个视频…」同样灰着；拖进来、⌘O、访达右键都走这里）
    if case .exporting = state {
      NSSound.beep()
      return
    }
    source = url
    frame = nil
    resultFrame = nil
    comparing = false
    rects = []
    state = .loading
    Task {
      do {
        let image = try await VideoDelogo.firstFrame(of: url)
        guard source == url else { return }
        frame = image
        state = .idle
      } catch {
        guard source == url else { return }
        state = .failed("读不出这段视频：" + error.localizedDescription)
      }
    }
  }

  func export() {
    guard let source, !rects.isEmpty, !busy else { return }
    state = .exporting(0)
    let rects = rects
    exporting = Task {
      do {
        let url = try await ProcessInfo.processInfo.working("正在导出视频") {
          try await VideoDelogo.export(source, rects: rects) { fraction in
            Task { @MainActor in
              if case .exporting = self.state { self.state = .exporting(fraction) }
            }
          }
        }
        resultFrame = try? await VideoDelogo.firstFrame(of: url)
        comparing = resultFrame != nil
        state = .done(url)
        NSApp.finished("导出好了「\(url.lastPathComponent)」")
      } catch {
        // 停下的：导了一半的文件已经删了，回到能接着框的样子
        state = Task.isCancelled ? .idle : .failed(error.localizedDescription)
        if !Task.isCancelled { NSApp.finished("没导出成：" + error.localizedDescription) }
      }
    }
  }

  /// 停下正在导出的
  func stop() { exporting?.cancel() }

  /// 正在导出（退出 App 前要问；读第一帧不算）
  var isExporting: Bool { if case .exporting = state { true } else { false } }

  /// 退出 App 前：停下，等导了一半的文件删掉
  func stopAndWait() async {
    stop()
    await exporting?.value
  }
}

struct VideoMarkView: View {
  @Bindable var model: VideoMarkModel
  /// 正在拖的框（视图坐标）
  @State private var draft: CGRect?

  var body: some View {
    ToolPage(tool: .video) {
      Button("换一个视频…", systemImage: "plus") { Navigator.shared.importing = true }
        .help("换一个视频（⌘O）")
        .disabled(model.busy)
      Button("清空框", systemImage: "trash") { model.rects = [] }
        .help("清空框好的位置")
        .disabled(model.rects.isEmpty || model.busy || model.comparing)
      Toggle("对比", systemImage: "rectangle.split.2x1", isOn: $model.comparing)
        .toggleStyle(.button)
        .help("拖中间的线对比原视频和导出的（第一帧）")
        .disabled(model.resultFrame == nil)
      if case .exporting = model.state {
        Button("停止") { model.stop() }
          .buttonStyle(BrandButtonStyle())
          .help("停下导出，导了一半的文件不留")
      } else {
        Button("导出") { model.export() }
          .buttonStyle(BrandButtonStyle())
          .keyboardShortcut(.defaultAction)
          .disabled(model.rects.isEmpty || model.busy)
      }
    } content: {
      if model.source == nil {
        DropZone(
          tool: .video, title: "拖入视频",
          detail: "一次一段；可以框几处，编码跟原视频走，结果另存成「原名-去水印」")
      } else if let frame = model.frame {
        if model.comparing, let after = model.resultFrame {
          CompareSlider(before: frame, after: after).padding(20)
        } else {
          canvas(frame).padding(20)
        }
      } else if case .failed(let reason) = model.state {
        LoadFailed(reason: reason, again: "换一个视频…") { model.clear() }
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } status: {
      status
      Spacer(minLength: 8)
      if case .exporting(let fraction) = model.state {
        ProgressView(value: fraction).frame(width: 120)
        Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
      }
    }
  }

  // MARK: 画面和框

  private func canvas(_ frame: CGImage) -> some View {
    GeometryReader { geometry in
      let size = CGSize(width: frame.width, height: frame.height)
      let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
      let origin = CGPoint(
        x: (geometry.size.width - size.width * scale) / 2,
        y: (geometry.size.height - size.height * scale) / 2)
      let toView = { (rect: CGRect) in
        CGRect(
          x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
          width: rect.width * scale, height: rect.height * scale)
      }
      ZStack(alignment: .topLeading) {
        Image(decorative: frame, scale: 1)
          .resizable()
          .frame(width: size.width * scale, height: size.height * scale)
          .clipShape(RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
          .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
          .offset(x: origin.x, y: origin.y)
        ForEach(Array(model.rects.enumerated()), id: \.offset) { index, rect in
          box(toView(rect)) { model.rects.remove(at: index) }
        }
        if let draft { box(draft, remove: nil) }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { drag in
            draft = CGRect(
              x: min(drag.startLocation.x, drag.location.x),
              y: min(drag.startLocation.y, drag.location.y),
              width: abs(drag.location.x - drag.startLocation.x),
              height: abs(drag.location.y - drag.startLocation.y))
          }
          .onEnded { _ in
            defer { draft = nil }
            guard let draft else { return }
            // 视图坐标 → 第一帧的像素，夹在画面里
            let pixel = CGRect(
              x: (draft.minX - origin.x) / scale, y: (draft.minY - origin.y) / scale,
              width: draft.width / scale, height: draft.height / scale
            ).intersection(CGRect(origin: .zero, size: size)).integral
            if pixel.width >= 2, pixel.height >= 2 { model.rects.append(pixel) }
          }
      )
      .disabled(model.busy)
    }
  }

  /// 一个框：强调色描边 + 淡底；右上角一个 × 删掉
  private func box(_ rect: CGRect, remove: (() -> Void)?) -> some View {
    ZStack(alignment: .topTrailing) {
      Rectangle().fill(Color.accentColor.opacity(0.18))
      Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5)
      if let remove {
        // 点得到的地方 22 pt 见方（图标本身只有十来个点），中心还在框角上
        Button(action: remove) {
          Image(systemName: "xmark.circle.fill").frame(width: 22, height: 22).contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white, Color.accentColor)
        .accessibilityLabel("删掉这个框").help("删掉这个框")
        .offset(x: 11, y: -11)
      }
    }
    .frame(width: rect.width, height: rect.height)
    .offset(x: rect.minX, y: rect.minY)
  }

  // MARK: 底部

  @ViewBuilder private var status: some View {
    switch model.state {
    case .exporting:
      Text("正在导出，逐帧补上框住的地方…")
    case .done(let url):
      DoneLine(text: "存成「\(url.lastPathComponent)」", url: url)
    case .failed(let reason):
      FailLine(reason: reason)
    case .idle, .loading:
      Text(
        [
          model.source?.lastPathComponent,
          model.rects.isEmpty ? "在画面上拖出台标的位置，可以框几处" : "框了 \(model.rects.count) 处",
          "编码跟原视频走，原视频不动",
        ].compactMap(\.self).joined(separator: " · "))
    }
  }
}
