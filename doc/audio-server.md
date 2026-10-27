# OpenAI-compatible chat and audio

The iOS server and CLI expose configured providers through OpenAI-shaped HTTP
requests. Chat uses an isolated history with the selected agent. Configured
agent tools execute inside pmai when tool execution is enabled; clients receive
the final answer. Client-supplied function definitions are not registered as tools.

## CLI REPL

Start pmai normally, then start serving from its prompt:

```text
/remote serve --protocol openai
/remote status
/remote stop
```

The listener defaults to `http://127.0.0.1:11435/v1`. The REPL remains usable.
Serving captures the current agent and provider configuration at startup; stop
and restart it to change those defaults. Existing ACP, OpenTunnel and Forwiroh
serving commands keep their behavior. One server runs at a time in this REPL.

```text
/remote serve --protocol openai --port 8080 --tools
/remote serve --protocol openai --bind 0.0.0.0
```

`--tools` enables the selected agent's configured tools. Existing project tool
approvals still apply. Set `PMAI_HTTP_TOKEN` before starting pmai to require a
Bearer token on all requests. LAN serving creates a mode-0600 token file at
`~/.pmai/remote-server/openai/token` when no token was provided. `/remote status`
shows the endpoint and token file location, without printing the token itself.
`/remote stop`, exiting the REPL or enabling Airplane Mode stops serving.

In another terminal:

```sh
curl http://127.0.0.1:11435/v1/models
curl http://127.0.0.1:11435/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello"}],"stream":true}'
```

Use `agent:ID` to select an enabled agent, `providerID::model` to select another
configured provider with the selected agent's settings, or omit `model` for the
selected agent. Chat streaming uses SSE chunks followed by `[DONE]`.

## Audio routes

| Route | Input | Output |
| --- | --- | --- |
| `GET /v1/models` | — | Agent/provider models and native audio IDs |
| `GET /v1/voices?model=MODEL` | Optional model selector | Voice IDs |
| `POST /v1/audio/transcriptions` | Multipart `model`, `file`, optional `language`, `response_format` | Transcript |
| `POST /v1/audio/speech` | JSON `model`, `input`, `voice`, optional `response_format`, `speed` | Audio bytes |

On iOS, enable **Settings → OpenAPI Server → Serve**. Audio model selectors use
`providerUUID::model` (portable provider IDs also work). Discovered audio models
appear in `/v1/models`. CLI selectors use the provider's configured string ID.

`system-stt` uses Apple speech recognition and an installed language. The iOS
server follows its Apple-server fallback permission; Airplane Mode disables
that fallback. The macOS CLI requires on-device recognition and Speech
Recognition permission. Native audio IDs are not advertised on other platforms.
Native transcription supports `json` and `text`, without streaming or timestamps.

`system-tts` renders an installed system voice without playing on the host.
Choose a voice ID from `/v1/voices`, a language such as `en-US`, or `default`.
WAV output is assembled before return. `response_format=pcm` streams signed
little-endian 16-bit mono samples at 24 kHz as synthesis runs. Other native
formats return an error. Use `stream_format=audio`; SSE audio events and the
Realtime API are outside this integration.

```sh
curl http://127.0.0.1:11435/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"system-tts","input":"Hello","voice":"default","response_format":"wav"}' \
  --output speech.wav
curl http://127.0.0.1:11435/v1/audio/transcriptions \
  -F model=system-stt -F file=@speech.wav -F response_format=json
```

Provider selectors forward audio using configured credentials and headers,
preserving request options and upstream HTTP error status. Speech bytes stream
from upstream on Apple platforms; other platforms currently buffer the response.
Uploads are limited to 25 MiB including multipart metadata. Native-transcription
temporary files are removed when the request ends.

## Groq

Groq already exists as an iOS provider preset. Select **Groq** in the provider
editor, enter the key, and refresh models. In **Settings → Voices**, choose Groq
as **File / Recorded Audio Provider** and select a Whisper model. This explicitly
uploads recordings and imports to Groq. Microphone input records a file first;
the native live engine is not used while a provider is selected. On-device
transcription remains the default. Airplane Mode blocks provider audio and
cancels active provider transcription.

For speech output, choose Groq in a role's voice settings. Orpheus has separate
English and Saudi Arabic voice catalogs and speech models. Chat and speech
choices remain separate. The app queues chunks under Groq's 200-character
speech limit; HTTP clients must split longer inputs themselves.

Configure the CLI with its existing provider commands:

```text
/provider add groq https://api.groq.com/openai/v1 --api-key-file /path/to/groq-key
/models groq
```

Then select `groq::whisper-large-v3-turbo` for transcription or
`groq::canopylabs/orpheus-v1-english` with voice `autumn` for speech. Provider
model catalogs reflect their active models. Built-in Groq voices do not require
an unsupported `/voices` discovery request.

The wire format follows the [OpenAI transcription reference](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)
and [speech reference](https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create).
Groq choices and limits follow its [Orpheus documentation](https://console.groq.com/docs/text-to-speech/orpheus)
and [transcription guide](https://console.groq.com/docs/speech-to-text).

## Checks

`swift test --package-path MaiCore --filter 'groq|audioMultipart|providerAudioTranscription|httpProxy'`
checks audio requests and chat routes without external providers. Run
`python3 test/openai-http-smoke.py /path/to/pmai` for the full loopback HTTP test
with a local fixture, including binary audio, authentication and provider errors.

### iOS chat streaming

With `stream: true`, `/v1/chat/completions` sends text deltas as SSE events,
followed by a stop chunk and `[DONE]`. `/api/chat` and `/api/generate` send
NDJSON deltas followed by `done: true`. Responses use HTTP chunked transfer;
`stream: false` still returns a single JSON response.

PocketMai forwards provider updates while generation is running. Providers that
only return completed text, and requests with **Run PocketMai tools** enabled,
return their answer once it is complete. Tool protocol messages are kept internal;
`pocketmai_tool_calls` is included in the final chunk.

Idle streams send an SSE comment or an empty NDJSON line every 15 seconds.
Clients should ignore these keepalives. Failed writes and consumer cancellation
cancel generation; keepalives also detect disconnected clients during inference.
Errors after the response starts are sent as an `error` event/object, without a
success terminator. The existing LLM timeout still applies.
