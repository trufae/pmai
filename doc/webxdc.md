# Webxdc apps in PocketMai

PocketMai runs shareable `.xdc` archives containing `index.html`, a
`manifest.toml`, and local HTML/CSS/JavaScript/assets. Load the host bridge before
using it:

```html
<script src="webxdc.js"></script>
<script src="app.js"></script>
```

Create/import apps in **Apps**, edit their files and revisions, and export them
as `.xdc` to share. A minimal manifest is:

```toml
name = "My voice companion"
description = "An alternative interface for PocketMai"
```

The script tags above must execute in that order (do not use `async` on
`webxdc.js`). In PocketMai, the host serves its own `webxdc.js` for
`xdc://app`, even if the archive includes a stub with that filename. The
extension is available synchronously after that script has executed; callers
do not need to poll, wait for a custom ready event, or load the script again.
A plain browser or another WebXDC host may expose `window.webxdc` without
providing PocketMai's extension.

### Troubleshoot an unavailable native API

Check these values in the running app (or its WebXDC debug console):

```js
console.log({
  protocol: location.protocol,
  webxdc: !!window.webxdc,
  pocketmai: !!window.webxdc?.pocketmai,
  host: window.webxdc?.pocketmai?.host,
  version: window.webxdc?.pocketmai?.version
});
```

- If `webxdc` is false, check that `webxdc.js` loaded successfully before
  your application script and that the app is running in a WebXDC host.
- If `webxdc` is true but `pocketmai` is false, check that the app is running
  inside PocketMai's **Apps/WebXDC runner**, not a browser preview or another
  host. This is a missing extension, **not** a permission failure. Verify the
  installed PocketMai build includes the native extension; changing inference
  grants or reloading `webxdc.js` will not fix an unsupported host.
- If `pocketmai` exists but the host/version does not match, use a portable
  fallback rather than assuming API compatibility.
- If the extension is present, call `capabilities()` to inspect effective
  grants. Disabled inference/transcription/synthesis permissions do **not**
  remove the namespace; they block the corresponding native operations.

When updating an app's JavaScript or HTML, ensure the runner uses the new app
revision. For an unavailable extension in a supported PocketMai build, inspect
the WebXDC debug log and report the host/version and PocketMai build. Do not
silently fall back to browser microphone or direct provider network calls:
those have different permissions and privacy properties.

`webxdc.pocketmai` is a **PocketMai extension**, not part of the webxdc standard.
Other hosts can run the portable parts of an app, but do not have to implement
inference or speech. Never assume that loading `webxdc.js` implies support.

## Detect the host and check permissions

```js
const mai = window.webxdc?.pocketmai;
if (mai?.host === 'pocketmai' && mai.version === 1) {
  const caps = await mai.capabilities();
  // caps.host === 'pocketmai'; caps.version === 1
  // caps.permissions: {inference, transcription, synthesis} -- effective booleans
  // caps.features: {streaming: true, cancellation: true, microphone: true,
  //                 providerAPIs: true, chat: true, tools: true}
  // chat/tools require an attached chat and the Chat bridge setting.
  // caps.voicePrompt: the built-in conversational voice system prompt
  showVoiceUI(caps.permissions.transcription && caps.permissions.synthesis);
} else {
  showPortableUI();
}
```

`capabilities()` is available without a grant. The **Inference and speech APIs**
checkbox is in **Settings → Tools → Native → WebXDC Apps**, alongside the other
WebXDC features. It is enabled by default to preserve existing app grants;
turning it off blocks inference, speech and provider discovery for every app.

Tap **Permissions** in the running app's top bar to manage this checkbox,
**Microphone**, **Audio playback**, and the app's own **Inference providers**,
**Speech to text**, and **Text to speech** grants. App grants are also available
under **App Permissions** in its Apps detail page. New and imported apps
start with all three disabled. Grants belong to the installed app on this device;
revisions keep them, exports do not include them, and importing an export does not
restore them. JavaScript and manifests cannot grant permissions.

