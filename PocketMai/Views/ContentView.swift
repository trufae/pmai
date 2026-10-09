import MaiCore
import SwiftUI
import UIKit

struct ContentView: View {
  let store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var screenshotService = ChatScreenshotService()
  @StateObject private var contentStoreObservation = AppStoreViewObservation(scope: .content)
  @StateObject private var chatStoreObservation = AppStoreViewObservation(scope: .chat)
  @StateObject private var sidebarStoreObservation = AppStoreViewObservation(scope: .sidebar)
  @StateObject private var settingsStoreObservation = AppStoreViewObservation(scope: .settings)
  @State private var showingSettings = false
  @State private var showingHistory = false
  @State private var isHistoryPanelMounted = false
  @State private var historyDragOffset: CGFloat = 0
  @State private var sidebarSelectionGeneration = 0
  @State private var isShowingBookmarksFolder = false

  var body: some View {
    GeometryReader { proxy in
      let panelWidth = min(max(proxy.size.width * 0.82, 300), 390)
      let basePanelOffset = showingHistory ? panelWidth : 0
      let panelOffset = min(max(basePanelOffset + historyDragOffset, 0), panelWidth)
      let revealProgress = panelOffset / panelWidth

      ZStack(alignment: .leading) {
        if isHistoryPanelMounted {
          SidebarView(
            storeObservation: sidebarStoreObservation,
            store: store,
            showingSettings: $showingSettings,
            isShowingBookmarks: $isShowingBookmarksFolder,
            onSelectConversation: selectConversationFromSidebar,
            onSelectBookmarkedMessage: selectBookmarkedMessageFromSidebar,
            onDismiss: { closeHistoryPanel() }
          )
          .equatable()
          .frame(width: panelWidth)
          .frame(maxHeight: .infinity)
          .modifier(SidebarPlaneEffect(progress: revealProgress))
          .background { SidebarBlurBackground() }
          .overlay { SidebarDistanceTone(progress: revealProgress) }
          .opacity(panelOffset > 0 ? 1 : 0)
          .allowsHitTesting(panelOffset > 0)
          .accessibilityHidden(panelOffset == 0)
          .zIndex(0)
        }

        ZStack {
          ChatScreenBackground()

          NavigationStack {
            ChatView(
              storeObservation: chatStoreObservation,
              store: store,
              renderInvalidationKey: ChatView.RenderInvalidationKey(
                isLandscape: proxy.size.width > proxy.size.height,
                selectedConversationID: store.selectedConversationID,
                selectedConversationIsLoading: store.selectedConversationIsLoading,
                appearance: store.settings.appearance,
                renderMarkdownInChat: store.settings.renderMarkdownInChat,
                renderMarkdownImagesInChat: store.settings.renderMarkdownImagesInChat),
              onShowHistory: {
                toggleHistoryPanel()
              }
            )
            .equatable()
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
        .clipShape(RoundedRectangle(cornerRadius: panelOffset > 0 ? 28 : 0, style: .continuous))
        .allowsHitTesting(panelOffset == 0)
        .overlay {
          Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .allowsHitTesting(panelOffset > 0)
            .onTapGesture {
              closeHistoryPanel()
            }
        }
        .offset(x: panelOffset)
        .zIndex(1)
      }
      .background(Color(uiColor: .systemGroupedBackground))
    }
    .ignoresSafeArea()
    .sheet(isPresented: $showingSettings) {
      SettingsView(store: store, storeObservation: settingsStoreObservation)
        .environmentObject(store)
    }
    .sheet(item: pendingConversationImportFileBinding) { file in
      NavigationStack {
        SettingsImportView(initialFile: file) {
          store.finishConversationImportFile(id: file.id)
        }
      }
      .environmentObject(store)
    }
    .onChange(of: showingSettings) { _, isShowing in
      // The chat view keeps rendering behind the sheet; pausing streamed-text
      // publications while Settings is open stops the message list from doing
      // main-thread layout/scroll work ~8×/sec and starving the Settings UI.
      store.streamingTextStore.setPublishingSuspended(isShowing)
    }
    .fullScreenCover(item: approvalBinding) { approval in
      Group {
        switch approval {
        case .tool(let request): ToolCallApprovalView(request: request)
        case .compaction(let request): AutocompactionApprovalView(request: request)
        }
      }
      .environmentObject(store)
      .interactiveDismissDisabled()
    }
    .onChange(of: store.activeToolCallApprovalRequest?.id) { _, requestID in
      // An approval is a blocking decision. Dismiss any ordinary sheet so the
      // confirmation cannot be queued behind it while the assistant waits.
      if requestID != nil { showingSettings = false }
    }
    .onChange(of: store.activeAutocompactionApprovalRequest?.id) { _, requestID in
      if requestID != nil { showingSettings = false }
    }
    .alert(
      store.activeLongRunningOperationTimeoutRequest?.context.promptTitle
        ?? "Operation is still running",
      isPresented: longRunningOperationTimeoutBinding,
      presenting: store.activeLongRunningOperationTimeoutRequest
    ) { request in
      Button("Continue") {
        store.continueLongRunningOperation(id: request.id)
      }
      Button("Skip") {
        store.skipLongRunningOperation(id: request.id)
      }
      Button("Interrupt", role: .destructive) {
        store.interruptLongRunningOperation(id: request.id)
      }
    } message: { request in
      Text(request.context.promptMessage)
    }
    .alert("Error", isPresented: errorBinding) {
      Button("OK") { store.errorMessage = nil }
    } message: {
      Text(store.errorMessage ?? "")
    }
    .background(ChatScreenshotServiceInstaller(service: screenshotService))
    .background {
      HistoryPanelPanBridge(
        isEnabled: !showingSettings && store.activeToolCallApprovalRequest == nil
          && store.activeAutocompactionApprovalRequest == nil
          && store.activeLongRunningOperationTimeoutRequest == nil,
        isOpen: showingHistory,
        onChanged: { offset in
          if offset > 0 {
            mountHistoryPanel()
          }
          historyDragOffset = offset
        },
        onEnded: {
          setHistoryPanelOpen($0, animation: historyPanelAnimation)
        }
      )
    }
    .onAppear {
      contentStoreObservation.connect(to: store)
      chatStoreObservation.connect(to: store)
      settingsStoreObservation.connect(to: store)
      screenshotService.store = store
      store.drainPendingSharedLaunchCommand()
    }
    .onChange(of: scenePhase) { _, phase in
      store.handleScenePhaseChange(phase)
      if phase == .active {
        store.refreshAppleIntelligenceAvailabilityInBackground()
        store.refreshLocalMLXModelsInBackground()
        store.drainPendingSharedLaunchCommand()
      }
    }
    .tint(store.effectiveTintColor)
    .accentColor(store.effectiveTintColor)
  }

  private func selectConversationFromSidebar(_ id: UUID) {
    guard id != store.selectedConversationID else {
      store.markConversationRead(id: id)
      closeHistoryPanel()
      return
    }

    sidebarSelectionGeneration += 1
    let selectionGeneration = sidebarSelectionGeneration
    Task {
      await store.preloadConversation(id: id)
    }
    closeHistoryPanel {
      guard sidebarSelectionGeneration == selectionGeneration else { return }
      Task { @MainActor in
        guard sidebarSelectionGeneration == selectionGeneration else { return }
        await store.selectConversation(id: id)
      }
    }
  }

  private var pendingConversationImportFileBinding: Binding<PendingConversationImportFile?> {
    Binding {
      store.pendingConversationImportFiles.first
    } set: { file in
      guard case .none = file,
        let current = store.pendingConversationImportFiles.first
      else { return }
      store.finishConversationImportFile(id: current.id)
    }
  }

  private func selectBookmarkedMessageFromSidebar(
    conversationID: UUID,
    messageID: UUID
  ) {
    sidebarSelectionGeneration += 1
    let selectionGeneration = sidebarSelectionGeneration

    if conversationID == store.selectedConversationID {
      store.markConversationRead(id: conversationID)
      closeHistoryPanel {
        guard sidebarSelectionGeneration == selectionGeneration else { return }
        store.requestNavigationToMessage(messageID, in: conversationID)
      }
      return
    }

    Task {
      await store.preloadConversation(id: conversationID)
    }
    closeHistoryPanel {
      guard sidebarSelectionGeneration == selectionGeneration else { return }
      Task { @MainActor in
        guard sidebarSelectionGeneration == selectionGeneration else { return }
        await store.selectConversation(id: conversationID)
        guard sidebarSelectionGeneration == selectionGeneration else { return }
        store.requestNavigationToMessage(messageID, in: conversationID)
      }
    }
  }

  private func closeHistoryPanel(completion: (() -> Void)? = nil) {
    setHistoryPanelOpen(false, animation: historyPanelAnimation, completion: completion)
  }

  private func toggleHistoryPanel() {
    setHistoryPanelOpen(!showingHistory, animation: .snappy)
  }

  private var historyPanelAnimation: Animation {
    .interactiveSpring(response: 0.32, dampingFraction: 0.86)
  }

  private func setHistoryPanelOpen(
    _ isOpen: Bool,
    animation: Animation,
    completion: (() -> Void)? = nil
  ) {
    if isOpen {
      mountHistoryPanel()
    }
    let visibilityChanged = showingHistory != isOpen
    withAnimation(animation, completionCriteria: .logicallyComplete) {
      showingHistory = isOpen
      historyDragOffset = 0
    } completion: {
      if visibilityChanged {
        store.sidebarVisibilitySettled()
      }
      if !isOpen {
        isHistoryPanelMounted = false
      }
      completion?()
    }
  }

  private func mountHistoryPanel() {
    guard !isHistoryPanelMounted else { return }
    sidebarStoreObservation.connect(to: store)
    isHistoryPanelMounted = true
  }

  private enum ApprovalPresentation: Identifiable {
    case tool(ToolCallApprovalRequest)
    case compaction(AutocompactionApprovalRequest)

    var id: UUID {
      switch self {
      case .tool(let request): request.id
      case .compaction(let request): request.id
      }
    }
  }

  private var approvalBinding: Binding<ApprovalPresentation?> {
    Binding(
      get: {
        if let request = store.activeToolCallApprovalRequest { return .tool(request) }
        if let request = store.activeAutocompactionApprovalRequest { return .compaction(request) }
        return nil
      },
      set: { _ in }
    )
  }

  private var longRunningOperationTimeoutBinding: Binding<Bool> {
    Binding(
      // Keep the approval surface foremost; the timeout decision remains queued
      // and is presented as soon as the approval is resolved.
      get: {
        store.activeToolCallApprovalRequest == nil
          && store.activeAutocompactionApprovalRequest == nil
          && store.activeLongRunningOperationTimeoutRequest != nil
      },
      set: { _ in })
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: {
        store.activeToolCallApprovalRequest == nil
          && store.activeAutocompactionApprovalRequest == nil && store.errorMessage != nil
      },
      set: { if !$0 { store.errorMessage = nil } }
    )
  }
}

private struct HistoryPanelPanBridge: UIViewRepresentable {
  let isEnabled: Bool
  let isOpen: Bool
  let onChanged: (CGFloat) -> Void
  let onEnded: (Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isEnabled: isEnabled,
      isOpen: isOpen,
      onChanged: onChanged,
      onEnded: onEnded)
  }

