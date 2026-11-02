package org.mai.kotlin

import android.app.Application
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Base64
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONObject
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom

// Termux intentionally runs under another UID. RUN_COMMAND launches a PTY relay
// there; no access to Termux's private files or shell executable is assumed here.
internal class TermuxShell(private val app: Application, private val id: String,
    private var columns: Int, private var rows: Int,
    private val onData: suspend (ByteArray) -> Unit, private val onStatus: (String) -> Unit,
    private val onError: (String) -> Unit) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val writes = Channel<String>(64)
    private var server: ServerSocket? = null
    private var socket: Socket? = null
    private var closed = false
    private var result: PendingIntent? = null

    fun start() {
        scope.launch {
            try {
                val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
                server = listener
                listener.soTimeout = 60_000
                val token = ByteArray(32).apply { SecureRandom().nextBytes(this) }
                    .joinToString("") { "%02x".format(it.toInt() and 255) }
                val source = app.assets.open("termux-terminal.py").bufferedReader().use { it.readText() }
                val callback = Intent(app, TermuxResultReceiver::class.java).setData(Uri.parse("pmai-terminal:$id"))
                result = PendingIntent.getBroadcast(app, 0, callback, PendingIntent.FLAG_CANCEL_CURRENT or
                    (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0))
                val script = "if ! command -v python >/dev/null; then echo 'Install Python in Termux: pkg install python' >&2; exit 127; fi; exec python -c \"\$1\" \"\$2\" \"\$3\" \"\$4\" \"\$5\""
                val intent = Intent("com.termux.RUN_COMMAND").setClassName("com.termux", "com.termux.app.RunCommandService")
                    .putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/sh")
                    .putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", script, "pmai-terminal", source,
                        listener.localPort.toString(), token, columns.toString(), rows.toString()))
                    .putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
                    .putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", result)
                    .putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "PocketMai terminal")
                withContext(Dispatchers.Main) { app.startService(intent) }
                onStatus("Connecting to Termux…")
                val deadline = System.nanoTime() + 60_000_000_000L
                var reader: java.io.BufferedReader
                while (true) {
                    check(System.nanoTime() < deadline) { "Termux did not connect. Enable allow-external-apps=true in ~/.termux/termux.properties and install Python (pkg install python)." }
                    val peer = listener.accept()
                    peer.soTimeout = 5000
                    val candidate = peer.getInputStream().bufferedReader()
                    val auth = try { candidate.readBoundedLine(128) } catch (_: Exception) { null }
                    if (auth != null && MessageDigest.isEqual(auth.toByteArray(), token.toByteArray())) {
                        socket = peer; reader = candidate; peer.soTimeout = 0; peer.tcpNoDelay = true; break
                    }
                    peer.close()
                }
                listener.close(); server = null
                onStatus("Termux")
                launch {
                    val out = requireNotNull(socket).getOutputStream().bufferedWriter()
                    for (message in writes) { out.write(message); out.newLine(); out.flush() }
                }
                resize(columns, rows)
                while (true) {
                    val line = reader.readBoundedLine(64 * 1024) ?: error("Termux connection closed")
                    val message = JSONObject(line)
                    if (message.has("data")) onData(Base64.decode(message.getString("data"), Base64.NO_WRAP))
                    if (message.has("exit")) { onStatus("Exited (${message.getInt("exit")})"); break }
                }
            } catch (error: Exception) {
                if (!closed) onError("${error.localizedMessage}\nTermux needs command permission, allow-external-apps=true in ~/.termux/termux.properties, and pkg install python.")
            } finally { close() }
        }
    }
    private fun write(message: JSONObject) {
        if (!closed && writes.trySend(message.toString()).isFailure) onError("Termux input queue is full. Paste smaller chunks.")
    }
    fun send(data: ByteArray) {
        data.asList().chunked(16 * 1024).forEach { write(JSONObject().put("data", Base64.encodeToString(it.toByteArray(), Base64.NO_WRAP))) }
    }
    fun resize(columns: Int, rows: Int) {
        this.columns = columns; this.rows = rows
        write(JSONObject().put("columns", columns).put("rows", rows))
    }
    fun close() {
        closed = true
        runCatching { server?.close() }; runCatching { socket?.close() }
        result?.cancel()
        writes.close(); scope.cancel()
    }
    companion object {
        const val PERMISSION = "com.termux.permission.RUN_COMMAND"
        fun installed(context: Context) = try { context.packageManager.getPackageInfo("com.termux", 0); true }
            catch (_: PackageManager.NameNotFoundException) { false }
        fun permitted(context: Context) = context.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED
    }
}

class TermuxResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.data?.schemeSpecificPart ?: return
        val result = intent.getBundleExtra("result") ?: return
        val message = listOf(result.getString("errmsg"), result.getString("stderr"))
            .filterNotNull().filter { it.isNotBlank() }.joinToString("\n")
        (context.applicationContext as MaiApplication).repository.terminals.termuxResult(id, message)
    }
}

private fun java.io.BufferedReader.readBoundedLine(limit: Int): String? {
    val line = StringBuilder()
    while (true) {
        val ch = read()
        if (ch == -1) return if (line.isEmpty()) null else line.toString()
        if (ch == 10) return line.toString()
        check(line.length < limit) { "Terminal message too large" }
        line.append(ch.toChar())
    }
}
