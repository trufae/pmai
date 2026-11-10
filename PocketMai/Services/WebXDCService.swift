import Foundation
import MaiDocuments

typealias WebXDCRevision = MaiDocuments.WebXDCRevision
typealias WebXDCAppInfo = MaiDocuments.WebXDCAppInfo
typealias WebXDCImportResult = MaiDocuments.WebXDCImportResult
typealias WebXDCError = MaiDocuments.WebXDCError

extension PocketMaiDirectories {
  static var webXDCAppsURL: URL {
    appDataURL.appendingPathComponent("WebXDCApps", isDirectory: true)
  }
}

// Retain the iOS call sites while sharing archive validation and revisions with Mac.
let WebXDCLibrary = WebXDCStore(rootURL: PocketMaiDirectories.webXDCAppsURL)