  func makeUIView(context: Context) -> HierarchyTrackingView {
    let view = HierarchyTrackingView()
    view.isUserInteractionEnabled = false
    view.onHierarchyChange = { [weak coordinator = context.coordinator] view in
      coordinator?.installIfNeeded(from: view)
    }
    return view
  }

  func updateUIView(_ view: HierarchyTrackingView, context: Context) {
    context.coordinator.isEnabled = isEnabled
    context.coordinator.isOpen = isOpen
    context.coordinator.onChanged = onChanged
    context.coordinator.onEnded = onEnded
    context.coordinator.installIfNeeded(from: view)
  }

  static func dismantleUIView(_ view: HierarchyTrackingView, coordinator: Coordinator) {
    view.onHierarchyChange = nil
    coordinator.uninstall()
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isEnabled: Bool {
      didSet { panGesture?.isEnabled = isEnabled }
    }
    var isOpen: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (Bool) -> Void

    private weak var installedView: UIView?
    private var panGesture: UIPanGestureRecognizer?
    private var startedOpen = false

    init(
      isEnabled: Bool,
      isOpen: Bool,
      onChanged: @escaping (CGFloat) -> Void,
      onEnded: @escaping (Bool) -> Void
    ) {
      self.isEnabled = isEnabled
      self.isOpen = isOpen
      self.onChanged = onChanged
      self.onEnded = onEnded
    }

    func installIfNeeded(from hostView: UIView) {
      guard let target = hostView.window else { return }
      guard target !== installedView || panGesture == nil else {
        panGesture?.isEnabled = isEnabled
        return
      }

      uninstall()
      let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
      gesture.cancelsTouchesInView = false
      gesture.maximumNumberOfTouches = 1
      gesture.delegate = self
      gesture.isEnabled = isEnabled
      target.addGestureRecognizer(gesture)
      installedView = target
      panGesture = gesture
    }

    func uninstall() {
      if let panGesture, let installedView {
        installedView.removeGestureRecognizer(panGesture)
      }
      panGesture = nil
      installedView = nil
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
      guard let view = recognizer.view else { return }
      let translation = recognizer.translation(in: view)
      let directionalTranslation = startedOpen
        ? min(translation.x, 0)
        : max(translation.x, 0)

      switch recognizer.state {
      case .began:
        startedOpen = isOpen
        dismissContextMenus(in: view)
        onChanged(0)
      case .changed:
        onChanged(directionalTranslation)
      case .ended:
        let panelWidth = resolvedPanelWidth(for: view.bounds.width)
        let velocity = recognizer.velocity(in: view)
        let baseOffset = startedOpen ? panelWidth : 0
        let projectedOffset = min(
          max(baseOffset + directionalTranslation + velocity.x * 0.18, 0),
          panelWidth)
        onEnded(projectedOffset > panelWidth * 0.45)
      case .cancelled, .failed:
        onEnded(startedOpen)
      default:
        break
      }
    }

    private func dismissContextMenus(in view: UIView) {
      for case let interaction as UIContextMenuInteraction in view.interactions {
        interaction.dismissMenu()
      }
      for subview in view.subviews {
        dismissContextMenus(in: subview)
      }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard isEnabled, let pan = gestureRecognizer as? UIPanGestureRecognizer,
        let view = pan.view
      else { return false }

      let location = pan.location(in: view)
      let translation = pan.translation(in: view)
      let velocity = pan.velocity(in: view)
      let startX = location.x - translation.x
      let isHorizontal = abs(velocity.x) > abs(velocity.y) * 1.15
      if isOpen {
        let panelWidth = resolvedPanelWidth(for: view.bounds.width)
        return startX >= panelWidth && velocity.x < 0 && isHorizontal
      }
      return startX <= view.bounds.width / 3 && velocity.x > 0 && isHorizontal
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      !isScrollViewPanGesture(otherGestureRecognizer)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      // Give the drawer the first decision on horizontal edge pans. Otherwise
      // the scroll view begins simultaneously and flashes its vertical indicator.
      gestureRecognizer === panGesture && isScrollViewPanGesture(otherGestureRecognizer)
    }

    private func isScrollViewPanGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let scrollView = gestureRecognizer.view as? UIScrollView else { return false }
      return gestureRecognizer === scrollView.panGestureRecognizer
    }

