import SwiftUI

struct AppleReminderPermissionButton: View {
  @State private var status = ""

  var body: some View {
    Button("Allow Apple Reminders access") {
      Task {
        do {
          try await PocketMaiReminders.apple.requestAccess()
          status = "Apple Reminders access is enabled."
        } catch {
          status = error.localizedDescription
        }
      }
    }
    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
  }
}
