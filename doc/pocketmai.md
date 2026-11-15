[Documentation](README.md) · [Project home](../README.md)

# PocketMai on iOS

See the [feature overview](features.md) for device tools, documents, the browser,
and WebXDC apps, or [remote hosts](remote-hosts.md) to connect to a workstation.

## Share a conversation between devices

Tap the chat title, or long-press a chat in the left sidebar, then choose
**Share...** and **AirDrop** or **Mail**. This sends a `.pocketmai`
conversation file. Open the received file
with PocketMai, choose its destination folder, and import it to continue chatting.
On a computer, import the very same file in pmai:

```text
/import ~/Downloads/My Chat.pocketmai
```

The file keeps the conversation and its embedded attachments, including tool
messages and nested subagent chats. It does not add the diagnostic report or
export your provider credentials. The receiving device uses its own configured
providers. Older `.pocketmai.json` conversation files remain importable; to send
to an older PocketMai version, rename the file to end in `.pocketmai.json`.

**Export...** offers readable copies such as Plain Text (.txt), Markdown, HTML and
Word. **Debug Report** is for troubleshooting; it is not needed to transfer a chat.

## Location

For a walking or driving guide on iOS, enable **Location** in the chat's tool
picker and allow location access when prompted. GPS is the default; each message
gets a fresh position, its accuracy, and measurement time in the AI's context.
Enable **Web Search** or **Browser** as well for nearby maps and information.
Location is sampled when sending messages while using the app, rather than
continuously tracked in the background. For a fixed place, turn off **Use GPS
location** in Settings → Tools → Contextual → Location and enter a manual location.
If access was denied, use **Open iOS Settings** there to restore it.

## Voice setup and privacy

Use device voices or configure a speech provider independently of your chat
model. Audio transcription stays on device by default; the resulting chat text
goes to your selected model provider.

See [OpenAI-compatible chat and audio server](audio-server.md) for CLI serving, native audio HTTP endpoints, and Groq transcription/voices.

### OpenAI text-to-speech

ChatGPT subscription sign-in provides the Responses API connection; it does not
provide Speech API access. Keep ChatGPT selected for chat and configure a separate
speech provider below. OpenAI speech requires an API key and separate API billing.
See the [ChatGPT plan endpoint contract](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).

1. Open **Settings > Voices > Assistant** (or **User**). **Browse Built-in Voices**
   lists OpenAI voices even before you configure a provider. Tap **Add OpenAI Speech
   Provider**, or use **Settings > Providers > Add Provider**, choose **OpenAI API**,
   set the base URL to `https://api.openai.com/v1`, and save your API key using
   the provider's existing credentials form. Enable the provider. Adding it from
   Voices selects it for that role without changing your chat provider.
2. Open **Settings > Voices > Assistant** (or **User**) and select that provider.
   Its built-in voices are available immediately, without voice discovery.
3. Leave **Speech Model** at its `gpt-4o-mini-tts` default, or choose a supported
   TTS model, then select a **Voice**. The speech model is shared by roles using
   that provider and is independent of its chat model.
4. Tap **Test Voice** for a paid preview. **Speak Message**, **Speak From Here**,
   live conversation replies, and the `speak` tool use these same settings.

Long messages are divided into bounded requests and played through the existing
speech queue. Pausing while synthesis is pending keeps the returned audio paused.

These are AI-generated voices. OpenAI documents 13 voices for `gpt-4o-mini-tts`;
`tts-1` and `tts-1-hd` support a smaller set. Unsupported selections show an
error without switching voices. Compatible servers are selectable before discovery
and load `/voices` when selected. **Refresh Voices** reports discovery failures;
you can also enter a **Voice ID** manually for servers without a voice catalog.
Switching providers chooses an available voice instead of carrying an unsupported
voice from the previous provider. Returning from System preserves the saved voice.
Compatible servers retain custom speech model names; a blank speech model uses
their server default.
Existing compatible-provider configurations keep their previous synthesis model
when migrated. Airplane Mode retains the existing system-voice behavior.
See the [official TTS guide](https://developers.openai.com/api/docs/guides/text-to-speech).

As of October 17, 2026, OpenAI has announced retirement of `tts-1`, `tts-1-hd`
and the dated `gpt-4o-mini-tts` models on January 6, 2027. See
[OpenAI's deprecation notice](https://developers.openai.com/api/docs/deprecations#2026-10-01-text-to-speech-models).
Realtime speech is outside this integration.

### Voice privacy

Voice recordings and imported audio stay on device for transcription by default.
Settings > Voices > **Allow Apple Server Transcription** explicitly permits an
Apple-server fallback if local recognition fails or is unavailable. The app's
airplane button overrides this permission immediately and cancels active server
recognition. Returning online restores the saved preference.

On iOS 26+, file transcription first tries `SpeechAnalyzer` / `SpeechTranscriber`
with an already-installed language model. The fallback on iOS 26+ and the primary
path on iOS 18–25 use `SFSpeechRecognizer`, checking `supportsOnDeviceRecognition`
before setting `requiresOnDeviceRecognition = true`. Without the server opt-in,
missing local support or recognition errors never trigger a server request.
Native iOS Live always uses the on-device analyzer and requires an installed model.
PocketMai does not initiate speech-model downloads.

Apple documents the guarantees in
[Asking Permission to Use Speech Recognition](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition),
[`requiresOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
and [`supportsOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).
This setting controls audio transcription; sending the resulting text to a chat
still uses that chat's selected model provider.

## CarPlay

On iOS 26.4 or later, PocketMai can start or resume a spoken chat from the car
and run favorite user prompts with one tap. Mark favorites and grant microphone
access under Settings > CarPlay on the iPhone. If the selected transcription
backend needs Speech Recognition permission, grant it there as well.

Device builds require the
[CarPlay voice-based conversation entitlement](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
from Apple for `io.github.trufae.mai`. Once it is enabled, regenerate the app's
provisioning profile and build with the following Xcode setting for the PocketMai
app target:

```text
POCKETMAI_ENTITLEMENTS = PocketMai/PocketMaiCarPlay.entitlements
```

For example, append
`POCKETMAI_ENTITLEMENTS=PocketMai/PocketMaiCarPlay.entitlements` to an
`xcodebuild -project PocketMai.xcodeproj -scheme PocketMai` device build.
The default signing configuration uses the regular entitlement file.

Test with CarPlay Simulator and a supported iPhone, then in a parked vehicle.
With the iPhone locked, open PocketMai on CarPlay, ask two questions, end the
session, reopen it with Resume Conversation, and run a favorite. Check that
replies play through the car, the favorite returns to the menu without opening
the microphone, and disconnecting or switching away stops capture and playback.
