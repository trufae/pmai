[Documentation](README.md) · [PocketMai on iOS](pocketmai.md)

# PocketMai CarPlay

PocketMai includes a CarPlay voice-based conversation experience for starting or resuming a spoken chat and running favorite prompts from the car.

## Status

### Done in this repo

- **CarPlay scene configuration**: `PocketMai/Info.plist` declares `CPTemplateApplicationSceneSessionRoleApplication` with scene class `CPTemplateApplicationScene`, configuration name `CarPlay`, and delegate `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`.
- **CarPlay implementation**: `PocketMai/CarPlay/CarPlaySceneDelegate.swift` (`@available(iOS 26.4, *)`) implements `CPTemplateApplicationSceneDelegate` and presents a voice-control UI with:
  - **Talk to the Agent**: starts a new spoken conversation.
  - **Resume Conversation**: resumes the selected/latest resumable conversation when available.
  - **Favorite Prompts**: runs selected user prompts and plays the agent’s reply aloud.
- **Favorites/settings UI**: `PocketMai/CarPlay/CarPlayFavoritesView.swift` and `Settings > CarPlay` let you mark user prompts as CarPlay favorites and request/review microphone and speech recognition permissions.
- **CarPlay-aware app behavior**: CarPlay turns/audio/session handling are integrated in `PocketMai/Stores/AppStore.swift`, `PocketMai/Stores/AppStore+BackgroundActivity.swift`, `PocketMai/Services/TTSPlayer.swift`, and `PocketMai/Services/LiveVoiceSession.swift`.
- **Entitlements file**: `PocketMai/PocketMaiCarPlay.entitlements` includes `com.apple.developer.carplay-voice-based-conversation` plus the same app group/iCloud entitlements as `PocketMai/PocketMai.entitlements`.
- **Default signing config**: `PocketMai.xcodeproj/project.pbxproj` now defaults `POCKETMAI_ENTITLEMENTS` to `PocketMai/PocketMaiCarPlay.entitlements` for Debug and Release.

### Still required outside this repo

1. **Apple entitlement approval**: request/enable the [CarPlay voice-based conversation entitlement](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements) for App ID `io.github.trufae.mai` in your Apple Developer account.
2. **Provisioning profiles**: regenerate and download development/App Store provisioning profiles that include the CarPlay capability.
3. **Signed build with correct profile**: archive/export with a profile that actually contains the CarPlay entitlement. If the app is signed with `PocketMaiCarPlay.entitlements` but the provisioning profile does not include the capability, signing/export will fail.
4. **App Store submission**: upload a new build/archive made after the above is in place. A previously uploaded binary signed without the CarPlay entitlement will not gain CarPlay support.

> Until Apple grants the entitlement and your provisioning profile includes it, you cannot ship a working CarPlay-enabled App Store build. For local/non-CarPlay builds with a profile that lacks the capability, override entitlements (see below).

## Requirements

- **iOS**: 26.4 or later for the CarPlay scene/delegate as implemented (`CarPlaySceneDelegate` is `@available(iOS 26.4, *)`).
- **Apple Developer**: CarPlay voice-based conversation entitlement approved for `io.github.trufae.mai`.
- **Provisioning**: development/App Store profile regenerated with the CarPlay entitlement.
- **Device/setup**: supported iPhone and CarPlay vehicle/head unit, or CarPlay Simulator for development testing.
- **Permissions**: microphone access required for “Talk to the Agent”. Speech Recognition permission may be required depending on the selected transcription backend (grant from iPhone Settings/CarPlay settings as prompted).
- **Content**: favorite prompts must be non-empty user prompts to appear/run as CarPlay favorites.

## Build and signing

### Default (CarPlay-enabled)

The PocketMai app target signs with:

```text
POCKETMAI_ENTITLEMENTS = PocketMai/PocketMaiCarPlay.entitlements
```

Use this for dev/device/App Store builds when your provisioning profile includes `com.apple.developer.carplay-voice-based-conversation`.

Example device/archive build:

