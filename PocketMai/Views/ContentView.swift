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
    .fullScreenCover(item: toolCallApprovalBinding) { request in
      ToolCallApprovalView(request: request)
        .environmentObject(store)
        .interactiveDismissDisabled()
    }
    .onChange(of: store.activeToolCallApprovalRequest?.id) { _, requestID in
      // An approval is a blocking decision. Dismiss any ordinary sheet so the
      // confirmation cannot be queued behind it while the assistant waits.
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

  private var toolCallApprovalBinding: Binding<ToolCallApprovalRequest?> {
    Binding(
      get: { store.activeToolCallApprovalRequest },
      set: { _ in }
    )
  }

  private var longRunningOperationTimeoutBinding: Binding<Bool> {
    Binding(
      // Keep the approval surface foremost; the timeout decision remains queued
      // and is presented as soon as the approval is resolved.
      get: {
        store.activeToolCallApprovalRequest == nil
          && store.activeLongRunningOperationTimeoutRequest != nil
      },
      set: { _ in })
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.activeToolCallApprovalRequest == nil && store.errorMessage != nil },
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
      true
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

private struct ToolCallApprovalView: View {
  @EnvironmentObject private var store: AppStore
  let request: ToolCallApprovalRequest
  @State private var toolCallText: String
  @State private var validationError: String?

  init(request: ToolCallApprovalRequest) {
    self.request = request
    _toolCallText = State(initialValue: request.originalText)
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        Label(request.callName, systemImage: "wrench.and.screwdriver")
          .font(.headline)
          .lineLimit(2)
        if let conversationTitle = request.conversationTitle {
          Text(conversationTitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        TextEditor(text: $toolCallText)
          .font(.system(.body, design: .monospaced))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .scrollContentBackground(.hidden)
          .padding(8)
          .frame(minHeight: 260)
          .background(Color(uiColor: .secondarySystemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        if let validationError {
          Text(validationError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
        Spacer(minLength: 0)
      }
      .padding()
      .navigationTitle("Confirm Tool Call")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) {
            store.cancelToolCallApproval(id: request.id)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Run") {
            validationError = store.approveToolCall(id: request.id, editedText: toolCallText)
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
