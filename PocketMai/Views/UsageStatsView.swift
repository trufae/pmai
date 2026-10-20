import MaiCore
import SwiftUI

/// Settings → Statistics: the report the pmai REPL prints with `/stats` —
/// lifetime tokens plus a combined ranking, speed, time in use, and efficiency per provider/model —
/// as a bar chart ranked by the chosen metric, with the models and providers
/// listed below it. Untick a row to leave it out of the chart; long-press
/// one for every recorded fact. Numbers, rankings, descriptions, and colors
/// all come from MaiCore.
struct UsageStatsView: View {
  private typealias Metric = ModelUsageReport.Metric

  @ObservedObject private var stats = UsageStatsStore.shared
  @State private var metric: Metric = .ranking
  @State private var selectedID: String?
  /// Rows left out of the chart; everything is in until unticked.
  @State private var hiddenModelIDs: Set<String> = []
  @State private var hiddenProviders: Set<String> = []
  @State private var confirmingReset = false
  /// A long-pressed row: its title, its facts, and what deleting it removes.
  @State private var inspected: (title: String, facts: String, target: String)?

  private static let chartHeight: CGFloat = 120

  private var report: ModelUsageReport {
    ModelUsageReport(
      totals: stats.totals.filter {
        !hiddenProviders.contains($0.providerLabel) && !hiddenModelIDs.contains($0.id)
      })
  }

  /// Rows with a number for the chosen metric, best first.
  private var chartRows: [ModelUsageReport.Row] {
    report.rows(for: metric).filter { ($0.number(metric) ?? 0) > 0 }
  }

  private var selectedRow: ModelUsageReport.Row? {
    chartRows.first { $0.id == selectedID } ?? chartRows.first
  }

  var body: some View {
    List {
      if stats.totals.isEmpty {
        ContentUnavailableView(
          "No Usage Yet",
          systemImage: "chart.bar",
          description: Text("Statistics appear here after the first model response."))
      } else if report.isEmpty {
        ContentUnavailableView(
          "No Statistics Selected",
          systemImage: "line.3.horizontal.decrease.circle",
          description: Text("Tick at least one model and provider to show statistics."))
      } else {
        Section {
          Picker("Metric", selection: $metric) {
            ForEach(Metric.displayCases, id: \.self) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
          chart
          caption(report.headline)
          caption(
            [
              "~\(ModelUsageFormat.count(report.ledger.userInputTokens)) sent",
              "~\(ModelUsageFormat.count(report.ledger.receivedTextTokens)) recv",
              report.ledger.imageInputs > 0 ? "\(report.ledger.imageInputs) images" : nil,
            ].compactMap { $0 }.joined(separator: " · "))
        } header: {
          Text(metric.title)
        } footer: {
          Text("\(metric.title): \(metric.explanation).")
        }
      }
      if !stats.totals.isEmpty {
        Section {
          ForEach(stats.ledger.sortedByLastUsed) { entry in
            row(
              title: entry.title,
              value: metric.number(of: entry).flatMap { $0 > 0 ? metric.text($0) : nil },
              summary: entry.summary,
              color: ModelUsagePalette.color(forModel: entry.id),
              hidden: $hiddenModelIDs,
              key: entry.id
            ) {
              inspected = (entry.title, entry.detailLines.joined(separator: "\n"), entry.id)
            }
          }
        } header: {
          Text("Models")
        } footer: {
          if stats.ledger.estimatedCallCount > 0 {
            Text("~ marks token counts estimated from text length (~4 characters per token).")
          }
        }
        Section {
          ForEach(stats.ledger.providerTotals) { provider in
            row(
              title: provider.providerLabel,
              value: metric == .efficiency
                ? provider.efficiency.map(ModelUsageFormat.efficiency) : nil,
              summary: provider.summary,
              color: ModelUsagePalette.color(forProviderLabel: provider.providerLabel),
              hidden: $hiddenProviders,
              key: provider.providerLabel
            ) {
              inspected = (provider.providerLabel, provider.summary, provider.providerLabel)
            }
          }
        } header: {
          Text("Providers")
        } footer: {
          Text(
            "Untick a model or a provider to leave it out of the chart. Long-press a row for every recorded fact."
          )
        }
        Section {
          Button(role: .destructive) {
            confirmingReset = true
          } label: {
            Label("Reset Statistics", systemImage: "trash")
          }
        }
      }
    }
    .navigationTitle("Statistics")
    .confirmationDialog(
      "Reset all usage statistics?",
      isPresented: $confirmingReset,
      titleVisibility: .visible
    ) {
      Button("Reset Statistics", role: .destructive) {
        stats.reset()
        hiddenModelIDs = []
        hiddenProviders = []
      }
    }
    .confirmationDialog(
      inspected?.title ?? "",
      isPresented: Binding(
        get: { inspected != nil },
        set: { if !$0 { inspected = nil } }
      ),
      titleVisibility: .visible,
      presenting: inspected
    ) { item in
      Button("Delete Statistics", role: .destructive) {
        stats.remove(matching: item.target)
      }
    } message: { item in
      Text(item.facts)
    }
  }

  /// One bar per model, its height the row's share of the best value for the
  /// chosen metric, in the model's shared color; the tapped one is named.
  private var chart: some View {
    VStack(spacing: 10) {
      if chartRows.isEmpty {
        caption("No \(metric.label.lowercased()) recorded for the shown models yet.")
      }
      HStack(alignment: .bottom, spacing: 6) {
        ForEach(chartRows) { row in
          Rectangle()
            .fill(Color(row.color).opacity(row.id == selectedRow?.id ? 1 : 0.35))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            .frame(maxWidth: 48)
            .frame(height: max(6, Self.chartHeight * row.fraction(metric)))
            .frame(maxWidth: .infinity, maxHeight: Self.chartHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture { selectedID = row.id }
            .accessibilityLabel(row.title)
            .accessibilityValue(row.value(metric))
        }
      }
      .animation(.snappy(duration: 0.2), value: selectedID)
      if let row = selectedRow {
        caption("\(row.title) · \(row.value(metric))")
        caption(row.detail(metric))
      }
    }
    .padding(.vertical, 6)
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
  }

  /// A model or provider row: its color, name, the chosen metric's number,
  /// the summary line, and a tick that keeps it in the chart.
  private func row(
    title: String,
    value: String?,
    summary: String,
    color: ModelUsageColor,
    hidden: Binding<Set<String>>,
    key: String,
    inspect: @escaping () -> Void
  ) -> some View {
    let shown = !hidden.wrappedValue.contains(key)
    return Button {
      if shown {
        hidden.wrappedValue.insert(key)
      } else {
        hidden.wrappedValue.remove(key)
      }
    } label: {
      HStack(spacing: 10) {
        Circle()
          .fill(Color(color))
          .frame(width: 10, height: 10)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(title)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            if let value {
              Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
          Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Image(systemName: shown ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(shown ? Color.accentColor : .secondary)
      }
    }
    .buttonStyle(.plain)
    .onLongPressGesture(perform: inspect)
    .accessibilityLabel(title)
    .accessibilityValue("\(shown ? "Shown" : "Hidden"), \(summary)")
  }
}

extension Color {
  /// The shared palette's color, so a model looks the same here as in the
  /// pmai REPL.
  fileprivate init(_ color: ModelUsageColor) {
    self.init(red: color.red, green: color.green, blue: color.blue)
  }
}
