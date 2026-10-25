# Conversation storage

Small chats continue to use the existing `<id>.json` document. Large chats use
that filename for a versioned manifest, with immutable JSON chunks and large
payload files in `<id>.json.parts/`. Use conversation export to distribute one
portable JSON file; copying only a live manifest does not copy its transcript.

The shared MaiCore `ChatFileStore` supports both layouts:

- `loadChatPage`: a read-only window of at most 64 messages by default, with a
  byte budget and an explicit range/revision. Previous/next requests overlap so
  clients can preserve a message anchor while discarding distant history.
- `loadChatHistory`: complete parent context for inference/editing, with completed
  child transcripts referenced on disk.
- `loadChat`: the complete portable model, including child transcripts.
- `exportChat(id:to:)`: stream the existing JSON schema into a file.

A window cannot be saved or encoded as a complete chat. Clients load the full
parent context before editing, sending, compacting, searching or exporting.
Scrolling never determines the model's context. Operations that explicitly need
full history can still require substantial memory, particularly with compaction
disabled; paging reduces the cost of opening and browsing history.

Chunks contain up to 64 messages or approximately 256 KiB of encoded message
data. Large individual values are stored separately. PocketMai leaves image
payloads on disk until its asynchronous image loader needs them. Other large
individual values are decoded when their page is requested.

Writers retain a small change ledger, reuse unaffected chunks and replace the
manifest only after new files are available. They keep the preceding generation
for incomplete iCloud downloads. Readers serialize file access on workers, and
child references pin their files until those references are released. Replaced
chunks and payloads are reclaimed after they leave both retained generations
and any live child snapshots. No background task loads the whole history simply
because a chat is visible.

Legacy files are converted on demand with a structural streaming reader. The
first conversion scans the file once and keeps an exact `.json.legacy` backup.
Date formats, IDs, tool/provider state and the portable import/export schema are
unchanged. Older applications can read portable exports, not live manifests.
