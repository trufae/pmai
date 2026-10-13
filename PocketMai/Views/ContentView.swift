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
  @State private var fileBrowserLocation: FileBrowserLocation?
  @State private var showingHistory = false
  @State private var isHistoryPanelMounted = false
  @State private var showingFolders = false
  @State private var isFoldersPanelMounted = false
  @State private var showingHosts = false
  @State private var isHostsPanelMounted = false
  @State private var hosts = HostNavigationStore()
  @State private var historyDragOffset: CGFloat = 0
  @State private var drawerTransitionGeneration = 0
  @State private var sidebarSelectionGeneration = 0
  @State private var isShowingBookmarksFolder = false

  var body: some View {
    GeometryReader { proxy in
      let panelWidth = min(max(proxy.size.width * 0.82, 300), 390)
      let drawerDepth = showingHosts ? 3 : (showingFolders ? 2 : (showingHistory ? 1 : 0))
      let basePanelOffset = CGFloat(drawerDepth) * panelWidth
      let panelOffset = min(max(basePanelOffset + historyDragOffset, 0), panelWidth * 3)
      let sidebarOffset = max(panelOffset - panelWidth, 0)
      let foldersOffset = max(panelOffset - panelWidth * 2, 0)
      let revealProgress = min(panelOffset / panelWidth, 1)

      ZStack(alignment: .leading) {
        if isHostsPanelMounted {
          HostsView(hosts: hosts, onSelectHost: selectHost)
            .frame(width: panelWidth).frame(maxHeight: .infinity)
            .background { SidebarBlurBackground() }
            .opacity(panelOffset > panelWidth * 2 ? 1 : 0)
            .allowsHitTesting(panelOffset >= panelWidth * 3)
            .accessibilityHidden(panelOffset < panelWidth * 3)
            .zIndex(-1)
        }
        if isFoldersPanelMounted {
          Group {
            if hosts.selectedHost != nil {
              RemoteFoldersView(
                hosts: hosts, isOffline: store.settings.isOffline,
                onShowHosts: { setDrawerDepth(3, animation: historyPanelAnimation) },
                onSelectFolder: { cwd in
                  hosts.selectFolder(cwd)
                  setDrawerDepth(1, animation: historyPanelAnimation)
                }, isVisible: showingFolders && !showingHosts,
                onBrowseFiles: { browseFiles(cwd: $0) })
            } else {
              ConversationFoldersView(
                storeObservation: sidebarStoreObservation,
                store: store,
                isShowingBookmarks: isShowingBookmarksFolder,
                onSelectFolder: { folderID in
                  sidebarSelectionGeneration += 1
                  isShowingBookmarksFolder = false
                  store.selectConversationFolder(folderID)
                  setDrawerDepth(1, animation: historyPanelAnimation)
                },
                onSelectBookmarks: {
                  isShowingBookmarksFolder = true
                  setDrawerDepth(1, animation: historyPanelAnimation)
                },
                onShowHosts: { setDrawerDepth(3, animation: historyPanelAnimation) },
                onBrowseFiles: { browseFiles(folderID: $0) }
              )
            }
          }
          .frame(width: panelWidth)
          .frame(maxHeight: .infinity)
          .background { SidebarBlurBackground() }
          .opacity(panelOffset > panelWidth ? 1 : 0)
          .allowsHitTesting(panelOffset >= panelWidth * 2 && panelOffset < panelWidth * 3)
          .accessibilityHidden(panelOffset < panelWidth * 2 || panelOffset >= panelWidth * 3)
          .offset(x: foldersOffset)
          .zIndex(0)
        }

        if isHistoryPanelMounted {
          Group {
            if hosts.selectedHost != nil {
              RemoteConversationsView(
                hosts: hosts,
                onShowFolders: { setDrawerDepth(2, animation: historyPanelAnimation) },
                onSelectConversation: { id in
                  hosts.selectedConversationID = id
                  closeHistoryPanel()
                },
                onShowSettings: { showingSettings = true },
                isVisible: showingHistory && !showingFolders)
            } else {
              SidebarView(
                storeObservation: sidebarStoreObservation,
                store: store,
                showingSettings: $showingSettings,
                isShowingBookmarks: $isShowingBookmarksFolder,
                isVisible: showingHistory && !showingFolders,
                onSelectConversation: selectConversationFromSidebar,
                onSelectBookmarkedMessage: selectBookmarkedMessageFromSidebar,
                onNewChat: newLocalConversation,
                onShowFolders: { setDrawerDepth(2, animation: historyPanelAnimation) },
                onDismiss: { closeHistoryPanel() }
              )
              .equatable()
            }
          }
          .frame(width: panelWidth)
          .frame(maxHeight: .infinity)
          .modifier(SidebarPlaneEffect(progress: revealProgress))
          .background { SidebarBlurBackground() }
          .overlay { SidebarDistanceTone(progress: revealProgress) }
          .opacity(panelOffset > 0 ? 1 : 0)
          .allowsHitTesting(panelOffset >= panelWidth && panelOffset < panelWidth * 2)
          .accessibilityHidden(panelOffset < panelWidth || panelOffset >= panelWidth * 2)
          .offset(x: sidebarOffset)
          .zIndex(1)
        }

        ZStack {
          ChatScreenBackground()

          NavigationStack {
            if let host = hosts.selectedHost, hosts.selectedConversation == nil {
              VStack(spacing: 20) {
                ContentUnavailableView(
                  "\(host.name)", systemImage: "network",
                  description: Text("Choose a folder and conversation, or start a new chat."))
                Button("Browse Folders") { setDrawerDepth(2, animation: historyPanelAnimation) }
                Button("Browse Files", systemImage: "folder") { browseFiles() }
              }
              .navigationTitle(host.name)
              .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                  Button(
                    "Conversations", systemImage: "line.3.horizontal", action: toggleHistoryPanel
                  )
                  .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                  Button(
                    "New Chat", systemImage: "square.and.pencil", action: newRemoteConversation
                  )
                  .labelStyle(.iconOnly)
                  .disabled(host.requiresApproval == true || hosts.selectedFolderID == nil)
                }
              }
            } else {
              ChatView(
                storeObservation: chatStoreObservation,
                remoteChat: hosts.selectedHost.flatMap { host in
                  hosts.selectedConversation.map {
                    RemoteAgentChat(bookmark: host, conversation: $0)
                  }
                },
                store: store,
                renderInvalidationKey: ChatView.RenderInvalidationKey(
                  isLandscape: proxy.size.width > proxy.size.height,
                  selectedConversationID: store.selectedConversationID,
                  selectedConversationIsLoading: store.selectedConversationIsLoading,
                  appearance: store.settings.appearance,
                  renderMarkdownInChat: store.settings.renderMarkdownInChat,
                  renderMarkdownImagesInChat: store.settings.renderMarkdownImagesInChat),
                onShowHistory: toggleHistoryPanel,
                onNewChat: {
                  if hosts.selectedHost == nil {
                    newLocalConversation()
                  } else {
                    newRemoteConversation()
                  }
                },
                onRemoteChatReady: { hosts.activeChat = $0 },
                onBrowseFiles: { browseFiles() }
              )
              .equatable()
              .id(
                hosts.selectedHost.map {
                  "\($0.id):\($0.url):\($0.revision?.uuidString ?? ""):\(hosts.selectedConversationID?.uuidString ?? "")"
                } ?? "local")
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(panelOffset == 0)
        .overlay {
          Color.black.opacity(0.001 + Double(revealProgress) * 0.25)
            .contentShape(Rectangle())
            .allowsHitTesting(panelOffset > 0)
            .onTapGesture {
              closeHistoryPanel()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: panelOffset > 0 ? 28 : 0, style: .continuous))
        .offset(x: panelOffset)
        .zIndex(2)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .background {
        HistoryPanelPanBridge(
          isEnabled: !showingSettings && store.activeToolCallApprovalRequest == nil
            && store.activeAutocompactionApprovalRequest == nil
            && store.activeLongRunningOperationTimeoutRequest == nil,
          drawerDepth: drawerDepth,
          onChanged: { offset in
            // A new drag can reveal panels before the previous settling animation finishes.
            drawerTransitionGeneration += 1
            let nextOffset = min(max(CGFloat(drawerDepth) * panelWidth + offset, 0), panelWidth * 3)
            if nextOffset > 0 {
              mountHistoryPanel()
            }
            if nextOffset > panelWidth {
              mountFoldersPanel()
            }
            if nextOffset > panelWidth * 2 { isHostsPanelMounted = true }
            historyDragOffset = offset
          },
          onEnded: { depth in
            setDrawerDepth(depth, animation: historyPanelAnimation)
          }
        )
      }
    }
    .ignoresSafeArea(.container)
    .sheet(isPresented: $showingSettings) {
      SettingsView(store: store, storeObservation: settingsStoreObservation)
        .environmentObject(store)
    }
    .sheet(item: $fileBrowserLocation) { location in
      FileBrowserView(location: location).environmentObject(store)
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
    .onAppear {
      contentStoreObservation.connect(to: store)
      chatStoreObservation.connect(to: store)
      settingsStoreObservation.connect(to: store)
      screenshotService.store = store
      store.drainPendingSharedLaunchCommand()
    }
    .onChange(of: scenePhase) { _, phase in
      store.handleScenePhaseChange(phase)
      if phase == .background { hosts.stopDiscovery() }
      if phase == .active {
        store.refreshAppleIntelligenceAvailabilityInBackground()
        store.refreshLocalMLXModelsInBackground()
        store.drainPendingSharedLaunchCommand()
      }
    }
    .onChange(of: store.settings.isOffline) { _, enabled in
      if enabled { hosts.stopDiscovery() }
    }
    .onChange(of: hosts.remotes.connections.map(\.id)) { _, ids in
      if let id = hosts.selectedHostID, !ids.contains(id) {
        hosts.selectHost(nil, isOffline: store.settings.isOffline)
      }
    }
    .onChange(of: hosts.selectedHost?.revision) { _, _ in
      if hosts.selectedHost != nil {
        hosts.stopDiscovery()
        hosts.refresh(isOffline: store.settings.isOffline)
      }
    }
    .tint(selectedHostTint)
    .accentColor(selectedHostTint)
  }

  private var selectedHostTint: Color? {
    guard let host = hosts.selectedHost else { return store.effectiveTintColor }
    return host.accentColor.flatMap { ConversationFolderTint(rawIdentifier: $0) }?.color
      ?? store.settings.appearance.tintColor
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
    setDrawerDepth(0, animation: historyPanelAnimation, completion: completion)
  }

  private func selectHost(_ id: UUID?) {
    sidebarSelectionGeneration += 1
    hosts.selectHost(id, isOffline: store.settings.isOffline)
    setDrawerDepth(2, animation: historyPanelAnimation)
  }

  private func newRemoteConversation() {
    guard hosts.newConversation() != nil else { return }
    closeHistoryPanel()
  }

  private func newLocalConversation() {
    sidebarSelectionGeneration += 1
    isShowingBookmarksFolder = false
    store.newConversation()
    closeHistoryPanel()
  }

  private func browseFiles(folderID: String? = nil, cwd: String? = nil) {
    do {
      if let host = hosts.selectedHost {
        fileBrowserLocation = .remote(host, cwd: cwd ?? hosts.selectedFolderID ?? host.cwd)
      } else {
        var conversation = store.currentConversation ?? Conversation()
        if let folderID { conversation.folderID = folderID; conversation.workingFolder = nil }
        let resolved = try FileWorkspaceTool.context(for: conversation, settings: store.settings)
        fileBrowserLocation = .local(resolved.context)
      }
    } catch { store.errorMessage = error.localizedDescription }
  }

  private func toggleHistoryPanel() {
    setDrawerDepth(showingHistory ? 0 : 1, animation: .snappy)
  }

  private var historyPanelAnimation: Animation {
    .interactiveSpring(response: 0.32, dampingFraction: 0.86)
  }

  private func setDrawerDepth(
    _ requestedDepth: Int,
    animation: Animation,
    completion: (() -> Void)? = nil
  ) {
    let depth = min(max(requestedDepth, 0), 3)
    drawerTransitionGeneration += 1
    let transitionGeneration = drawerTransitionGeneration
    if depth > 0 {
      mountHistoryPanel()
    }
    if depth > 1 {
      mountFoldersPanel()
    }
    if depth > 2 { isHostsPanelMounted = true }
    let previousDepth = showingHosts ? 3 : (showingFolders ? 2 : (showingHistory ? 1 : 0))
    withAnimation(animation, completionCriteria: .logicallyComplete) {
      showingHistory = depth > 0
      showingFolders = depth > 1
      showingHosts = depth > 2
      historyDragOffset = 0
    } completion: {
      // Only the latest transition may unmount panels; an older completion can
      // otherwise remove the folders or hosts panel revealed by a fast swipe.
      if drawerTransitionGeneration == transitionGeneration {
        if previousDepth != depth {
          store.sidebarVisibilitySettled()
        }
        if depth < 2 {
          isFoldersPanelMounted = false
        }
        if depth < 3 { isHostsPanelMounted = false }
      }
      // Keep the lazily mounted conversation list alive so closing the drawer
      // preserves its native scroll offset and search state.
      completion?()
    }
  }

  private func mountHistoryPanel() {
    guard !isHistoryPanelMounted else { return }
    sidebarStoreObservation.connect(to: store)
    isHistoryPanelMounted = true
  }

  private func mountFoldersPanel() {
    guard !isFoldersPanelMounted else { return }
    isFoldersPanelMounted = true
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

struct HistoryPanelDrag {
  let startingDepth: Int
  let panelWidth: CGFloat

  func offset(for translation: CGFloat) -> CGFloat {
    // Dragging and settling must share the same adjacent-panel limits, or a
    // long swipe overshoots and then visibly snaps in the opposite direction.
    let minimum = -CGFloat(min(startingDepth, 1)) * panelWidth
    let maximum = CGFloat(min(3 - startingDepth, 1)) * panelWidth
    return min(max(translation, minimum), maximum)
  }

  func targetDepth(translation: CGFloat, velocity: CGFloat) -> Int {
    let projectedOffset = offset(for: translation + velocity * 0.18)
    return Int((CGFloat(startingDepth) + projectedOffset / panelWidth).rounded())
  }
}

private struct HistoryPanelPanBridge: UIViewRepresentable {
  let isEnabled: Bool
  let drawerDepth: Int
  let onChanged: (CGFloat) -> Void
  let onEnded: (Int) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isEnabled: isEnabled,
      drawerDepth: drawerDepth,
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
    context.coordinator.drawerDepth = drawerDepth
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
    var drawerDepth: Int
    var onChanged: (CGFloat) -> Void
    var onEnded: (Int) -> Void

    private weak var installedView: UIView?
    private var panGesture: UIPanGestureRecognizer?
    private var drag = HistoryPanelDrag(startingDepth: 0, panelWidth: 300)

    init(
      isEnabled: Bool,
      drawerDepth: Int,
      onChanged: @escaping (CGFloat) -> Void,
      onEnded: @escaping (Int) -> Void
    ) {
      self.isEnabled = isEnabled
      self.drawerDepth = drawerDepth
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
      gesture.cancelsTouchesInView = true
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
      switch recognizer.state {
      case .began:
        drag = HistoryPanelDrag(
          startingDepth: drawerDepth,
          panelWidth: resolvedPanelWidth(for: view.bounds.width))
        dismissContextMenus(in: view)
        onChanged(0)
      case .changed:
        onChanged(drag.offset(for: translation.x))
      case .ended:
        let velocity = recognizer.velocity(in: view)
        onEnded(drag.targetDepth(translation: translation.x, velocity: velocity.x))
      case .cancelled, .failed:
        onEnded(drag.startingDepth)
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
      let panelWidth = resolvedPanelWidth(for: view.bounds.width)
      switch drawerDepth {
      case 0:
        return startX <= view.bounds.width / 3 && velocity.x > 0 && isHorizontal
      case 1, 2:
        if velocity.x > 0 {
          return startX <= panelWidth && isHorizontal
        }
        return velocity.x < 0 && isHorizontal
      default:
        return velocity.x < 0 && isHorizontal
      }
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
          Text(
            "This chat has about \(request.estimatedTokens) tokens, above its \(request.threshold)-token compaction threshold."
          )
          Text(
            "Compacting replaces older messages with a summary and keeps your latest message. Choose how to continue."
          )
        }
        Section("Model") {
          Button("Change chat model…") {
            Task {
              await store.selectConversation(id: request.conversationID)
              showingModelSettings = true
            }
          }
          Picker(
            "Compaction agent",
            selection: Binding(
              get: { store.settings.taskAgents.compact ?? "" },
              set: {
                store.settings.taskAgents.compact = $0.isEmpty ? nil : $0
                store.saveSettings()
              })
          ) {
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
            store.resolveAutocompactionApproval(
              id: request.id, decision: .continueWithoutCompacting)
          }
          Button("Stop response", role: .cancel) {
            store.resolveAutocompactionApproval(id: request.id, decision: .cancelRun)
          }
          Button("Clear chat…", role: .destructive) { confirmingClear = true }
        } footer: {
          Text(
            "Continuing without compaction keeps all messages for this response. The prompt can appear again on your next message."
          )
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
        Label(
          request.skillSelection == nil ? request.callName : "Use a skill for this task?",
          systemImage: request.skillSelection == nil ? "wrench.and.screwdriver" : "sparkles"
        )
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
              Text(
                skill.annotations.title
                  ?? String(skill.name.dropFirst(MaiSkillTools.toolPrefix.count))
              )
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
            validationError =
              request.skillSelection == nil
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