Apps can ask the user for grants without making a provider request:

```js
const caps = await mai.requestPermissions({
  capabilities: ['inference', 'transcription', 'synthesis']
});
```

This shows native confirmation prompts for missing grants and returns the same
shape as `capabilities()`. Denial or a disabled WebXDC feature rejects with
`NotAllowedError` and directions to the relevant control. Older PocketMai builds
may not provide `requestPermissions`; check for the function before using it.

Speech to text additionally requires **Microphone** in PocketMai's WebXDC
settings and the relevant iOS microphone/speech permissions. Text to speech also
requires **Audio Playback** in WebXDC settings. Native checks enforce these gates
even if an app modifies the bridge or posts native messages itself. A missing
grant rejects the call with `NotAllowedError`; handle that error even after a
successful capability check.

Configured providers perform network requests in the native host. This does not
require the app's general WebXDC Internet permission. It does require the
appropriate extension grant, and PocketMai's offline policy still applies. Tell
users that their chosen service may receive app text or recorded audio and charge
for usage. The bridge never returns API keys, auth tokens, headers, or endpoint
URLs.

Only the app's main `xdc://app` frame may invoke native operations. Iframes and
remote pages cannot. Keep untrusted content in iframes; scripts executing in the
main app frame have the app's grants.

## Async requests, streaming, cancellation and lifetime

Every method returns a Promise. Pass an `AbortSignal` in `signal`, or call
`.cancel()` on the original returned Promise. Do not spread/serialize a signal or
callback into an application payload. They are local control options:

```js
const controller = new AbortController();
const pending = mai.complete({
  messages: [{role: 'user', content: 'Say hello'}],
  signal: controller.signal,
  onUpdate(event) {
    if (event.event === 'text') output.textContent = event.text;
  }
});
stopButton.onclick = () => controller.abort(); // or pending.cancel()
try {
  const {text} = await pending;
  output.textContent = text;
} catch (error) {
  if (error.name !== 'AbortError') showError(error.message);
}
```

Text updates are **whole snapshots**, not token deltas: replace the displayed
text, rather than appending. The final resolved result is authoritative. A
provider may deliver only a final result. `onUpdate` errors are logged without
breaking the request. Use `textContent`, not `innerHTML`, for model output.

Cancellation immediately rejects the JavaScript Promise with `AbortError`,
cancels the native task, stops owned microphone/playback work, and suppresses late
results. A backend may already have processed or billed a request. Abort does not
undo remote work. Navigation, page teardown, stopping a session, closing its
runner, revoking an app grant, or changing PocketMai settings cancels outstanding
requests. Tool-written todo data and memory updates do not cancel requests.
A hidden runner cannot start new native requests. Closing the runner
retains the web app's page state; reopening allows new requests.

There are at most eight native requests per app at once and one active speech
operation (listening or speaking). Wait for one speech operation to finish before
starting another. `BusyError` indicates those limits. On cancellation the native
resource may need a short cleanup interval before it is available again.

Errors use `error.name`: `AbortError`, `NotAllowedError`, `NotSupportedError`,
`NotFoundError`, `BusyError`, `TypeError`, or `OperationError`. The message gives
the provider/OS failure or a setting to change. Catalog results are hints;
availability, installed speech assets, connectivity, or credentials can change
before execution.

## Discover providers, models, voices and languages

```js
const providers = await mai.providers();
// [{id, name, available, capabilities: ['inference', 'transcription', 'synthesis']}]
const chat = providers.find(p => p.available && p.capabilities.includes('inference'));
const models = await mai.models({provider: chat.id}); // string[]
const voices = await mai.voices({provider: 'system'});
// [{id, name, language}] -- language is empty if the service does not report it
const languages = await mai.languages({provider: 'system', purpose: 'synthesis'});
// string[]: locale identifiers, e.g. en-US (some recognition locales use en_US)
```

