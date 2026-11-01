import SwiftUI

struct MarkdownTableLayout: Layout {
  let columnCount: Int
  var maximumColumnWidth: CGFloat? = nil

  struct Cache {
    var idealWidths: [CGFloat]
    var width: CGFloat?
    var maximumColumnWidth: CGFloat?
    var frames: [CGRect] = []
    var size: CGSize = .zero
  }

  func makeCache(subviews: Subviews) -> Cache {
    var widths = Array(repeating: CGFloat.zero, count: columnCount)
    guard columnCount > 0 else { return Cache(idealWidths: widths) }
    for (index, cell) in subviews.enumerated() {
      let column = index % columnCount
      widths[column] = max(widths[column], cell.sizeThatFits(.unspecified).width)
    }
    return Cache(idealWidths: widths)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    guard columnCount > 0 else { return .zero }
    var widths = cache.idealWidths.map { min($0, maximumColumnWidth ?? .infinity) }
    let idealWidth = widths.reduce(0, +)
    let width = max(0, min(proposal.width ?? idealWidth, idealWidth))
    if cache.width == width && cache.maximumColumnWidth == maximumColumnWidth { return cache.size }

    // Keep short columns at their natural width and share the rest among wrapping columns.
    var remaining = width
    for (offset, column) in widths.indices.sorted(by: { widths[$0] < widths[$1] }).enumerated() {
      widths[column] = min(widths[column], remaining / CGFloat(columnCount - offset))
      remaining = max(0, remaining - widths[column])
    }

    var frames: [CGRect] = []
    var y: CGFloat = 0
    for start in stride(from: 0, to: subviews.count, by: columnCount) {
      let end = min(start + columnCount, subviews.count)
      let height = (start..<end).map { index in
        subviews[index].sizeThatFits(
          ProposedViewSize(width: widths[index - start], height: nil)
        ).height
      }.max() ?? 0
      var x: CGFloat = 0
      for index in start..<end {
        let cellWidth = widths[index - start]
        frames.append(CGRect(x: x, y: y, width: cellWidth, height: height))
        x += cellWidth
      }
      y += height
    }
    cache.width = width
    cache.maximumColumnWidth = maximumColumnWidth
    cache.frames = frames
    cache.size = CGSize(width: widths.reduce(0, +), height: y)
    return cache.size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    _ = sizeThatFits(
      proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews, cache: &cache)
    for (cell, frame) in zip(subviews, cache.frames) {
      cell.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading, proposal: ProposedViewSize(width: frame.width, height: frame.height))
    }
  }
}
