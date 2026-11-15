#if os(iOS) || os(macOS)
import MaiCore
import SwiftUI

/// Management for the app's local reminders. The OS owns notification permission.
public struct ReminderSettings: View {
  let notifications: AppleReminderNotifications
  @State private var snapshot = ReminderStore.Snapshot()
  @State private var editor: Editor?
  @State private var remove: MaiReminder?
  @State private var status = ""
  @State private var error: String?

  public init(notifications: AppleReminderNotifications) { self.notifications = notifications }

  public var body: some View {
    Group {
      Toggle("Reminder alerts", isOn: Binding(get: { snapshot.notificationsEnabled }, set: { enabled in
        perform { try await notifications.store.setNotificationsEnabled(enabled) }
      }))
      Button("Allow notifications") { perform { try await notifications.requestAuthorization() } }
      if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
      Button("Add reminder", systemImage: "plus") { editor = Editor() }
      ForEach(snapshot.reminders.sorted { ($0.dueAt ?? .infinity) < ($1.dueAt ?? .infinity) }) { reminder in
        HStack {
          Button {
            perform {
              _ = try await notifications.store.update(id: reminder.id, title: nil,
                due: .keep, alert: nil, completed: !reminder.completed)
            }
          } label: {
            Image(systemName: reminder.completed ? "checkmark.circle.fill" : "circle")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(reminder.completed ? "Reopen" : "Complete")
          Button { editor = Editor(reminder) } label: {
            VStack(alignment: .leading) {
              Text(reminder.title).strikethrough(reminder.completed)
              if let due = reminder.dueDate {
                Text(due.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }.buttonStyle(.borderless)
          Spacer()
          Button(role: .destructive) { remove = reminder } label: {
            Image(systemName: "trash")
          }.buttonStyle(.borderless).accessibilityLabel("Delete reminder")
        }
      }
    }
    .task {
      await reload()
      // Show writes made by chats or another local process while Settings is open.
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        if let next = try? notifications.store.snapshot(), next != snapshot { await reload() }
      }
    }
    .sheet(item: $editor) { entry in
      ReminderEditor(entry: entry) { title, due, alert in
        if let item = entry.reminder {
          _ = try await notifications.store.update(id: item.id, title: title,
            due: due.map(ReminderDueChange.set) ?? .clear, alert: alert, completed: nil)
        } else {
          _ = try await notifications.store.add(title: title, due: due, alert: alert)
        }
        await reload()
      }
    }
    .confirmationDialog("Delete this reminder?", isPresented: Binding(
      get: { remove != nil }, set: { if !$0 { remove = nil } }
    ), presenting: remove) { item in
      Button("Delete", role: .destructive) { perform { try await notifications.store.remove(id: item.id) } }
    }
    .alert("Reminders", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) {}
    } message: { Text(error ?? "") }
  }

  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    Task {
      do { try await action(); await reload() }
      catch { self.error = error.localizedDescription }
    }
  }

  private func reload() async {
    do {
      snapshot = try notifications.store.snapshot()
      await notifications.refresh()
      status = notifications.status
    } catch { self.error = error.localizedDescription }
  }

  fileprivate struct Editor: Identifiable {
    let id = UUID()
    let reminder: MaiReminder?
    init(_ reminder: MaiReminder? = nil) { self.reminder = reminder }
  }
}

private struct ReminderEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var scheduled: Bool
  @State private var date: Date
  @State private var alert: ReminderAlert
  @State private var saving = false
  @State private var error = ""
  let entry: ReminderSettings.Editor
  let save: @MainActor (String, Date?, ReminderAlert) async throws -> Void

  init(entry: ReminderSettings.Editor,
    save: @escaping @MainActor (String, Date?, ReminderAlert) async throws -> Void
  ) {
    self.entry = entry
    self.save = save
    _title = State(initialValue: entry.reminder?.title ?? "")
    _scheduled = State(initialValue: entry.reminder?.dueAt != nil)
    _date = State(initialValue: entry.reminder?.dueDate ?? Date().addingTimeInterval(3600))
    _alert = State(initialValue: entry.reminder?.alert ?? .notification)
  }

  var body: some View {
    Form {
      TextField("Title", text: $title)
      Toggle("Due date", isOn: $scheduled)
      if scheduled {
        DatePicker("Due", selection: $date)
        Picker("Alert", selection: $alert) {
          Text("None").tag(ReminderAlert.none)
          Text("Notification").tag(ReminderAlert.notification)
          Text("Audible alarm").tag(ReminderAlert.alarm)
        }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
          .disabled(saving)
        Spacer()
        Button("Save") {
          saving = true
          Task {
            do {
              try await save(title.trimmingCharacters(in: .whitespacesAndNewlines),
                scheduled ? date : nil, scheduled ? alert : .none)
              dismiss()
            } catch {
              self.error = error.localizedDescription
              saving = false
            }
          }
        }
        .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .buttonStyle(.borderedProminent)
      }
    }
    .padding()
    #if os(macOS)
    .frame(minWidth: 440)
    #endif
  }
}
#endif
