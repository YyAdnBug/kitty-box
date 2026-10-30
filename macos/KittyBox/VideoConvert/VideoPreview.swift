// 视频转换页上半的预览（M8，用户问「转换时不能预览吗」「要不要加截取」）：系统的播放器（AVKit 的 AVPlayerView，同 QuickTime：
// 播放、拖进度、逐帧），选中哪一行放哪一个。「剪一段…」打开播放器自带的剪辑条（同 QuickTime 的「修剪」，拖两头的黄把手），
// 点「修剪」就只转这一段（存进那一行的 trim，GIF 也从这一段取）；「不剪了」回到整段。转好的能切到「转换后」看结果。

import AVKit
import SwiftUI

struct VideoPreview: View {
  let item: FileBatch.Item
  let setTrim: (ClosedRange<Double>?) -> Void
  @State private var showsResult = false
  @State private var box = PlayerBox()

  var body: some View {
    VStack(spacing: 0) {
      PlayerView(box: box, url: showing, trim: showsResult ? nil : item.trim)
        .background(.black)
      HStack(spacing: 10) {
        if item.result != nil {
          Picker("看哪个", selection: $showsResult) {
            Text("原视频").tag(false)
            Text("转换后").tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        if let trim = item.trim {
          Label(
            "只转 \(Self.clock(trim.lowerBound)) – \(Self.clock(trim.upperBound))（\(Self.clock(trim.upperBound - trim.lowerBound))）",
            systemImage: "scissors"
          )
          .foregroundStyle(.secondary)
        }
        Spacer()
        if item.trim != nil, !showsResult {
          Button("不剪了") { setTrim(nil) }
        }
        Button("剪一段…", systemImage: "scissors") { Task { await trim() } }
          .help("拖两头的把手选一段，只转这一段")
          .disabled(showsResult)
      }
      .font(.system(size: 12))
      .controlSize(.small)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .onChange(of: item.id) { showsResult = false }
  }

  private var showing: URL { showsResult ? item.result ?? item.source : item.source }

  /// 打开播放器自带的剪辑条；点了「修剪」就记下选的那一段
  private func trim() async {
    guard let view = box.view, view.canBeginTrimming else { return }
    let result = await view.beginTrimming()
    guard result == .okButton, let current = view.player?.currentItem else { return }
    let duration = current.duration.seconds
    let start = current.reversePlaybackEndTime.isValid ? current.reversePlaybackEndTime.seconds : 0
    let end =
      current.forwardPlaybackEndTime.isValid ? current.forwardPlaybackEndTime.seconds : duration
    // 两头都没动：等于整段
    setTrim(start <= 0.01 && end >= duration - 0.01 ? nil : start...end)
  }

  /// 1:05、0:07
  static func clock(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
  }
}

/// 拿得到 AVPlayerView 本身（「剪一段…」要调它的 beginTrimming）
@MainActor private final class PlayerBox {
  weak var view: AVPlayerView?
}

private struct PlayerView: NSViewRepresentable {
  let box: PlayerBox
  let url: URL
  /// 选过的那一段：播放器只放这一段（剪辑条打开时也从这一段起）
  let trim: ClosedRange<Double>?

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .inline
    view.showsFrameSteppingButtons = true
    view.videoGravity = .resizeAspect
    box.view = view
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    box.view = view
    if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
      view.player?.pause()
      view.player = AVPlayer(url: url)
    }
    guard let current = view.player?.currentItem else { return }
    current.reversePlaybackEndTime =
      trim.map { CMTime(seconds: $0.lowerBound, preferredTimescale: 600) } ?? .invalid
    current.forwardPlaybackEndTime =
      trim.map { CMTime(seconds: $0.upperBound, preferredTimescale: 600) } ?? .invalid
  }

  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
    view.player?.pause()
  }
}