Provider IDs are `apple`, `mlx`, `system`, or an opaque UUID for a configured,
enabled endpoint. IDs are local to the installation: discover them again on each
device, and do not ship hardcoded endpoint UUIDs. Providers expose only the
capabilities covered by this app's grants; `providers()` needs at least one grant.
`available` indicates local runtime/offline availability, not a successful remote
health or credential check. Generic compatible endpoints may advertise speech
but reject it if their server does not implement the relevant audio endpoint.

| Method | Options and results | Required grant |
| --- | --- | --- |
| `capabilities()` | Host/version, effective permissions, features, voice prompt | None |
| `requestPermissions({capabilities})` | Request one to three named permissions through native prompts; returns capabilities | User approval for each missing grant |
| `providers()` | Provider descriptors described above | At least one extension grant |
| `models({provider?, purpose?})` | Model ID strings; purpose defaults to `inference`, or `transcription` / `synthesis` | The chosen purpose |
| `voices({provider?, model?})` | Voice descriptors; provider defaults to `system`; optional speech model changes model-specific voice choices | Synthesis |
| `languages({provider?, purpose?})` | Locale strings; provider defaults to `system`, purpose defaults to `transcription` or can be `synthesis` | The chosen purpose |

All methods also accept `signal`. Local inference model lists contain the Apple
configured model or cached MLX repositories. Remote inference models come from the
existing provider catalog implementation. Speech model catalogs use PocketMai's
built-in choices or configured model where available; other remote transcription
catalogs may include models for other purposes, so validate with the backend.
`system` speech has no selectable model and returns `[]` for speech models.

Remote language enumeration returns `[]`: it means **not enumerable**, not that
the provider supports no languages. System transcription languages are candidate
iOS recognition locales; support and installed assets for the selected native
backend can differ. For live transcription, a missing downloaded speech model
causes an operation error rather than a silent switch to a cloud service.

## Inference outside the chat

```js
const result = await mai.complete({
  provider: chat.id,             // optional: PocketMai default inference provider
  model: models[0],              // optional: selected provider's configured default
  systemPrompt: 'You are a museum guide. Answer briefly in plain English.',
  messages: [
    {role: 'user', content: 'What is this sculpture?'},
    {role: 'assistant', content: 'Which sculpture are you looking at?'},
    {role: 'user', content: 'The bronze horse.'}
  ],
  onUpdate: event => { output.textContent = event.text; },
  signal: controller.signal
});
// result: {text: '...'}
```

Each completion creates a fresh provider session with only the supplied messages
and system prompt. The request uses no current-chat history or memory and never writes to the
current PocketMai chat or changes its selected provider. The app owns its
history: pass it again on the next call or discard it. Normal provider usage
accounting still applies. This is the default `scope: 'isolated'`: tools, MCP and
agent actions are disabled. Use explicit chat scope below to access chat tools.

Messages must contain `role: 'user' | 'assistant'` and string `content`, with
1–200 entries totaling at most 256,000 UTF-8 bytes. The optional `systemPrompt`
can contain at most 64,000 UTF-8 bytes. Use it instead of a `system` message.
`mode: 'voice'` selects the voice prompt when `systemPrompt` is omitted; otherwise
the default is a generic helpful assistant. A supplied custom prompt replaces the
default. PocketMai's provider privacy/redaction, timeouts and offline behavior
still apply. Keep app histories small for low latency and model context limits.

## Inference with the attached chat's tools and context

```js
const caps = await mai.capabilities();
if (!caps.features.chat) throw new Error('Open this app from a chat and enable Chat bridge.');
const result = await mai.complete({
  scope: 'chat',
  mode: 'voice',
  messages: [{role: 'user', content: 'Use the enabled tools to check my calendar.'}],
  signal: controller.signal
});
await mai.speak({text: result.text, signal: controller.signal});
```

