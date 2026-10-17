import AuthenticationServices
import MaiOpenAI
import SwiftUI
import UIKit

struct ChatGPTSignInSection: View {
  let providerID: String
  let onSignedIn: @MainActor () async -> Void
  @State private var account: ChatGPTCredentials?
  @State private var message: String?
  @State private var signingIn = false
  @State private var loginTask: Task<Void, Never>?
  @State private var authenticationSession: ASWebAuthenticationSession?
  @State private var presenter = ChatGPTAuthPresenter()
  @State private var showWelcome = false
  @AppStorage("chatGPTPlanWelcomeShown") private var welcomeShown = false

  private var store: ChatGPTCredentialStore { .init(providerID: providerID) }

  var body: some View {
    Section {
      if let account, account.isSignedIn {
        Label("Using ChatGPT plan", systemImage: "checkmark.circle.fill")
        Text(account.label).font(.caption).foregroundStyle(.secondary)
      }
      Button {
        loginTask = Task { await signIn() }
      } label: {
        HStack {
          if signingIn { ProgressView() }
          Text("Continue with ChatGPT")
        }
      }
      .disabled(signingIn)
      if signingIn {
        Button("Cancel Sign-In", role: .cancel) {
          loginTask?.cancel()
          authenticationSession?.cancel()
        }
      }
      if account?.isSignedIn == true {
        Button("Sign Out", role: .destructive) {
          Task {
            do {
              let revoked = try await ChatGPTAuth.shared.signOut(store: store)
              account = try store.load()
              message =
                revoked
                ? "Signed out."
                : "Signed out locally. Remote revocation was not confirmed; disconnect pmai in ChatGPT settings."
            } catch { message = error.localizedDescription }
          }
        }.disabled(signingIn)
      }
      Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
      if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
    } header: {
      Text("ChatGPT subscription")
    } footer: {
      Text(
        "Eligible requests use your ChatGPT plan and its usage limits. Add another ChatGPT provider to sign in with a different account or workspace."
      )
      Text(OpenAIEndpoint.chatGPTSpeechUnavailableMessage)
    }
    .task { do { account = try store.load() } catch { message = error.localizedDescription } }
    .onDisappear {
      loginTask?.cancel()
      authenticationSession?.cancel()
    }
    .alert("You're using your ChatGPT plan", isPresented: $showWelcome) {
      Button("Got it") { welcomeShown = true }
    } message: {
      Text(
        "Eligible requests in PocketMai use your ChatGPT plan. Review and manage this app's usage in ChatGPT settings."
      )
    }
  }

  @MainActor private func signIn() async {
    signingIn = true
    message = nil
    defer {
      signingIn = false
      authenticationSession?.cancel()
      authenticationSession = nil
    }
    do {
      let listener = try ChatGPTCallbackListener()
      let attempt = try await ChatGPTAuth.shared.beginSignIn(
        store: store, redirectURI: listener.redirectURI)
      do {
        let browser = ASWebAuthenticationSession(
          url: attempt.authorizationURL,
          callbackURLScheme: "pocketmai"
        ) { _, error in
          if error != nil { listener.cancel() }
        }
        browser.presentationContextProvider = presenter
        authenticationSession = browser
        guard browser.start() else { throw ChatGPTError.message("Could not open ChatGPT sign-in.") }
        let callback = try await listener.callback(
          state: attempt.state,
          returnToApp: URL(string: "pocketmai://oauth/chatgpt-complete"))
        account = try await ChatGPTAuth.shared.finishSignIn(
          attempt, callback: callback, store: store)
        authenticationSession?.cancel()
        authenticationSession = nil
        if !welcomeShown { showWelcome = true }
        await onSignedIn()
      } catch {
        listener.cancel()
        await ChatGPTAuth.shared.cancelSignIn(attempt)
        throw error
      }
    } catch is CancellationError {
      message = "ChatGPT sign-in cancelled."
    } catch { message = error.localizedDescription }
  }
}

@MainActor
private final class ChatGPTAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding
{
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
  }
}
