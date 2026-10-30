// 去水印前后对比（Gemini 角标、画笔擦除、视频台标共用）：两张一样大的图叠在一起，中间一条竖线，线左边露原图、右边是去掉之后的；
// 在图上任意处按下左右拖都能挪线。照常见修图工具的样子：线上一个圆把手，左上「原图」、右上「去水印后」两个小标签，线挪到边上时那一侧的标签隐去。

import SwiftUI

struct CompareSlider: View {
  let before: CGImage
  let after: CGImage
  /// 线的位置：0 全是去掉之后的，1 全是原图
  @State private var split: CGFloat = 0.5

  var body: some View {
    GeometryReader { geometry in
      let image = CGSize(width: after.width, height: after.height)
      let scale = min(geometry.size.width / image.width, geometry.size.height / image.height)
      let size = CGSize(width: image.width * scale, height: image.height * scale)
      let x = size.width * split
      ZStack(alignment: .topLeading) {
        Image(decorative: after, scale: 1).resizable()
        Image(decorative: before, scale: 1).resizable()
          .mask(alignment: .leading) { Rectangle().frame(width: x) }
        Rectangle()
          .fill(.white)
          .frame(width: 2)
          .shadow(color: .black.opacity(0.35), radius: 2)
          .offset(x: x - 1)
        Image(systemName: "arrow.left.and.right")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.black.opacity(0.7))
          .frame(width: 30, height: 30)
          .background(.white, in: Circle())
          .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
          .position(x: x, y: size.height / 2)
        HStack {
          tag("原图").opacity(split > 0.12 ? 1 : 0)
          Spacer()
          tag("去水印后").opacity(split < 0.88 ? 1 : 0)
        }
        .padding(8)
      }
      .frame(width: size.width, height: size.height)
      .clipShape(RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged {
          split = min(max($0.location.x / size.width, 0), 1)
        }
      )
      .pointerStyle(.columnResize)
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .accessibilityRepresentation {
      Slider(value: $split, in: 0...1) { Text("原图露出多少") }
    }
  }

  private func tag(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        .black.opacity(0.5),
        in: RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous))
  }
}
