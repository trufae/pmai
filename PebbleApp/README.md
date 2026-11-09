# PocketMai for Pebble Time 2

A C watch app for the Pebble Time 2 (`emery`). It shows the PocketMai logo,
uses the watch microphone for dictation and displays the agent's text reply
on a scrollable screen. PebbleKit JS runs inside the Pebble phone app and
relays AppMessage requests to PocketMai over phone loopback.

## Build and install

Install Node.js and the [current Pebble SDK](https://developer.repebble.com/sdk/).
From the repository root, run:

```sh
cd PebbleApp
npm ci
pebble build
```

The package is `build/PebbleApp.pbw`. Install it using the Pebble mobile
app's developer connection (`pebble install --cloudpebble`), or try the
watch UI with `pebble install --emulator emery`.

## Pair and use

1. Open **Settings → Pebble** in PocketMai for iOS or Kotlin Android and enable
   the bridge. In the Pebble phone app, grant the PocketMai watch app its
   **Local Network** permission.
2. In PocketMai's Pebble settings, tap **Pair a Watch**, then choose **Pair
   Phone** on the watch. Confirm that the six digits on both screens match
   before approving on the phone. To change watches, use **Forget Watch**.
3. Mark up to eight user prompts as favorites on iOS, or add up to eight
   named messages in Android's Pebble settings. Select **Refresh Prompts** on
   the watch after editing them.
4. Select **Talk to the Agent**, speak and confirm the system transcription,
   or select a preset to send it directly. Scroll the reply with Up and Down.
   **New Watch Chat** starts a fresh chat on the next turn. **Refresh Prompts**
   also checks for a pending reply after a disconnect.

Keep PocketMai open on the phone during use. Its **Keep Awake** setting can
prevent the screen from locking. The Pebble phone app must remain connected to
the watch. System dictation depends on the Pebble phone app's transcription
support and connectivity. Model and tool approval behavior is handled by
PocketMai. Full replies and conversation history are saved in the phone app.
