import Foundation
import MaiCore
import MaiDocuments

struct PersistedConversations: Codable {
  var conversations: [Conversation]
}

private struct PersistedConversationIndex: Codable {
  var version = 2
  var ids: [UUID]
  var summaries: [ConversationSummary]?
}

private struct PersistedRecentConversationCache: Codable {
  var version = 1
  var entries: [PersistedRecentConversationEntry]
}

private struct PersistedLaunchConversationCache: Codable {
  var version = 1
  var summaries: [ConversationSummary]
}

private struct PersistedRecentConversationEntry: Codable {
  var filename: String
  var summary: ConversationSummary
}

private struct PersistedDrafts: Codable {
  var version = 1
  var drafts: [String: String]
}

private struct PersistedBookmarks: Codable {
  var version = 1
  var bookmarks: [MessageBookmark]
}

/// One place conversations live: the device or iCloud. The conversation files
/// themselves are managed by MaiCore's `ChatFileStore`, which follows the
/// layout PocketMai has always used, one `<id>.json` per conversation inside
/// `conversations/`. The index and recent caches beside them are the app's own.
private struct ConversationStorageURLs {
  var baseURL: URL

  var conversationsURL: URL {
    baseURL.appendingPathComponent("conversations.json")
  }

  var conversationsDirectoryURL: URL {
    baseURL.appendingPathComponent("conversations", isDirectory: true)
  }

  var conversationsIndexURL: URL {
    conversationsDirectoryURL.appendingPathComponent("index.json")
  }

  var recentConversationsCacheURL: URL {
    conversationsDirectoryURL.appendingPathComponent("recent.json")
  }

  var store: ChatFileStore<Conversation> {
    ChatFileStore(
      directoryURL: conversationsDirectoryURL, coding: PersistenceStore.conversationCoding)
  }

  func conversationFilename(for id: UUID) -> String {
    store.fileURL(for: id).lastPathComponent
  }
}

struct CorruptedConversationRecoveryResult: Sendable {
  let recoveredConversations: [Conversation]
  let remainingCount: Int
}

struct CorruptedConversationExportResult: Sendable {
  let url: URL?
  let errorMessage: String?
}

struct CorruptedConversationDocument: Identifiable, Sendable {
  let id: String
  let filename: String
  let location: String
  let contents: String
  let isValidJSON: Bool
  let byteCount: Int
}

struct CorruptedConversationDeletionResult: Sendable {
  let deleted: Bool
  let errorMessage: String?
}

final class PersistenceStore: @unchecked Sendable {
  /// Exactly what the app has always written: compact JSON with ISO 8601
  /// dates. Reading is shared with MaiCore and also accepts numeric dates.
  static let conversationCoding = MaiJSONCoding(
    makeEncoder: { PersistenceStore.makeEncoder() },
    makeDecoder: {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .custom(MaiJSONCoding.decodeFlexibleDate)
      return decoder
    })

  private let fileManager: FileManager
  private let localBaseURL: URL
  private let iCloudFallbackBaseURL: URL
  private let preparesLaunchStorage: Bool
  private let discoversICloudStorage: Bool
  private let preparationLock = NSLock()
  private let quarantineLock = NSLock()
  private let writeQueue = DispatchQueue(
    label: "dev.mai.chat.persistence", qos: .userInitiated)
  private let debounce: TimeInterval = 0.4
  private var didPrepareStorage = false
  // Touched only from writeQueue; serial access guarantees thread-safety.
  private var pendingSettings: DispatchWorkItem?
  private var pendingConversations: DispatchWorkItem?
  private var pendingDrafts: DispatchWorkItem?
  private var pendingBookmarks: DispatchWorkItem?
  private var persistedConversationsByID: [UUID: Conversation] = [:]

  init(fileManager: FileManager = .default, localBaseURL: URL? = nil) {
    self.fileManager = fileManager
    let resolvedLocalBaseURL = localBaseURL ?? PocketMaiDirectories.appDataURL
    self.localBaseURL = resolvedLocalBaseURL
    iCloudFallbackBaseURL = resolvedLocalBaseURL
      .appendingPathComponent("iCloud-conversations", isDirectory: true)
    preparesLaunchStorage = localBaseURL == nil
    discoversICloudStorage = localBaseURL == nil
  }

