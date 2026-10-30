// 视频台标（D4–D6）：拖进一段视频，第一帧铺在中间，在上面拖出台标的位置（可以框几处，框角的 × 删掉一处），点「导出」。
// 导出好了画面换成前后对比（原视频和导出的第一帧，拖中间的线看），页头「对比」关掉接着框。
// 页头：换一个视频、清空框、对比、导出；底下状态栏写框了几处、导出进度和结果。
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

  var busy: Bool {
    switch state {
    case .loading, .exporting: true
    default: false
    }
  }

  func load(_ url: URL) {
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
        state = .failed("读不出这段视频：" + error.localizedDescription)
      }
    }
  }

  func export() async {
    guard let source, !rects.isEmpty, !busy else { return }
    state = .exporting(0)
    do {
      let url = try await VideoDelogo.export(source, rects: rects) { fraction in
        Task { @MainActor in
          if case .exporting = self.state { self.state = .exporting(fraction) }
        }
      }
      resultFrame = try? await VideoDelogo.firstFrame(of: url)
      comparing = resultFrame != nil
      state = .done(url)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }
}

struct VideoMarkView: View {
  @Bindable var model: VideoMarkModel
  /// 正在拖的框（视图坐标）
  @State private var draft: CGRect?

  var body: some View {
    ToolPage(tool: .video) {
      Button("换一个视频…", systemImage: "film.stack") { Navigator.shared.importing = true }
        .help("换一个视频（⌘O）")
        .disabled(model.busy)
      Button("清空框", systemImage: "trash") { model.rects = [] }
        .help("清空框好的位置")
        .disabled(model.rects.isEmpty || model.busy || model.comparing)
      Toggle("对比", systemImage: "rectangle.split.2x1", isOn: $model.comparing)
        .toggleStyle(.button)
        .help("拖中间的线对比原视频和导出的（第一帧）")
        .disabled(model.resultFrame == nil)
      Button("导出") { Task { await model.export() } }
        .buttonStyle(BrandButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(model.rects.isEmpty || model.busy)
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
        Button("删掉这个框", systemImage: "xmark.circle.fill", action: remove)
          .labelStyle(.iconOnly).buttonStyle(.borderless)
          .foregroundStyle(.white, Color.accentColor)
          .offset(x: 8, y: -8)
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
