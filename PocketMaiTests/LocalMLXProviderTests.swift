import Foundation
import MLXLMCommon
import XCTest

@testable import PocketMai

@MainActor
final class LocalMLXProviderTests: XCTestCase {
  func testUnsupportedHardwareNeverDownloadsOrTouchesCache() async throws {
    for availability: LocalMLXAvailability in [
      .simulator, .metalUnavailable, .unsupportedGPU("Apple A12 GPU"),
    ] {
      let modelID = "pmai-tests/\(UUID().uuidString)"
      let directory = try XCTUnwrap(LocalMLXModelCache.cacheDirectoryURL(forRepoID: modelID))
      defer { try? LocalMLXModelCache.deleteRepository(modelID) }
      let snapshot = directory.appendingPathComponent("snapshots/test")
      try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
      let config = snapshot.appendingPathComponent("config.json")
      try Data("{}".utf8).write(to: config)
      let downloader = FailingDownloader(directory: directory)
      let provider = LocalMLXProvider(downloader: downloader, availability: availability)
      for allowDownload in [false, true] {
        do {
          try await provider.load(modelID: modelID, allowDownload: allowDownload)
          XCTFail("Unsupported hardware must be rejected before loading or downloading")
        } catch LocalMLXError.unavailable(let reason) {
          XCTAssertEqual(reason, availability)
        }
      }
      let requests = await downloader.requestedIDs
      XCTAssertTrue(requests.isEmpty)
      XCTAssertEqual(try Data(contentsOf: config), Data("{}".utf8))
    }
  }

  func testFreshModelRequiresExplicitDownload() async throws {
    let modelID = "pmai-tests/\(UUID().uuidString)"
    let directory = try XCTUnwrap(LocalMLXModelCache.cacheDirectoryURL(forRepoID: modelID))
    defer { try? LocalMLXModelCache.deleteRepository(modelID) }
    let downloader = FailingDownloader(directory: directory)
    let provider = LocalMLXProvider(downloader: downloader, availability: .available)
    XCTAssertFalse(LocalMLXModelCache.containsRepository(modelID))

    do {
      try await provider.load(modelID: modelID)
      XCTFail("Chat must not start downloading a missing model")
    } catch LocalMLXError.modelNotDownloaded(let id) {
      XCTAssertEqual(id, modelID)
    }
    let initialRequests = await downloader.requestedIDs
    XCTAssertTrue(initialRequests.isEmpty)

    let progress = Progress(totalUnitCount: 0)
    do {
      try await provider.load(modelID: " \(modelID)\n", allowDownload: true) { update in
        progress.totalUnitCount = update.totalUnitCount
        progress.completedUnitCount = update.completedUnitCount
      }
      XCTFail("Expected the downloader's error")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .notConnectedToInternet)
    }
    let requests = await downloader.requestedIDs
    XCTAssertEqual(requests, [modelID])
    XCTAssertEqual(progress.totalUnitCount, 100)
    XCTAssertEqual(progress.completedUnitCount, 25)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testCachedModelSurvivesLoadFailure() async throws {
    let modelID = "pmai-tests/\(UUID().uuidString)"
    let directory = try XCTUnwrap(LocalMLXModelCache.cacheDirectoryURL(forRepoID: modelID))
    defer { try? LocalMLXModelCache.deleteRepository(modelID) }
    let snapshot = directory.appendingPathComponent("snapshots/test")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
    // The downloader fails before MLX reads these cache-presence fixtures.
    let weights = snapshot.appendingPathComponent("model.safetensors")
    let contents = Data("cached model".utf8)
    try contents.write(to: weights)
    XCTAssertTrue(LocalMLXModelCache.containsRepository(modelID))

    let downloader = FailingDownloader(directory: directory)
    let provider = LocalMLXProvider(downloader: downloader, availability: .available)
    for allowDownload in [false, true] {
      do {
        try await provider.load(modelID: modelID, allowDownload: allowDownload)
        XCTFail("Expected the downloader's error")
      } catch let error as URLError {
        XCTAssertEqual(error.code, .notConnectedToInternet)
      }
      XCTAssertTrue(LocalMLXModelCache.containsRepository(modelID))
      XCTAssertEqual(try Data(contentsOf: weights), contents)
    }
    let requests = await downloader.requestedIDs
    XCTAssertEqual(requests, [modelID, modelID])
  }

  func testExplicitDownloadStillValidatesModelID() async throws {
    let downloader = FailingDownloader(directory: FileManager.default.temporaryDirectory)
    let provider = LocalMLXProvider(downloader: downloader, availability: .available)
    let modelID = "https://huggingface.co/org/model"
    do {
      try await provider.load(modelID: modelID, allowDownload: true)
      XCTFail("Expected an invalid model ID error")
    } catch LocalMLXError.invalidModelID(let id) {
      XCTAssertEqual(id, modelID)
    }
    let requests = await downloader.requestedIDs
    XCTAssertTrue(requests.isEmpty)
  }
}

private actor FailingDownloader: Downloader {
  let directory: URL
  private(set) var requestedIDs: [String] = []

  init(directory: URL) {
    self.directory = directory
  }

  func download(
    id: String,
    revision: String?,
    matching patterns: [String],
    useLatest: Bool,
    progressHandler: @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    requestedIDs.append(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: directory.appendingPathComponent("download.partial"))
    let progress = Progress(totalUnitCount: 100)
    progress.completedUnitCount = 25
    progressHandler(progress)
    throw URLError(.notConnectedToInternet)
  }
}