  private func prepareForAccess() {
    preparationLock.lock()
    defer { preparationLock.unlock() }
    guard !didPrepareStorage else { return }
    if preparesLaunchStorage {
      PocketMaiDirectories.prepareLaunchStorage(fileManager: fileManager)
    }
    try? fileManager.createDirectory(at: localBaseURL, withIntermediateDirectories: true)
    didPrepareStorage = true
  }

  private var localStorageURLs: ConversationStorageURLs {
    ConversationStorageURLs(baseURL: localBaseURL)
  }

  private func iCloudStorageURLs(migrateFallback: Bool = true) -> ConversationStorageURLs {
    if let baseURL = resolvedICloudBaseURL() {
      if migrateFallback {
        migrateFallbackICloudConversationsIfNeeded(to: baseURL)
      }
      return ConversationStorageURLs(baseURL: baseURL)
    }
    return ConversationStorageURLs(baseURL: iCloudFallbackBaseURL)
  }

  private func resolvedICloudBaseURL() -> URL? {
    guard discoversICloudStorage else { return nil }
    return fileManager.url(forUbiquityContainerIdentifier: nil)?
      .appendingPathComponent("Documents", isDirectory: true)
      .appendingPathComponent("PocketMai", isDirectory: true)
      .appendingPathComponent("SharedConversations", isDirectory: true)
  }

  private var settingsURL: URL {
    localBaseURL.appendingPathComponent("settings.json")
  }

  private var draftsURL: URL {
    localBaseURL.appendingPathComponent("drafts.json")
  }

  private var bookmarksURL: URL {
    localBaseURL.appendingPathComponent("bookmarks.json")
  }

  private var launchConversationCacheURL: URL {
    localBaseURL.appendingPathComponent("recent-conversations.json")
  }

  func loadConversations() -> [Conversation] {
    prepareForAccess()
    var conversations = loadConversations(from: localStorageURLs)
    conversations.append(contentsOf: loadConversations(from: iCloudStorageURLs()))
    conversations = Conversation.newest(of: conversations)
    seedPersistedSnapshot(conversations)
    return conversations
  }

  func loadConversationSummaries() -> [ConversationSummary] {
    prepareForAccess()
    let summaries = ConversationSummary.newest(
      of: loadConversationSummaries(from: localStorageURLs)
        + loadConversationSummaries(from: iCloudStorageURLs()))
    Self.persistLaunchConversationCache(summaries, to: launchConversationCacheURL)
    return summaries
  }

  func loadRecentConversationSummaries(
    limit: Int = ConversationSummary.recentCacheLimit
  ) -> [ConversationSummary] {
    prepareForAccess()
    return ConversationSummary.mostRecent(
      ConversationSummary.newest(
        of: loadRecentConversationSummaries(from: localStorageURLs, limit: limit)
          + loadRecentConversationSummaries(
            from: iCloudStorageURLs(migrateFallback: false),
            limit: limit)),
      limit: limit)
  }

  /// Loads only the device-local launch cache. Keep this separate from the merged loader so the
  /// welcome screen never waits for iCloud container discovery or coordinated cloud file access.
  func loadLocalRecentConversationSummaries(
    limit: Int = ConversationSummary.recentCacheLimit
  ) -> [ConversationSummary] {
    prepareForAccess()
    if let data = try? Data(contentsOf: launchConversationCacheURL),
      let cache = try? makeDecoder().decode(PersistedLaunchConversationCache.self, from: data)
    {
      return ConversationSummary.mostRecent(cache.summaries, limit: limit)
    }
    return loadRecentConversationSummaries(from: localStorageURLs, limit: limit)
  }

  func loadConversation(id: UUID) -> Conversation? {
    prepareForAccess()
    let candidates = [
      loadConversation(id: id, from: localStorageURLs),
      loadConversation(id: id, from: iCloudStorageURLs()),
    ].compactMap { $0 }
    return Conversation.newest(of: candidates).first
  }

  func loadBookmarks() -> [MessageBookmark] {
    prepareForAccess()
    guard let data = try? Data(contentsOf: bookmarksURL),
      let persisted = try? makeDecoder().decode(PersistedBookmarks.self, from: data)
    else {
      return []
    }
    var seen = Set<String>()
    return persisted.bookmarks.filter { seen.insert($0.storageKey).inserted }
  }

