import Foundation
import MaiCore
import SwiftTUIRuntime

/// Lifetime usage per provider/model: the report the REPL prints with
/// `/stats` — one colored bar per model for combined ranking, speed, time in use, and
/// efficiency — drawn from its styled runs, so both surfaces lay the table
/// out identically and a model keeps its color across the three rankings.
struct StatsScreen: View {
  let workspace: VisualWorkspace

  var body: some View {
    GeometryReader { proxy in
      let lines = workspace.usageReport.runs(width: Int(proxy.size.width) - 2)
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(0..<lines.count) { index in
            HStack(spacing: 0) {
              ForEach(0..<lines[index].count) { run in
                styled(lines[index][run])
              }
            }
          }
          HStack(spacing: 2) {
            Button("Refresh") { Task { await workspace.refreshUsageStats() } }
            Button("Reset statistics", role: .destructive) { workspace.resetUsageStats() }
              .disabled(workspace.usageLedger.isEmpty)
          }
          .padding(.top, 1)
          Text(
            "/stats prints the same table in the REPL; /stats del PROVIDER[:MODEL] drops one row."
          )
          .foregroundStyle(.separator)
          .lineLimit(2)
        }
        .padding(1)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  @ViewBuilder
  private func styled(_ run: ModelUsageReport.Run) -> some View {
    switch run.style {
    case .heading?, .value?:
      Text(run.text).bold()
    case .label(let color)?, .bar(let color)?:
      Text(run.text).foregroundStyle(Color(red: color.red, green: color.green, blue: color.blue))
    case .headline?, .detail?:
      Text(run.text).foregroundStyle(.muted).lineLimit(1).truncationMode(.tail)
    case .note?:
      Text(run.text).foregroundStyle(.separator).lineLimit(2)
    case nil:
      Text(run.text)
    }
  }
}