    private func resolvedPanelWidth(for availableWidth: CGFloat) -> CGFloat {
      min(max(availableWidth * 0.82, 300), 390)
    }
  }
}

private final class HierarchyTrackingView: UIView {
  var onHierarchyChange: ((UIView) -> Void)?

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    notifyHierarchyChange()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    notifyHierarchyChange()
  }

  private func notifyHierarchyChange() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      onHierarchyChange?(self)
    }
  }
}

struct ChatScreenBackground: View {
  var body: some View {
    LinearGradient(
      colors: [Color(uiColor: .systemBackground), Color.accentColor.opacity(0.05)],
      startPoint: .top,
      endPoint: .bottom
    )
    .ignoresSafeArea()
  }
}

private struct AutocompactionApprovalView: View {
  @EnvironmentObject private var store: AppStore
  let request: AutocompactionApprovalRequest
  @State private var showingModelSettings = false
  @State private var confirmingClear = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(request.conversationTitle).font(.headline)
          Text("This chat has about \(request.estimatedTokens) tokens, above its \(request.threshold)-token compaction threshold.")
          Text("Compacting replaces older messages with a summary and keeps your latest message. Choose how to continue.")
        }
        Section("Model") {
          Button("Change chat model…") {
            Task {
              await store.selectConversation(id: request.conversationID)
              showingModelSettings = true
            }
          }
          Picker("Compaction agent", selection: Binding(
            get: { store.settings.taskAgents.compact ?? "" },
            set: {
              store.settings.taskAgents.compact = $0.isEmpty ? nil : $0
              store.saveSettings()
            })) {
            Text("Current conversation agent").tag("")
            ForEach(store.settings.agents) { agent in
              Text(agent.name).tag(agent.id.uuidString.lowercased())
            }
          }
        }
        Section {
          Button("Compact and continue") {
            store.resolveAutocompactionApproval(id: request.id, decision: .compact)
          }
          Button("Continue without compacting") {
            store.resolveAutocompactionApproval(id: request.id, decision: .continueWithoutCompacting)
          }
          Button("Stop response", role: .cancel) {
            store.resolveAutocompactionApproval(id: request.id, decision: .cancelRun)
          }
          Button("Clear chat…", role: .destructive) { confirmingClear = true }
        } footer: {
          Text("Continuing without compaction keeps all messages for this response. The prompt can appear again on your next message.")
        }
      }
      .navigationTitle("Compact this chat?")
      .sheet(isPresented: $showingModelSettings) {
        ConversationModelSettingsView().environmentObject(store)
      }
      .alert("Clear this chat?", isPresented: $confirmingClear) {
        Button("Clear chat", role: .destructive) {
          store.clearChatForAutocompaction(id: request.id)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("All messages in this chat will be removed and the response will stop.")
      }
    }
  }
}

