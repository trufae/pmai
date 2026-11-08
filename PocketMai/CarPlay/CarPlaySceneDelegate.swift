import AVFoundation
import CarPlay
import Combine
import UIKit

@available(iOS 26.4, *)
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
  CPInterfaceControllerDelegate
{
  private let store = PocketMaiApp.sharedStore
  private let voice = LiveVoiceSession()
  private let speech = TTSPlayer(integratesWithSystemPlayback: false, carPlayAudio: true)
  private weak var controller: CPInterfaceController?
  private var root: CPListTemplate?
  private var voiceTemplate: CPVoiceControlTemplate?
  private var newConversationID: UUID?
  private var startTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?
  private var stateObservation: AnyCancellable?
  private var interruptionObservation: AnyCancellable?

  private enum Action {
    case talk
    case resume
    case preset(UUID)
  }

  func templateApplicationScene(
    _ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController
  ) {
    controller = interfaceController
    interfaceController.delegate = self
    let loading = CPListItem(text: "Loading PocketMai", detailText: nil)
    loading.isEnabled = false
    let list = CPListTemplate(title: "PocketMai", sections: [CPListSection(items: [loading])])
    root = list
    interfaceController.setRootTemplate(list, animated: false, completion: nil)
    startupTask = Task { [weak self] in
      guard let self else { return }
      await store.waitForStartup()
      guard !Task.isCancelled else { return }
      startupTask = nil
      updateMenu()
    }
    interruptionObservation = NotificationCenter.default.publisher(
      for: AVAudioSession.interruptionNotification
    )
    .compactMap { $0.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt }
    .filter { $0 == AVAudioSession.InterruptionType.began.rawValue }
    .merge(
      with: NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
        .compactMap { $0.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt }
        .filter { $0 == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue }
    )
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.endVoice() }
  }

  func templateApplicationScene(
    _ scene: CPTemplateApplicationScene, didDisconnect interfaceController: CPInterfaceController
  ) {
    guard controller === interfaceController else { return }
    endVoice(dismiss: false)
    startupTask?.cancel()
    startupTask = nil
    interruptionObservation = nil
    interfaceController.delegate = nil
    root = nil
    controller = nil
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    endVoice()
  }

  func templateWillAppear(_ template: CPTemplate, animated: Bool) {
    if template === root, startupTask == nil { updateMenu() }
  }

  func templateDidDisappear(_ template: CPTemplate, animated: Bool) {
    if template === voiceTemplate { endVoice(dismiss: false) }
  }

  private var resumableConversation: ConversationSummary? {
    if let selected = store.selectedConversationSummary, selected.hasMessages, !selected.isArchived
    {
      return selected
    }
    return store.conversationSummaries.lazy.filter { $0.hasMessages && !$0.isArchived }
      .max { $0.updatedAt < $1.updatedAt }
  }

  private func updateMenu() {
    let talk = item("Talk to the Agent", image: "mic", action: .talk)
    let resume = item("Resume Conversation", image: "clock.arrow.circlepath", action: .resume)
    resume.isEnabled = resumableConversation != nil
    var sections = [CPListSection(items: [talk, resume])]
    let favorites = CarPlayFavorites.ids(
      from: UserDefaults.standard.string(forKey: CarPlayFavorites.key) ?? "")
    let presets = store.settings.userPrompts.lazy
      .filter { favorites.contains($0.id) && !$0.message(arguments: "").isEmpty }
      .prefix(max(0, CPListTemplate.maximumItemCount - 2))
      .map { self.item($0.displayName, image: "star", action: .preset($0.id)) }
    if !presets.isEmpty {
      sections.append(
        CPListSection(items: Array(presets), header: "Favorite Prompts", sectionIndexTitle: nil))
    }
    root?.updateSections(sections)
  }

  private func item(_ title: String, image: String, action: Action) -> CPListItem {
    let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: image))
    item.handler = { [weak self] _, completion in
      self?.start(action)
      completion()
    }
    return item
  }

  private func start(_ action: Action) {
    guard let controller, startTask == nil, voiceTemplate == nil else { return }
    let preset: PromptShortcutSelection?
    if case .preset(let id) = action {
      guard
        store.settings.userPrompts.contains(where: {
          $0.id == id && !$0.message(arguments: "").isEmpty
        })
      else {
        updateMenu()
        return
      }
      preset = PromptShortcutSelection(kind: .user, id: id)
    } else {
      guard AVAudioApplication.shared.recordPermission == .granted else {
        showAlert("Enable microphone access for PocketMai on your iPhone.")
        return
      }
      preset = nil
    }

    let conversationID: UUID?
    if case .resume = action {
      conversationID = resumableConversation?.id
    } else {
      let id = store.createCarPlayConversation()
      newConversationID = id
      conversationID = id
    }
    guard let conversationID else {
      showAlert("No conversation is available.")
      return
    }

    startTask = Task { [weak self, weak controller] in
      guard let self, let controller else { return }
      await store.preloadConversation(id: conversationID)
      guard !Task.isCancelled else { return }
      startTask = nil
      guard let conversation = store.conversation(withID: conversationID),
        conversation.historyWindow == nil, !store.isResponding(in: conversationID)
      else {
        discardEmptyConversation()
        showAlert("This conversation is unavailable or busy.")
        return
      }

      let template = makeVoiceTemplate(conversationID: conversationID)
      voiceTemplate = template
      controller.presentTemplate(template, animated: true) {
        [weak self, weak template] success, _ in
        guard let self, let template, voiceTemplate === template else { return }
        guard success else {
          endVoice(dismiss: false)
          return
        }
        stateObservation = voice.$state.dropFirst().sink { [weak self] state in
          self?.updateVoiceState(state)
        }
        TTSPlayer.shared.stop()
        if let preset {
          voice.submitPreset(preset, in: conversationID, store: store, ttsPlayer: speech)
        } else {
          voice.start(store: store, ttsPlayer: speech, conversationID: conversationID)
        }
      }
    }
  }

  private func makeVoiceTemplate(conversationID: UUID) -> CPVoiceControlTemplate {
    let states = [
      state("starting", "Starting", symbol: "waveform"),
      state("listening", "Listening", symbol: "mic"),
      state("thinking", "Thinking", symbol: "ellipsis"),
      state("speaking", "Speaking", symbol: "speaker.wave.2"),
      state("paused", "Paused", symbol: "pause.circle"),
      state("error", "Voice unavailable", symbol: "exclamationmark.circle"),
    ]
    if let send = UIImage(systemName: "arrow.up.circle"),
      let resume = UIImage(systemName: "mic.circle")
    {
      states[1].actionButtons = [
        CPButton(image: send) { [weak self] _ in
          guard let self else { return }
          voice.submitCurrentTurn(store: store, ttsPlayer: speech)
        }
      ]
      states[4].actionButtons = [
        CPButton(image: resume) { [weak self] _ in
          guard let self else { return }
          voice.start(store: store, ttsPlayer: speech, conversationID: conversationID)
        }
      ]
    }
    let template = CPVoiceControlTemplate(voiceControlStates: states)
    template.trailingNavigationBarButtons = [
      CPBarButton(title: "End") { [weak self] _ in self?.endVoice() }
    ]
    template.activateVoiceControlState(withIdentifier: "starting")
    return template
  }

  private func state(_ id: String, _ title: String, symbol: String) -> CPVoiceControlState {
    CPVoiceControlState(
      identifier: id, titleVariants: [title], image: UIImage(systemName: symbol), repeats: false)
  }

  private func updateVoiceState(_ state: LiveVoiceState) {
    let identifier: String
    switch state {
    case .idle:
      endVoice(stopSession: false)
      return
    case .requestingPermission: identifier = "starting"
    case .listening: identifier = "listening"
    case .thinking: identifier = "thinking"
    case .speaking: identifier = "speaking"
    case .paused: identifier = voice.errorMessage == nil ? "paused" : "error"
    case .error: identifier = "error"
    }
    voiceTemplate?.activateVoiceControlState(withIdentifier: identifier)
  }

  private func endVoice(dismiss: Bool = true, stopSession: Bool = true) {
    startTask?.cancel()
    startTask = nil
    let template = voiceTemplate
    voiceTemplate = nil
    stateObservation = nil
    if stopSession, voice.isActive { voice.stop(cancelResponse: true) }
    discardEmptyConversation()
    if dismiss, let template, controller?.presentedTemplate === template {
      controller?.dismissTemplate(animated: true, completion: nil)
    }
  }

  private func discardEmptyConversation() {
    guard let id = newConversationID else { return }
    newConversationID = nil
    store.discardEmptyCarPlayConversation(id: id)
  }

  private func showAlert(_ title: String) {
    let action = CPAlertAction(title: "OK", style: .default) { _ in }
    let alert = CPAlertTemplate(titleVariants: [title], actions: [action])
    controller?.presentTemplate(alert, animated: true, completion: nil)
  }
}
