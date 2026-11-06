import Foundation
import MaiCore
import MaiOpenAI

extension MaiCLI {
  static func chatGPTAccountCommand(
    _ command: String, provider: ConfiguredProvider,
    directory: URL, terminal: TerminalWriter
  ) async {
    let store = ChatGPTCredentialStore(
      providerID: provider.options["account"]?.stringValue ?? provider.id, directory: directory)
    do {
      switch command {
      case "status":
        let account = try store.load()
        await terminal.line(
          account?.isSignedIn == true
            ? "Using ChatGPT plan: \(account!.label)\nManage usage: https://chatgpt.com/settings/usage"
            : "ChatGPT is signed out. /provider login \(provider.id)")
      case "logout":
        let revoked = try await ChatGPTAuth.shared.signOut(store: store)
        await terminal.line("Signed out of ChatGPT for '\(provider.id)'.")
        if !revoked {
          await terminal.line(
            "Remote revocation was not confirmed. Disconnect pmai at https://chatgpt.com/settings/usage."
          )
        }
      default:
        let listener = try ChatGPTCallbackListener()
        let attempt = try await ChatGPTAuth.shared.beginSignIn(
          store: store,
          redirectURI: listener.redirectURI, useIDTokenHint: false)
        await terminal.line(
          "Continue with ChatGPT in your browser:\n\(attempt.authorizationURL.absoluteString)\nWaiting for sign-in (5 minutes)…"
        )
        // The URL contains fresh PKCE/state and no retained ID-token hint.
        let browser = Process()
        #if os(macOS)
          browser.executableURL = URL(fileURLWithPath: "/usr/bin/open")
          browser.arguments = [attempt.authorizationURL.absoluteString]
        #elseif os(Linux)
          browser.executableURL = URL(fileURLWithPath: "/usr/bin/env")
          browser.arguments = ["xdg-open", attempt.authorizationURL.absoluteString]
        #endif
        browser.standardOutput = FileHandle.nullDevice
        browser.standardError = FileHandle.nullDevice
        try? browser.run()
        do {
          let callback = try await listener.callback(state: attempt.state)
          let account = try await ChatGPTAuth.shared.finishSignIn(
            attempt, callback: callback, store: store)
          await terminal.line(
            "You're using your ChatGPT plan: \(account.label)\nManage usage: https://chatgpt.com/settings/usage\n/models \(provider.id) lists available models; /model \(provider.id)::MODEL selects one."
          )
        } catch {
          listener.cancel()
          await ChatGPTAuth.shared.cancelSignIn(attempt)
          throw error
        }
      }
    } catch is CancellationError {
      await terminal.line("ChatGPT sign-in cancelled.")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }
}