```sh
xcodebuild -project PocketMai.xcodeproj -scheme PocketMai -configuration Release
```

(Ensure Xcode/CLI signing selects a provisioning profile that contains the CarPlay entitlement.)

### Override for non-CarPlay builds

If the entitlement/profile is not yet available, you can build without CarPlay entitlement:

```sh
xcodebuild -project PocketMai.xcodeproj -scheme PocketMai \
  POCKETMAI_ENTITLEMENTS=PocketMai/PocketMai.entitlements
```

This avoids CarPlay signing requirements but the app will **not** appear/function as a CarPlay app.

### Verifying the built app

Before submitting, inspect the embedded entitlements/provisioning profile of the archive/IPA and confirm `com.apple.developer.carplay-voice-based-conversation` is present. Also confirm the CarPlay scene configuration remains in the built app’s `Info.plist`.

## Development and testing

- **CarPlay Simulator**: test UI/flow during development (Xcode Additional Tools / CarPlay Simulator). Behavior still depends on correct entitlements/signing for device-style validation.
- **Dev/device builds**: work for CarPlay when built/signed with a development profile that includes the approved CarPlay entitlement and installed on a compatible iPhone (iOS 26.4+).
- **In-car testing**: test in a parked vehicle. Recommended checks:
  - With iPhone locked/unlocked as applicable, open PocketMai on CarPlay.
  - Ask two questions and confirm replies play through the car.
  - End the session, reopen, and use **Resume Conversation**.
  - Run a favorite prompt and confirm it plays the reply without opening the microphone.
  - Disconnect/switch away and confirm capture/playback stop.

## How to use

### On iPhone

1. Open **PocketMai > Settings > CarPlay**.
2. Grant **Microphone Access** if needed. Grant **Speech Recognition** if your selected transcription backend requires it.
3. Add/select **user prompts** as favorites (empty prompts are disabled). Favorites appear in PocketMai on CarPlay and play the agent’s reply aloud.
4. Ensure CarPlay is set up for your vehicle/iPhone and PocketMai is allowed/visible in CarPlay settings as applicable.

### In CarPlay

1. Open **PocketMai** from the CarPlay app launcher.
2. Choose:
   - **Talk to the Agent**: starts a new voice conversation.
   - **Resume Conversation**: continues the selected/latest resumable conversation (disabled if none).
   - A **Favorite Prompt**: runs that prompt and speaks the reply.
3. During voice interaction the app shows states such as Starting/Listening/Thinking/Speaking/Paused/Error. Use **End** to stop the CarPlay voice session.
4. If microphone access is missing, CarPlay shows an alert asking to enable it on iPhone.

## Troubleshooting

- **App doesn’t show in CarPlay**: most commonly the distributed build lacks `com.apple.developer.carplay-voice-based-conversation` (wrong entitlements/profile), or Apple hasn’t approved the entitlement/profile wasn’t regenerated. Rebuild with the CarPlay entitlements and a matching profile, then reinstall/resubmit.
- **Signing/export fails**: the selected provisioning profile likely doesn’t include the CarPlay capability required by `PocketMaiCarPlay.entitlements`. Regenerate the profile or temporarily override to `PocketMai/PocketMai.entitlements` for non-CarPlay builds.
- **“Resume Conversation” disabled**: no resumable non-archived conversation with messages is available.
- **Favorites missing**: add user prompts in PocketMai and mark them in **Settings > CarPlay** (prompt message must not be empty).
- **Voice unavailable / no mic**: grant microphone (and speech recognition if needed) on iPhone; check iOS/CarPlay permissions and that the device/connection supports audio input.

## Related files

- `PocketMai/Info.plist`
- `PocketMai/CarPlay/CarPlaySceneDelegate.swift`
- `PocketMai/CarPlay/CarPlayFavoritesView.swift`
- `PocketMai/PocketMaiCarPlay.entitlements`
- `PocketMai/PocketMai.entitlements`
- `PocketMai.xcodeproj/project.pbxproj`
- `doc/pocketmai.md`