Chat scope uses a snapshot of the chat the app was started from, including its
history, memory, working folder, tool selections, MCP grants and tool
calling mode. Switching chats does not retarget a running app. Stop and reopen
the app to attach it to a different chat. A missing or deleted attached chat
rejects with `NotFoundError`; a disabled **Chat bridge** rejects with
`NotAllowedError`. The app's inference grant and **Inference and speech APIs**
setting are still required. No OpenAPI server or server tool-execution switch
is needed for this native JavaScript API.

Omit `provider` and `model` to inherit the attached chat's selection; explicit
values override only this request. By default the chat's system prompt is kept.
`mode: 'voice'` selects the voice prompt, and `systemPrompt` replaces the prompt
for this request. The usual tool policy, offline restrictions and approval flow
apply, including MCP discovery and execution. Chat scope never enables tools
that are disabled in the attached chat. Capability flags describe availability
of chat scope, not whether any particular tool is enabled.

Supplied messages are appended to the chat snapshot. Pass only the app's own
conversation history, without copying the host transcript. Requests and replies
are not saved to the host chat. Tool actions can still change data or invoke
services, just as they can in normal chat. Chat completions currently return
their final answer after the tool loop; callers must not require streaming
updates to display the result. Cancellation and runner lifetime rules also apply
while the model or a tool is running.

## Speech to text from the microphone

```js
const capture = mai.listen({
  provider: 'system',           // omit to use configured PocketMai transcription
  backend: 'file',              // optional: 'file' or 'live'; omit for app setting
  language: 'en-US',            // optional: configured recognition language
  silenceSeconds: 1.25,         // clamped to 0.5–8; endpointing for file backend
  maxSeconds: 30,               // bounded to 1–120, default 30
  onUpdate(event) {
    // {event: 'transcript', text, isFinal, language}
    transcript.textContent = event.text;
  },
  signal: controller.signal
});
sendNowButton.onclick = () => capture.finish();
const {text, language} = await capture;
```

`listen()` uses PocketMai's existing recognition engines and transcription policy,
not browser `getUserMedia` or `SpeechRecognition`. `provider: 'system'` explicitly
chooses native recognition. Omit `provider` to honor the configured transcription
endpoint; supply an endpoint ID to choose a compatible service, optionally with
`model`. File recognition records locally and transcribes after silence, manual
finish, or the time limit; it normally emits a final transcript only. Temporary
recordings are removed at completion/cancellation rather than attached to chat.

`backend: 'live'` uses the existing iOS 26+ SpeechTranscriber implementation and
can emit provisional transcript snapshots. It needs supported, installed speech
assets. Finish live captures manually or use the duration bound. A configured or
explicit remote transcription endpoint uses the file backend regardless of the
native backend option. `finish()` ends capture and resolves a transcript;
`.cancel()` / abort discards it. A no-speech result may reject with an operation
error. There is no automatic permission escalation or fallback to Apple servers:
PocketMai's separate Apple server-transcription preference is honored.

## Text to speech and voice-friendly prompts

```js
await mai.speak({
  text: 'Hey! Ready to explore?',
  provider: 'system',           // omit for PocketMai's configured assistant voice
  voice: voices[0].id,          // optional: voice identifier from this provider
  language: 'en-US',
  rate: 0.5,                   // system rate, clamped 0–1
  pitch: 1.0,                  // system pitch, clamped 0.5–2
  signal: controller.signal
});
// resolves {spoken: true} after playback completes, not just after synthesis
```

For remote speech, use a compatible endpoint ID and its voice ID. Optional
`model` overrides that request's speech model without changing settings. Remote
voices/languages/rate/pitch follow the service's existing PocketMai implementation;
system rate and pitch options are not promises of remote support. Speech uses an
app-owned TTS player, so cancelling it does not cancel a chat response. Microphone
and speaker share the device's audio hardware: alternate listening and playback
to avoid transcribing the avatar's own speech. This API provides turn-based voice,
not simultaneous duplex audio or phoneme/viseme events.

