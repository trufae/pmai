import AVFoundation
import Foundation
import Observation
import Speech

enum SystemLanguageSupport {
  struct Catalog: Sendable {
    let textToSpeechVoices: [AVSpeechSynthesisVoice]
    let textToSpeechLanguageIdentifiers: [String]
    let speechRecognitionLocaleIdentifiers: [String]
    let chatLanguageIdentifiers: [String]
    let chatLanguageIdentifierSet: Set<String>

    init(voices: [AVSpeechSynthesisVoice], recognitionLocales: [String]) {
      let textToSpeech = SystemLanguageSupport.sortedLanguageIdentifiersUncached(
        voices.map(\.language)
      )
      let speechRecognition = SystemLanguageSupport.sortedLanguageIdentifiersUncached(
        recognitionLocales
      )
      let speechRecognitionSet = Set(speechRecognition)
      let chat = SystemLanguageSupport.sortedLanguageIdentifiersUncached(
        textToSpeech.filter { speechRecognitionSet.contains($0) }
      )

      textToSpeechVoices = voices
      textToSpeechLanguageIdentifiers = textToSpeech
      speechRecognitionLocaleIdentifiers = speechRecognition
      chatLanguageIdentifiers = chat
      chatLanguageIdentifierSet = Set(chat)
    }
  }

  @MainActor @Observable
  final class CatalogLoader {
    private(set) var catalog: Catalog?
    private var started = false

    func preload(
      load: @escaping @Sendable () -> Catalog = {
        Catalog(
          voices: AVSpeechSynthesisVoice.speechVoices(),
          recognitionLocales: SFSpeechRecognizer.supportedLocales().map(\.identifier))
      }
    ) {
      guard !started else { return }
      started = true
      // These synchronous system APIs can wait on services. Keep them off both
      // the main actor and Swift's cooperative executor, and never wait in a getter.
      DispatchQueue.global(qos: .utility).async {
        let loaded = load()
        Task { @MainActor in self.catalog = loaded }
      }
    }
  }

  @MainActor private static let loader = CatalogLoader()

  @MainActor private static var catalog: Catalog? {
    loader.preload()
    return loader.catalog
  }

  @MainActor
  static func preload() {
    loader.preload()
  }

  @MainActor
  static var textToSpeechVoices: [AVSpeechSynthesisVoice] {
    catalog?.textToSpeechVoices ?? []
  }

  @MainActor
  static var textToSpeechLanguageIdentifiers: [String] {
    catalog?.textToSpeechLanguageIdentifiers ?? []
  }

  @MainActor
  static var speechRecognitionLocaleIdentifiers: [String] {
    catalog?.speechRecognitionLocaleIdentifiers ?? []
  }

  @MainActor
  static func chatLanguageIdentifiers(including selected: String? = nil) -> [String] {
    let catalog = catalog
    guard let selected = normalizedLanguageIdentifier(selected),
      catalog?.chatLanguageIdentifierSet.contains(selected) != true
    else { return catalog?.chatLanguageIdentifiers ?? [] }
    return sortedLanguageIdentifiers((catalog?.chatLanguageIdentifiers ?? []) + [selected])
  }

  static func normalizedLanguageIdentifier(_ identifier: String?) -> String? {
    guard let identifier else { return nil }
    let normalized = canonicalLanguageIdentifier(identifier)
    return normalized.isEmpty ? nil : normalized
  }

  static func canonicalLanguageIdentifier(_ identifier: String) -> String {
    identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
  }

  static func primaryLanguageCode(_ identifier: String) -> String? {
    let code = Locale(identifier: identifier).language.languageCode?.identifier
    return code?.isEmpty == false ? code : nil
  }

  static func primaryLanguageDisplayName(_ code: String) -> String {
    Locale.current.localizedString(forLanguageCode: code) ?? code
  }

  static func variantDisplayName(_ identifier: String) -> String {
    let locale = Locale(identifier: identifier)
    if let region = locale.region?.identifier,
      let regionName = Locale.current.localizedString(forRegionCode: region)
    {
      return "\(regionName) (\(canonicalLanguageIdentifier(identifier)))"
    }
    return languageDisplayName(identifier)
  }

  static func languageDisplayName(_ identifier: String) -> String {
    uncachedLanguageDisplayName(identifier)
  }

  static func sortedLanguageIdentifiers(_ identifiers: [String]) -> [String] {
    sortLanguageIdentifiers(identifiers, displayName: languageDisplayName)
  }

  private static func sortedLanguageIdentifiersUncached(_ identifiers: [String]) -> [String] {
    sortLanguageIdentifiers(identifiers, displayName: uncachedLanguageDisplayName)
  }

  private static func sortLanguageIdentifiers(
    _ identifiers: [String],
    displayName: (String) -> String
  ) -> [String] {
    let unique = Set(identifiers.map(canonicalLanguageIdentifier).filter { !$0.isEmpty })
    return
      unique
      .map { identifier in (identifier, displayName(identifier)) }
      .sorted { lhs, rhs in
        let order = lhs.1.localizedCaseInsensitiveCompare(rhs.1)
        return order == .orderedSame ? lhs.0 < rhs.0 : order == .orderedAscending
      }
      .map(\.0)
  }

  private static func uncachedLanguageDisplayName(_ identifier: String) -> String {
    let normalized = canonicalLanguageIdentifier(identifier)
    let name = Locale.current.localizedString(forIdentifier: normalized) ?? normalized
    return "\(name) (\(normalized))"
  }
}
