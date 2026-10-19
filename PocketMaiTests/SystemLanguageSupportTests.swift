import Foundation
import Observation
import XCTest

@testable import PocketMai

@MainActor
final class SystemLanguageSupportTests: XCTestCase {
  func testSlowCatalogLoadDoesNotBlockReadersAndPublishesOnce() async throws {
    let loader = SystemLanguageSupport.CatalogLoader()
    let started = expectation(description: "Background load started")
    let published = expectation(description: "Catalog observation updated")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }

    withObservationTracking {
      _ = loader.catalog
    } onChange: {
      published.fulfill()
    }
    loader.preload {
      XCTAssertFalse(Thread.isMainThread)
      started.fulfill()
      _ = release.wait(timeout: .now() + 5)
      return SystemLanguageSupport.Catalog(
        voices: [], recognitionLocales: ["es_ES", "en-US", "es-ES"])
    }
    await fulfillment(of: [started], timeout: 2)

    // Reads and another preload must return while the system service is still waiting.
    XCTAssertNil(loader.catalog)
    loader.preload {
      XCTFail("Preloading twice must not start another system query")
      return SystemLanguageSupport.Catalog(voices: [], recognitionLocales: [])
    }
    XCTAssertNil(loader.catalog)

    release.signal()
    await fulfillment(of: [published], timeout: 2)
    let catalog = try XCTUnwrap(loader.catalog)
    XCTAssertEqual(Set(catalog.speechRecognitionLocaleIdentifiers), ["en-US", "es-ES"])
    XCTAssertEqual(catalog.speechRecognitionLocaleIdentifiers.count, 2)
  }

  func testSelectedLanguageAndDisplayNamesDoNotNeedTheSystemCatalog() {
    XCTAssertTrue(
      SystemLanguageSupport.chatLanguageIdentifiers(including: "zz_ZZ").contains("zz-ZZ"))
    XCTAssertTrue(SystemLanguageSupport.languageDisplayName("es_ES").contains("es-ES"))
    XCTAssertEqual(SystemLanguageSupport.sortedLanguageIdentifiers(["es_ES", "es-ES"]), ["es-ES"])
  }
}