private struct ToolCallApprovalView: View {
  @EnvironmentObject private var store: AppStore
  let request: ToolCallApprovalRequest
  @State private var toolCallText: String
  @State private var selectedSkill: String
  @State private var validationError: String?

  init(request: ToolCallApprovalRequest) {
    self.request = request
    _toolCallText = State(initialValue: request.originalText)
    _selectedSkill = State(initialValue: request.skillSelection?.proposed.name ?? "")
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        Label(request.skillSelection == nil ? request.callName : "Use a skill for this task?",
          systemImage: request.skillSelection == nil ? "wrench.and.screwdriver" : "sparkles")
          .font(.headline)
          .lineLimit(2)
        if let conversationTitle = request.conversationTitle {
          Text(conversationTitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        if let selection = request.skillSelection {
          Picker("Skill", selection: $selectedSkill) {
            ForEach(selection.skills, id: \.name) { skill in
              Text(skill.annotations.title ?? String(skill.name.dropFirst(MaiSkillTools.toolPrefix.count)))
                .tag(skill.name)
            }
          }
          .pickerStyle(.menu)
          Text(selection.skills.first(where: { $0.name == selectedSkill })?.description ?? "")
            .font(.subheadline)
          if let task = selection.proposed.argumentValues["arguments"]?.stringValue, !task.isEmpty {
            Text(task)
              .font(.body)
              .textSelection(.enabled)
          }
        } else {
          TextEditor(text: $toolCallText)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 260)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        if let validationError {
          Text(validationError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
        Spacer(minLength: 0)
      }
      .padding()
      .navigationTitle(request.skillSelection == nil ? "Confirm Tool Call" : "Confirm Skill")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) {
            store.cancelToolCallApproval(id: request.id)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(request.skillSelection == nil ? "Run" : "Accept") {
            validationError = request.skillSelection == nil
              ? store.approveToolCall(id: request.id, editedText: toolCallText)
              : store.approveSkill(id: request.id, toolName: selectedSkill)
          }
        }
        ToolbarItem(placement: .bottomBar) {
          Button("Stop", role: .destructive) {
            store.interruptToolCallApproval(id: request.id)
          }
        }
      }
    }
  }
}

// Identity-stable wrapper so the material's CALayer survives drag-tick body runs.
private struct SidebarBlurBackground: View, Equatable {
  var body: some View {
    Rectangle().fill(.regularMaterial)
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }
}
