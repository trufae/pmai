# iOS background replies

PocketMai treats suspension as a normal end to a connection's lifetime. Keeping
an HTTP stream open does not make the process runnable after iOS suspends it.

## Current policy

- Start a finite UIKit background allowance with each main reply or side question.
  It gives a short app switch or screen lock a chance to finish the work. iOS
  controls its duration; creating more tasks does not extend the process's budget.
- On entering the background, copy streamed text into the conversation and drain
  pending conversation, draft, settings, and bookmark writes immediately.
- When the allowance expires, save the partial reply with an interruption message,
  cancel main replies, side questions, follow-up generation, and child agents,
  then release the allowances. Cancellation cannot undo a remote tool's effects.
- Returning to the app does not retry an interrupted prompt or replay its tools.
  The user can review the saved reply and send a new message. Explicit `/then`
  actions remain queued while backgrounded and can run after returning.
- Live Activities and completion/approval notifications report status while the
  process can run. They do not extend execution. New settings default them off;
  saved preferences remain intact. Notification permission is requested only when
  enabling notifications in Settings. Delivery and cleanup run on a serial queue
  so notification-service IPC cannot block the main thread.
- The audio background mode remains for real voice conversations and speech
  playback. Replies never play silent audio to keep the process alive.
- Remote agent connections close on background entry, retaining conversation and
  session IDs. Reconnecting restores a session when the remote supports it;
  transport reconnection alone does not guarantee that an interrupted job survived.

The former silent-audio watchdog, continued-processing task submission, system
progress reporting, and automatic timeout continuation while away have
been removed. Local notifications cannot report a result obtained only after the
app has been suspended.

Apple documents the finite execution and cancellation requirements in
[Choosing Background Strategies for Your App](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
and [Extending your app's background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).
[Continued processing](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
is a legitimate option for suitable user-initiated jobs, but has visible system
progress UI and remains subject to cancellation. It is not part of this reply policy.

## Reliable work while the phone is suspended

This needs a server-owned job, independent of the client's streaming connection.
It is a protocol change, not another iOS keepalive mechanism:

1. Submit a turn with a stable idempotency key and receive a durable job ID.
2. Keep the job and tool execution on the server when the client disconnects.
3. Persist ordered events and results. Reconnect using the job ID and last event
   cursor, fetching a snapshot if events have expired. Deduplicate events locally.
4. Represent approval requests and cancellation as durable job state. A client
   disconnect must neither approve a tool nor silently cancel the server job.
5. Optionally send an APNs completion/approval notification from the server, after
   explicit user opt-in. Opening the app fetches authoritative job state.

Do not emulate this by automatically resending a chat-completions POST: a tool
may already have run, and most streaming endpoints provide no replay cursor.
Local model generation likewise cannot be moved to a server without changing
the selected execution mode.

## Validation

The focused iOS tests use a local deterministic provider and explicit expiration
events to check immediate persistence, cancellation, foreground queue draining,
and compatibility with saved settings. Simulator tests do not reproduce real
device suspension, GPU restrictions, or resource pressure. Device validation
should cover locking during streaming and tool approval, switching back before
and after expiration, and checking saved partial text after terminating the app.