Supply nonempty, speakable text up to 32,000 UTF-8 bytes. PocketMai's existing
speech sanitizer skips technical content; do not depend on it to turn a long
Markdown answer into a good spoken response. Choose `mode: 'voice'`, or provide
a suitable custom system prompt:

```js
const reply = await mai.complete({
  mode: 'voice',
  systemPrompt: 'You are Pip, a friendly companion. Answer in the user’s language. '
    + 'Use one or two short, colloquial sentences. Return only natural spoken text. '
    + 'No Markdown, lists, code, URLs, stage directions or internal reasoning.',
  messages: history,
  signal: controller.signal
});
await mai.speak({text: reply.text, signal: controller.signal});
```

The built-in prompt is available as `(await mai.capabilities()).voicePrompt`, so
an app can show it in an editable personality/prompt field. A voice prompt helps
keep responses conversational but cannot guarantee the model follows it.

## Runnable avatar example

[examples/webxdc/voice-avatar](../examples/webxdc/voice-avatar) contains a small
animated CSS avatar, provider/model/voice selection, an editable system prompt,
transcript, Start/Stop, and Send now controls. It loops through microphone →
transcription → inference → speech playback. When chat scope is available,
**Use attached chat context and tools** is checked and uses that chat's model;
uncheck it for isolated inference with the provider/model selectors. All requests share
an AbortController, so Stop interrupts the current phase. It keeps its last 20
messages in requests and stores no history outside the page.

Build the shareable archive:

```sh
make -C examples/webxdc/voice-avatar
```

Import `voice-avatar.xdc` into PocketMai and run it. The example requests its
three app grants. If a WebXDC feature is disabled, use **Permissions** in the
top bar to enable it, then tap **Start** to retry. Configure a
working inference provider and any remote speech credentials in PocketMai first.
The example uses silence-ended file transcription for short turns; the same API
can drive a WebGL character when WebGL is enabled in WebXDC settings. Animate from
application states or transcript/text events; precise audio-driven lip sync is
not exposed by v1.

## Existing chat integration and portability

`webxdc.sendUpdate()` and `webxdc.sendToChat()` remain separate from the
PocketMai extension. Depending on the existing WebXDC chat-interaction setting,
updates can trigger the attached chat. Use `mai.complete()` for voice inference,
with isolated or chat scope as appropriate. State updates
are useful for deliberately shared game state; avoid publishing prompts,
transcripts, or private answers through them automatically.

Keep core app behavior independent of the extension and offer an explanation or
portable UI on other hosts. Package local assets, feature-detect WebGL and media
capabilities, discover local provider IDs, and handle permission/availability
errors at the point of use. Permissions, credentials and downloaded models do
not travel with a shared `.xdc`.

For implementation checks, run `node test/webxdc-bridge-test.cjs` and the iOS
`WebXDCPocketMaiTests` / `WebXDCImportTests` suites. Real microphone, installed
speech assets, remote services and audible playback also need device validation.


## Importing apps on iOS

Open a `.xdc` document with **PocketMai**, import it from **Apps → Import**, or
share it to PocketMai. Imports open **Apps → App details**, with an import notice
and a choice to review the app or run it. You can inspect the icon and files,
review permissions, and press **RUN** when ready. Importing never starts an app
without your confirmation.

An app with identical files is reported as **Already Imported** and reuses the
existing installation, keeping its data and permissions. ZIP entry order,
compression and timestamps do not affect this check. Different apps with the
same name get the first free suffix: `Name (2)`, `Name (3)`, and so on. Matching
names is case insensitive. This check compares the installed current revision;
if you edited the installed files, importing the original creates a separate app.

For immediate launch, use the document's **Open in PocketMai** action. iOS does
not support launching the containing app from a Share extension; if the system
refuses that request, the shared files remain queued until PocketMai next opens.
See [Apple's app extension lifecycle documentation](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html).
