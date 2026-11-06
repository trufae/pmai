import MaiCore
import SwiftUI

struct ReasoningLevelControl: View {
  @Binding var level: ReasoningLevel
  var model: String = ""
  var endpointName: String = ""
  var baseURL: String = ""
  @State private var dragValue: Double?

  private static let thumbSize: CGFloat = 26
  private static let trackHeight: CGFloat = 5
  private static let controlHeight: CGFloat = 34

  private var displayLevel: ReasoningLevel {
    level(for: currentValue)
  }

  private var currentValue: Double {
    dragValue ?? value(for: level)
  }

  private var maximumValue: Double {
    Double(ReasoningLevel.allCases.count - 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Reasoning", systemImage: displayLevel.systemImage)
          .contentTransition(.symbolEffect(.replace))
        Spacer()
        Text(displayLevel.displayName)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
          .animation(.snappy, value: displayLevel)
      }
      sliderTrack
        .accessibilityValue(displayLevel.displayName)
      if let note = displayLevel.limitation(model: model, provider: endpointName, baseURL: baseURL)
      {
        Text(note).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var sliderTrack: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let thumbCenterX = xPosition(for: currentValue, width: width)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.tertiary)
          .frame(height: Self.trackHeight)
          .position(x: width / 2, y: Self.controlHeight / 2)
        Capsule()
          .fill(Color.accentColor)
          .frame(width: max(0, thumbCenterX), height: Self.trackHeight)
          .position(x: thumbCenterX / 2, y: Self.controlHeight / 2)
        tickMarks(width: width)
        Circle()
          .fill(.background)
          .overlay {
            Circle()
              .stroke(Color.accentColor, lineWidth: 2)
          }
          .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
          .frame(width: Self.thumbSize, height: Self.thumbSize)
          .position(x: thumbCenterX, y: Self.controlHeight / 2)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
              dragValue = value(forLocationX: gesture.location.x, width: width)
            }
          }
          .onEnded { gesture in
            let finalLevel = level(
              for: value(forLocationX: gesture.location.x, width: width))
            level = finalLevel
            withAnimation(.snappy) {
              dragValue = nil
            }
          }
      )
    }
    .frame(height: Self.controlHeight)
    .accessibilityElement()
    .accessibilityLabel("Reasoning")
    .accessibilityValue(displayLevel.displayName)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        commitLevel(offset: 1)
      case .decrement:
        commitLevel(offset: -1)
      default:
        break
      }
    }
  }

  private func tickMarks(width: CGFloat) -> some View {
    ForEach(ReasoningLevel.allCases.indices, id: \.self) { index in
      Circle()
        .fill(Color.accentColor.opacity(Double(index) <= currentValue.rounded() ? 0.55 : 0.25))
        .frame(width: 4, height: 4)
        .position(
          x: xPosition(for: Double(index), width: width),
          y: Self.controlHeight / 2)
    }
  }

  private func value(for level: ReasoningLevel) -> Double {
    Double(ReasoningLevel.allCases.firstIndex(of: level) ?? 0)
  }

  private func level(for value: Double) -> ReasoningLevel {
    let cases = ReasoningLevel.allCases
    let index = max(0, min(cases.count - 1, Int(value.rounded())))
    return cases[index]
  }

  private func xPosition(for value: Double, width: CGFloat) -> CGFloat {
    guard maximumValue > 0 else { return Self.thumbSize / 2 }
    let usableWidth = max(1, width - Self.thumbSize)
    let fraction = CGFloat(min(max(value / maximumValue, 0), 1))
    return Self.thumbSize / 2 + usableWidth * fraction
  }

  private func value(forLocationX x: CGFloat, width: CGFloat) -> Double {
    guard maximumValue > 0 else { return 0 }
    let usableWidth = max(1, width - Self.thumbSize)
    let fraction = min(max((x - Self.thumbSize / 2) / usableWidth, 0), 1)
    return Double(fraction) * maximumValue
  }

  private func commitLevel(offset: Int) {
    let cases = ReasoningLevel.allCases
    let currentIndex = cases.firstIndex(of: level) ?? 0
    let nextIndex = max(0, min(cases.count - 1, currentIndex + offset))
    level = cases[nextIndex]
  }
}