  func corruptedConversationCount() -> Int {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      corruptedConversationFileURLs(in: locations).count
    }
  }

  func corruptedConversationDocuments() -> [CorruptedConversationDocument] {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      corruptedConversationFileURLs(in: locations).compactMap { file in
        guard let data = try? Data(contentsOf: file.url) else { return nil }
        let rendered = Self.renderCorruptedConversationData(data)
        return CorruptedConversationDocument(
          id: file.identifier,
          filename: file.url.lastPathComponent,
          location: file.location.displayName,
          contents: rendered.contents,
          isValidJSON: rendered.isValidJSON,
          byteCount: data.count)
      }
    }
  }

  func deleteCorruptedConversation(id: String) -> CorruptedConversationDeletionResult {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      guard
        let file = corruptedConversationFileURLs(in: locations).first(where: {
          $0.identifier == id
        })
      else {
        return CorruptedConversationDeletionResult(
          deleted: false, errorMessage: "The corrupted chat file no longer exists.")
      }
      do {
        try fileManager.removeItem(at: file.url)
        return CorruptedConversationDeletionResult(deleted: true, errorMessage: nil)
      } catch {
        return CorruptedConversationDeletionResult(
          deleted: false,
          errorMessage: "Could not delete the corrupted chat: \(error.localizedDescription)")
      }
    }
  }

  /// Deletes only conversation files named by an explicit, confirmed user action.
  /// Quarantined files are deliberately excluded and have their own confirmation flow.
  func deleteConversationFiles(ids: Set<UUID>, completion: (@Sendable () -> Void)? = nil) {
    guard !ids.isEmpty else { completion?(); return }
    writeQueue.async { [weak self] in
      defer { completion?() }
      guard let self else { return }
      self.prepareForAccess()
      let candidates = [
        self.localStorageURLs,
        self.iCloudStorageURLs(migrateFallback: false),
        ConversationStorageURLs(baseURL: self.iCloudFallbackBaseURL),
      ]
      var seen = Set<URL>()
      for storage in candidates
      where seen.insert(storage.baseURL.standardizedFileURL).inserted {
        for id in ids {
          _ = try? storage.store.delete(id: id)
        }
      }
      self.persistedConversationsByID = self.persistedConversationsByID.filter {
        !ids.contains($0.key)
      }
    }
  }

  func exportCorruptedConversationsArchive() -> CorruptedConversationExportResult {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      let files = corruptedConversationFileURLs(in: locations)
      guard !files.isEmpty else {
        return CorruptedConversationExportResult(
          url: nil, errorMessage: "There are no corrupted chats to export.")
      }

      var entries: [(path: String, data: Data)] = []
      for file in files {
        guard let data = try? Data(contentsOf: file.url) else { continue }
        entries.append(("\(file.location.archiveDirectory)/\(file.url.lastPathComponent)", data))
      }
      guard !entries.isEmpty else {
        return CorruptedConversationExportResult(
          url: nil, errorMessage: "Could not read the corrupted chat files.")
      }

      do {
        let filename = "PocketMai-corrupted-chats-\(Int(Date().timeIntervalSince1970))"
        let url = try ConversationExportFiles.url(filename: filename, fileExtension: "zip")
        try ZipArchiveWriter.write(entries: entries, to: url)
        return CorruptedConversationExportResult(url: url, errorMessage: nil)
      } catch {
        return CorruptedConversationExportResult(
          url: nil,
          errorMessage: "Could not create the recovery archive: \(error.localizedDescription)")
      }
    }
  }

  func recoverCorruptedConversations() -> CorruptedConversationRecoveryResult {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      var recovered: [Conversation] = []
      for location in locations {
        recovered.append(contentsOf: recoverCorruptedConversations(in: location.storage))
      }
      return CorruptedConversationRecoveryResult(
        recoveredConversations: recovered,
        remainingCount: corruptedConversationFileURLs(in: locations).count)
    }
  }

  private func loadConversations(from storage: ConversationStorageURLs) -> [Conversation] {
    if let conversations = loadIndexedConversations(from: storage) {
      return conversations
    }

    let legacyConversations = loadLegacyConversations(from: storage)
    let conversations = Conversation.newest(
      of: legacyConversations + loadUnindexedConversations(from: storage))
    if !conversations.isEmpty {
      let persisted = persistConversations(
        conversations,
        summaries: conversations.map(ConversationSummary.init),
        storage: storage,
        writeIndex: true)
      if persisted, !legacyConversations.isEmpty {
        try? fileManager.removeItem(at: storage.conversationsURL)
      }
    }
    return conversations
  }

  private func loadConversationSummaries(from storage: ConversationStorageURLs)
    -> [ConversationSummary]
  {
    guard let data = try? Data(contentsOf: storage.conversationsIndexURL),
      let index = try? makeDecoder().decode(PersistedConversationIndex.self, from: data)
    else {
      if fileManager.fileExists(atPath: storage.conversationsIndexURL.path) {
        _ = quarantineConversationFile(at: storage.conversationsIndexURL, in: storage)
      }
      let legacyConversations = loadLegacyConversations(from: storage)
      let conversations = Conversation.newest(
        of: legacyConversations + loadUnindexedConversations(from: storage))
      guard !conversations.isEmpty else { return [] }
      let summaries = conversations.map(ConversationSummary.init)
      let persisted = persistConversations(
        conversations,
        summaries: summaries,
        storage: storage,
        writeIndex: true)
      if persisted, !legacyConversations.isEmpty {
        try? fileManager.removeItem(at: storage.conversationsURL)
      }
      return summaries
    }
    if let summaries = index.summaries {
      let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
      let ordered = index.ids.compactMap { byID[$0] }
      let unindexed = loadUnindexedConversations(from: storage, excluding: Set(index.ids))
      let validated = ConversationSummary.newest(
        of: validatedConversationSummaries(ordered, in: storage)
          + unindexed.map(ConversationSummary.init))
      if validated.count != ordered.count || !unindexed.isEmpty {
        _ = persistConversations(
          unindexed,
          summaries: validated,
          storage: storage,
          writeIndex: true)
      } else {
        _ = Self.persistRecentConversationCache(summaries: validated, storage: storage)
      }
      return validated
    }
    return []
  }

  private func loadRecentConversationSummaries(
    from storage: ConversationStorageURLs,
    limit: Int
  ) -> [ConversationSummary] {
    guard let data = try? Data(contentsOf: storage.recentConversationsCacheURL),
      let cache = try? makeDecoder().decode(PersistedRecentConversationCache.self, from: data)
    else {
      return []
    }
    let summaries = cache.entries.compactMap { entry -> ConversationSummary? in
      guard entry.filename == storage.conversationFilename(for: entry.summary.id),
        storage.store.fileExists(for: entry.summary.id)
      else { return nil }
      return entry.summary
    }
    return ConversationSummary.mostRecent(summaries, limit: limit)
  }

  /// Reads one conversation file. A file that no longer decodes is quarantined
  /// with its bytes intact; a missing or unreadable file answers nil.
  private func loadConversation(id: UUID, from storage: ConversationStorageURLs) -> Conversation? {
    do {
      return try storage.store.loadChat(id: id)
    } catch ChatFileStoreError.undecodable(let url, _) {
      _ = quarantineConversationFile(at: url, in: storage)
      return nil
    } catch {
      return nil
    }
  }

  private struct CorruptedConversationStorage {
    let archiveDirectory: String
    let displayName: String
    let storage: ConversationStorageURLs
  }

  private struct CorruptedConversationFile {
    let url: URL
    let location: CorruptedConversationStorage

    var identifier: String {
      "\(location.archiveDirectory)/\(url.lastPathComponent)"
    }
  }

  private func corruptedConversationStorageLocations() -> [CorruptedConversationStorage] {
    let local = localStorageURLs
    let iCloud = iCloudStorageURLs(migrateFallback: false)
    let fallback = ConversationStorageURLs(baseURL: iCloudFallbackBaseURL)
    let candidates = [
      CorruptedConversationStorage(
        archiveDirectory: "on-device", displayName: "On This Device", storage: local),
      CorruptedConversationStorage(
        archiveDirectory: "icloud", displayName: "iCloud", storage: iCloud),
      CorruptedConversationStorage(
        archiveDirectory: "icloud-fallback", displayName: "iCloud Fallback", storage: fallback),
    ]
    var seen = Set<URL>()
    return candidates.filter { seen.insert($0.storage.baseURL.standardizedFileURL).inserted }
  }

  private func corruptedConversationFileURLs(
    in locations: [CorruptedConversationStorage]
  ) -> [CorruptedConversationFile] {
    locations.flatMap { location in
      corruptedConversationFileURLs(in: location.storage).map {
        CorruptedConversationFile(url: $0, location: location)
      }
    }
  }

  /// Quarantined files beside the conversations, plus quarantined legacy
  /// documents at the store root such as `conversations.json.corrupt`.
  private func corruptedConversationFileURLs(in storage: ConversationStorageURLs) -> [URL] {
    (storage.store.quarantinedFileURLs()
      + ChatFileStore<Conversation>.quarantinedFileURLs(in: storage.baseURL))
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func renderCorruptedConversationData(_ data: Data) -> (
    contents: String, isValidJSON: Bool
  ) {
    if let object = try? JSONSerialization.jsonObject(with: data),
      let prettyData = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: prettyData, encoding: .utf8)
    {
      return (text, true)
    }
    if let text = String(data: data, encoding: .utf8) {
      return (text, false)
    }
    return (data.base64EncodedString(options: [.lineLength76Characters]), false)
  }

  private func quarantineConversationFile(
    at source: URL,
    in storage: ConversationStorageURLs
  ) -> URL? {
    quarantineLock.lock()
    defer { quarantineLock.unlock() }
    return storage.store.quarantine(fileAt: source)
  }

  private func recoverCorruptedConversations(in storage: ConversationStorageURLs) -> [Conversation]
  {
    var moved: [(source: URL, destination: URL, conversation: Conversation)] = []
    for source in corruptedConversationFileURLs(in: storage) {
      guard let conversation = try? storage.store.restoreQuarantinedFile(at: source) else {
        continue
      }
      moved.append((source, storage.store.fileURL(for: conversation.id), conversation))
    }

    guard !moved.isEmpty else { return [] }
    let conversations = moved.map(\.conversation)
    guard restoreRecoveredConversationsToIndex(conversations, in: storage) else {
      for entry in moved.reversed() {
        try? fileManager.moveItem(at: entry.destination, to: entry.source)
      }
      return []
    }
    return conversations
  }

  private func restoreRecoveredConversationsToIndex(
    _ recovered: [Conversation], in storage: ConversationStorageURLs
  ) -> Bool {
    guard let data = try? Data(contentsOf: storage.conversationsIndexURL),
      let index = try? makeDecoder().decode(PersistedConversationIndex.self, from: data)
    else {
      let conversations = Conversation.newest(
        of: loadLegacyConversations(from: storage)
          + loadUnindexedConversations(from: storage)
          + recovered)
      return persistConversations(
        conversations,
        summaries: conversations.map(ConversationSummary.init),
        storage: storage,
        writeIndex: true)
    }

    var ids: [UUID] = []
    for id in index.ids where !ids.contains(id) {
      ids.append(id)
    }
    var summaries: [UUID: ConversationSummary] = [:]
    for summary in index.summaries ?? [] {
      summaries[summary.id] = summary
    }
    for id in ids where summaries[id] == nil {
      guard let conversation = loadConversation(id: id, from: storage) else { return false }
      summaries[id] = ConversationSummary(conversation: conversation)
    }
    for conversation in recovered {
      if !ids.contains(conversation.id) {
        ids.append(conversation.id)
      }
      summaries[conversation.id] = ConversationSummary(conversation: conversation)
    }
    return Self.persistConversationIndex(
      ids: ids,
      summaries: ids.compactMap { summaries[$0] },
      storage: storage)
  }

  /// Conversation files the index does not know about, such as files another
  /// device synced in or a previous build wrote without indexing.
  private func loadUnindexedConversations(
    from storage: ConversationStorageURLs,
    excluding indexedIDs: Set<UUID> = []
  ) -> [Conversation] {
    ((try? storage.store.chatIDs()) ?? [])
      .filter { !indexedIDs.contains($0) }
      .compactMap { loadConversation(id: $0, from: storage) }
  }

  private func loadIndexedConversations(from storage: ConversationStorageURLs) -> [Conversation]? {
    guard let data = try? Data(contentsOf: storage.conversationsIndexURL),
      let index = try? makeDecoder().decode(PersistedConversationIndex.self, from: data)
    else {
      if fileManager.fileExists(atPath: storage.conversationsIndexURL.path) {
        _ = quarantineConversationFile(at: storage.conversationsIndexURL, in: storage)
      }
      return nil
    }

    var needsRepair = false
    var canRepairIndex = true
    var conversations = index.ids.compactMap { id -> Conversation? in
      do {
        guard let conversation = try storage.store.loadChat(id: id) else {
          needsRepair = true
          return nil
        }
        return conversation
      } catch ChatFileStoreError.undecodable(let url, _) {
        if quarantineConversationFile(at: url, in: storage) != nil {
          needsRepair = true
        } else {
          canRepairIndex = false
        }
        return nil
      } catch {
        canRepairIndex = false
        return nil
      }
    }
    let unindexed = loadUnindexedConversations(from: storage, excluding: Set(index.ids))
    conversations = Conversation.newest(of: conversations + unindexed)
    if canRepairIndex && (needsRepair || !unindexed.isEmpty) {
      _ = Self.persistConversationIndex(
        ids: conversations.map(\.id),
        summaries: conversations.map(ConversationSummary.init),
        storage: storage)
    }
    return conversations
  }

  private func loadLegacyConversations(from storage: ConversationStorageURLs) -> [Conversation] {
    guard let data = try? Data(contentsOf: storage.conversationsURL) else { return [] }
    let decoder = makeDecoder()
    if let envelope = try? decoder.decode(PersistedConversations.self, from: data) {
      return envelope.conversations
    }
    if let conversations = try? decoder.decode([Conversation].self, from: data) {
      return conversations
    }
    _ = quarantineConversationFile(at: storage.conversationsURL, in: storage)
    return []
  }

  /// Writes the conversations that changed since the last save. Placeholder
  /// conversations that never received a message earn no file, unless they
  /// are named in `retaining`, which the app uses for chats holding an unsent
  /// draft or a reply in progress.
  func saveConversations(
    _ conversations: [Conversation], retaining retained: Set<UUID> = [],
    completion: (@Sendable () -> Void)? = nil
  ) {
    let snapshot = conversations
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      let localStorage = self.localStorageURLs
      let iCloudStorage = self.iCloudStorageURLs()
      let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
      let localConversations = snapshot.filter { $0.folderID != ConversationFolder.iCloudID }
      let iCloudConversations = snapshot.filter { $0.folderID == ConversationFolder.iCloudID }
      self.pendingConversations?.cancel()
      let item = DispatchWorkItem { [weak self] in
        defer { completion?() }
        guard let self else { return }
        let localChanged = localConversations.filter {
          self.persistedConversationsByID[$0.id] != $0
        }
        let iCloudChanged = iCloudConversations.filter {
          self.persistedConversationsByID[$0.id] != $0
        }
        let persistedLocal = self.persistConversations(
          localChanged,
          summaries: localConversations.map(ConversationSummary.init),
          storage: localStorage,
          writeIndex: true,
          retaining: retained
        )
        let persistedICloud = self.persistConversations(
          iCloudChanged,
          summaries: iCloudConversations.map(ConversationSummary.init),
          storage: iCloudStorage,
          writeIndex: true,
          retaining: retained
        )
        if persistedLocal && persistedICloud {
          self.persistedConversationsByID = byID
          Self.persistLaunchConversationCache(
            snapshot.map(ConversationSummary.init),
            to: self.launchConversationCacheURL)
        }
      }
      self.pendingConversations = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func saveLoadedConversations(
    _ conversations: [Conversation],
    summaries: [ConversationSummary],
    retaining retained: Set<UUID> = [],
    completion: (@Sendable () -> Void)? = nil
  ) {
    let conversationSnapshot = conversations
    let summarySnapshot = summaries
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      let localStorage = self.localStorageURLs
      let iCloudStorage = self.iCloudStorageURLs()
      let localConversations = conversationSnapshot.filter {
        $0.folderID != ConversationFolder.iCloudID
      }
      let iCloudConversations = conversationSnapshot.filter {
        $0.folderID == ConversationFolder.iCloudID
      }

      self.pendingConversations?.cancel()
      let item = DispatchWorkItem { [weak self] in
        defer { completion?() }
        guard let self else { return }
        let persistedLocal = self.persistConversations(
          localConversations,
          summaries: summarySnapshot.filter { $0.folderID != ConversationFolder.iCloudID },
          storage: localStorage,
          writeIndex: true,
          retaining: retained
        )
        let persistedICloud = self.persistConversations(
          iCloudConversations,
          summaries: summarySnapshot.filter { $0.folderID == ConversationFolder.iCloudID },
          storage: iCloudStorage,
          writeIndex: true,
          retaining: retained
        )
        if persistedLocal && persistedICloud {
          let liveIDs = Set(summarySnapshot.map(\.id))
          self.persistedConversationsByID = self.persistedConversationsByID.filter {
            liveIDs.contains($0.key)
          }
          for conversation in conversationSnapshot {
            self.persistedConversationsByID[conversation.id] = conversation
          }
          Self.persistLaunchConversationCache(
            summarySnapshot,
            to: self.launchConversationCacheURL)
        }
      }
      self.pendingConversations = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func saveConversationSummaries(_ summaries: [ConversationSummary]) {
    let summarySnapshot = summaries
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      let localStorage = self.localStorageURLs
      let iCloudStorage = self.iCloudStorageURLs()
      let localSummaries = self.validatedConversationSummaries(
        summarySnapshot.filter { $0.folderID != ConversationFolder.iCloudID },
        in: localStorage)
      let iCloudSummaries = self.validatedConversationSummaries(
        summarySnapshot.filter { $0.folderID == ConversationFolder.iCloudID },
        in: iCloudStorage)
      let persistedLocal = Self.persistConversationIndex(
        ids: localSummaries.map(\.id),
        summaries: localSummaries,
        storage: localStorage)
      let persistedICloud = Self.persistConversationIndex(
        ids: iCloudSummaries.map(\.id),
        summaries: iCloudSummaries,
        storage: iCloudStorage)
      if persistedLocal && persistedICloud {
        Self.persistLaunchConversationCache(
          summarySnapshot,
          to: self.launchConversationCacheURL)
      }
    }
  }

  func loadSettings() -> AppSettings {
    prepareForAccess()
    guard let data = try? Data(contentsOf: settingsURL),
      let settings = try? makeDecoder().decode(AppSettings.self, from: data)
    else {
      return .defaults
    }
    return settings
  }

  func saveSettings(_ settings: AppSettings) {
    let snapshot = settings
    let url = settingsURL
    let dir = localBaseURL
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      self.pendingSettings?.cancel()
      let item = DispatchWorkItem { Self.persist(snapshot, to: url, dir: dir) }
      self.pendingSettings = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func loadDrafts() -> [UUID: String] {
    prepareForAccess()
    guard let data = try? Data(contentsOf: draftsURL),
      let persisted = try? makeDecoder().decode(PersistedDrafts.self, from: data)
    else {
      return [:]
    }
    var drafts: [UUID: String] = [:]
    for (key, text) in persisted.drafts {
      guard let id = UUID(uuidString: key), !text.isEmpty else { continue }
      drafts[id] = text
    }
    return drafts
  }

  func saveDrafts(_ drafts: [UUID: String]) {
    let drafts = drafts
    let url = draftsURL
    let dir = localBaseURL
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      self.pendingDrafts?.cancel()
      let item = DispatchWorkItem {
        let snapshot = PersistedDrafts(
          drafts: Dictionary(uniqueKeysWithValues: drafts.map { ($0.key.uuidString, $0.value) }))
        Self.persist(snapshot, to: url, dir: dir)
      }
      self.pendingDrafts = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func saveBookmarks(_ bookmarks: [MessageBookmark]) {
    let bookmarks = bookmarks
    let url = bookmarksURL
    let dir = localBaseURL
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      self.pendingBookmarks?.cancel()
      let item = DispatchWorkItem {
        Self.persist(PersistedBookmarks(bookmarks: bookmarks), to: url, dir: dir)
      }
      self.pendingBookmarks = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func factoryReset() {
    let localBaseURL = localBaseURL
    let iCloudBaseURL = iCloudStorageURLs().baseURL
    let iCloudFallbackBaseURL = iCloudFallbackBaseURL
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.pendingSettings?.cancel()
      self.pendingSettings = nil
      self.pendingConversations?.cancel()
      self.pendingConversations = nil
      self.pendingDrafts?.cancel()
      self.pendingDrafts = nil
      self.pendingBookmarks?.cancel()
      self.pendingBookmarks = nil
      self.persistedConversationsByID.removeAll()
      try? self.fileManager.removeItem(at: localBaseURL)
      if iCloudBaseURL != localBaseURL {
        try? self.fileManager.removeItem(at: iCloudBaseURL)
      }
      if iCloudFallbackBaseURL != localBaseURL {
        try? self.fileManager.removeItem(at: iCloudFallbackBaseURL)
      }
    }
  }

  private static func persist<T: Encodable>(_ value: T, to url: URL, dir: URL) {
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(value)
      try data.write(to: url, options: [.atomic])
    } catch {
      // Persistence errors are surfaced through the next successful read; avoid blocking.
    }
  }

  private static func persistLaunchConversationCache(
    _ summaries: [ConversationSummary],
    to url: URL
  ) {
    do {
      let cache = PersistedLaunchConversationCache(
        summaries: ConversationSummary.mostRecent(summaries))
      let data = try makeEncoder().encode(cache)
      if (try? Data(contentsOf: url)) == data {
        return
      }
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic])
    } catch {
      // The full indexes remain authoritative and will refresh this cache on the next load/save.
    }
  }

  /// Summaries whose conversation file is actually present, so the index
  /// never points at a file that does not exist.
  private func validatedConversationSummaries(
    _ summaries: [ConversationSummary],
    in storage: ConversationStorageURLs
  ) -> [ConversationSummary] {
    summaries.filter { storage.store.fileExists(for: $0.id) }
  }

  private static func persistConversationIndex(
    ids: [UUID],
    summaries: [ConversationSummary],
    storage: ConversationStorageURLs
  ) -> Bool {
    do {
      let fileManager = FileManager.default
      try fileManager.createDirectory(
        at: storage.conversationsDirectoryURL, withIntermediateDirectories: true)
      let encoder = makeEncoder()
      let index = PersistedConversationIndex(ids: ids, summaries: summaries)
      let data = try encoder.encode(index)
      try data.write(to: storage.conversationsIndexURL, options: [.atomic])
      try writeRecentConversationCache(summaries: summaries, storage: storage, encoder: encoder)
      return true
    } catch {
      return false
    }
  }

  @discardableResult
  private static func persistRecentConversationCache(
    summaries: [ConversationSummary],
    storage: ConversationStorageURLs,
    encoder: JSONEncoder = makeEncoder()
  ) -> Bool {
    do {
      try writeRecentConversationCache(summaries: summaries, storage: storage, encoder: encoder)
      return true
    } catch {
      return false
    }
  }

  private static func writeRecentConversationCache(
    summaries: [ConversationSummary],
    storage: ConversationStorageURLs,
    encoder: JSONEncoder
  ) throws {
    let entries = ConversationSummary.mostRecent(summaries).map {
      PersistedRecentConversationEntry(
        filename: storage.conversationFilename(for: $0.id),
        summary: $0)
    }
    let cache = PersistedRecentConversationCache(entries: entries)
    let data = try encoder.encode(cache)
    if (try? Data(contentsOf: storage.recentConversationsCacheURL)) == data {
      return
    }
    try data.write(to: storage.recentConversationsCacheURL, options: [.atomic])
  }

  /// Writes conversation files through the shared store, then the index. The
  /// index lists only summaries whose file exists afterwards: a placeholder
  /// the store declined to write, unless retained, is not indexed either.
  private func persistConversations(
    _ conversations: [Conversation],
    summaries: [ConversationSummary],
    storage: ConversationStorageURLs,
    writeIndex: Bool,
    retaining retained: Set<UUID> = []
  ) -> Bool {
    do {
      let store = storage.store
      try fileManager.createDirectory(
        at: storage.conversationsDirectoryURL, withIntermediateDirectories: true)
      for conversation in conversations {
        try store.save(conversation, evenIfDisposable: retained.contains(conversation.id))
      }
      if writeIndex {
        let indexed = validatedConversationSummaries(summaries, in: storage)
        let encoder = Self.makeEncoder()
        let index = PersistedConversationIndex(ids: indexed.map(\.id), summaries: indexed)
        let data = try encoder.encode(index)
        try data.write(to: storage.conversationsIndexURL, options: [.atomic])
        try Self.writeRecentConversationCache(
          summaries: indexed, storage: storage, encoder: encoder)
      }
      return true
    } catch {
      return false
    }
  }

  private func migrateFallbackICloudConversationsIfNeeded(to cloudBaseURL: URL) {
    let fallbackStorage = ConversationStorageURLs(baseURL: iCloudFallbackBaseURL)
    guard fallbackStorage.baseURL != cloudBaseURL else { return }
    let fallbackConversations = loadConversations(from: fallbackStorage)
    guard !fallbackConversations.isEmpty else { return }

    let cloudStorage = ConversationStorageURLs(baseURL: cloudBaseURL)
    let merged = Conversation.newest(
      of: loadConversations(from: cloudStorage) + fallbackConversations)
    // Copies keep every conversation, placeholders included, exactly as they were.
    let persisted = persistConversations(
      merged,
      summaries: merged.map(ConversationSummary.init),
      storage: cloudStorage,
      writeIndex: true,
      retaining: Set(merged.map(\.id)))
    // Keep the fallback store after copying. It may contain quarantined or temporarily unreadable
    // files that were intentionally excluded from the decoded migration set.
    _ = persisted
  }

  private func seedPersistedSnapshot(_ conversations: [Conversation]) {
    let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    writeQueue.async { [weak self] in
      self?.persistedConversationsByID = byID
    }
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
