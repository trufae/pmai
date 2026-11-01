@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.mai.kotlin

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.webkit.*
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.mai.kotlin.generated.MaiKotlinBridge
import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest

internal data class XdcApp(val id: String, val name: String, val description: String)

internal class XdcLibrary(private val context: Context) {
    private val root = context.filesDir.resolve("webxdc").apply { mkdirs() }
    fun directory(id: String): File {
        require(id.matches(Regex("[a-f0-9]{40}"))) { "Invalid app ID" }
        return root.resolve(id)
    }
    fun app(id: String): XdcApp {
        val metadata = JSONObject(directory(id).resolve("metadata.json").readText())
        return XdcApp(id, metadata.getString("name"), metadata.optString("description"))
    }
    fun apps(): List<XdcApp> = root.listFiles().orEmpty().filter { it.name.matches(Regex("[a-f0-9]{40}")) }
        .map { app(it.name) }.sortedBy { it.name.lowercase() }
    fun import(uri: Uri): XdcApp {
        val archive = context.cacheDir.resolve("webxdc-${java.util.UUID.randomUUID()}.xdc")
        try {
            requireNotNull(context.contentResolver.openInputStream(uri)) { "Cannot open archive" }.use { input ->
                archive.outputStream().use { output ->
                    val buffer = ByteArray(16 * 1024); var size = 0
                    while (true) {
                        val n = input.read(buffer); if (n == -1) break
                        size += n; require(size <= XdcArchive.maxTotalBytes) { "Archive is too large" }
                        output.write(buffer, 0, n)
                    }
                }
            }
            val digest = MessageDigest.getInstance("SHA-256")
            archive.inputStream().use { stream ->
                val buffer = ByteArray(16 * 1024)
                while (true) { val n = stream.read(buffer); if (n == -1) break; digest.update(buffer, 0, n) }
            }
            val id = digest.digest().take(20).joinToString("") { "%02x".format(it) }
            if (directory(id).exists()) return app(id)
            val staging = root.resolve("import-${java.util.UUID.randomUUID()}")
            try {
                archive.inputStream().use { XdcArchive.extract(it, staging.resolve("content")) }
                val manifest = staging.resolve("content/manifest.toml").takeIf { it.isFile }?.readText().orEmpty()
                fun field(name: String) = Regex("(?m)^\\s*$name\\s*=\\s*\"([^\"]*)\"").find(manifest)?.groupValues?.get(1)
                val metadata = JSONObject().put("name", field("name") ?: "WebXDC app").put("description", field("description").orEmpty())
                staging.resolve("metadata.json").writeText(metadata.toString())
                check(staging.renameTo(directory(id))) { "Cannot save imported app" }
            } finally { staging.deleteRecursively() }
            return app(id)
        } finally { archive.delete() }
    }
    fun remove(id: String) { check(directory(id).deleteRecursively()) { "Cannot remove app" } }
}

@Composable fun WebXdcLibrary(state: AppState, model: MaiViewModel, onOpen: (String) -> Unit) {
    val context = LocalContext.current
    val library = remember { XdcLibrary(context) }
    var apps by remember { mutableStateOf(emptyList<XdcApp>()) }
    var error by remember { mutableStateOf("") }
    var importing by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<XdcApp?>(null) }
    var browsing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        try { apps = withContext(Dispatchers.IO) { library.apps() } }
        catch (e: Exception) { error = e.localizedMessage.orEmpty() }
    }
    LaunchedEffect(state.remote.downloadPath) {
        if (state.remote.downloadPath.isNotEmpty()) {
            importing = true
            try {
                val app = withContext(Dispatchers.IO) { library.import(Uri.fromFile(File(state.remote.downloadPath))) }
                apps = withContext(Dispatchers.IO) { library.apps() }
                browsing = false
                onOpen(app.id)
            } catch (e: Exception) { error = e.localizedMessage.orEmpty() }
            finally { importing = false; model.command("consumeDownload") }
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            importing = true
            try {
                val app = withContext(Dispatchers.IO) { library.import(uri) }
                apps = withContext(Dispatchers.IO) { library.apps() }
                onOpen(app.id)
            } catch (e: Exception) { error = e.localizedMessage.orEmpty() }
            finally { importing = false }
        }
    }
    Scaffold(topBar = { TopAppBar(title = { Text("Apps") }) }, floatingActionButton = {
        ExtendedFloatingActionButton(onClick = { picker.launch(arrayOf("*/*")) }, icon = { Icon(Icons.Outlined.FileOpen, null) }, text = { Text("Import .xdc") })
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 100.dp)) {
            item { Text("Small apps, right here", Modifier.padding(20.dp), style = MaterialTheme.typography.headlineSmall) }
            item { Text("Open WebXDC apps with their own saved state. Each app has separate storage and permissions.", Modifier.padding(horizontal = 20.dp), style = MaterialTheme.typography.bodyMedium) }
            if (state.isRemote) item { OutlinedButton(onClick = { browsing = true },
                modifier = Modifier.padding(20.dp), enabled = !state.remote.busy) { Icon(Icons.Outlined.Dns, null); Spacer(Modifier.width(8.dp)); Text("Import from remote host") } }
            if (importing) item { LinearProgressIndicator(Modifier.fillMaxWidth().padding(20.dp)) }
            if (error.isNotEmpty()) item { Text(error, Modifier.padding(20.dp), color = MaterialTheme.colorScheme.error) }
            if (apps.isEmpty()) item { EmptyState(Icons.Outlined.Widgets, "Bring an app", "Import a .xdc file from Files or a download. Your app stays available offline.") }
            items(apps, key = { it.id }) { app ->
                ListItem(headlineContent = { Text(app.name) }, supportingContent = { Text(app.description) },
                    leadingContent = { Icon(Icons.Outlined.Widgets, null) }, modifier = Modifier.clickable { onOpen(app.id) },
                    trailingContent = { IconButton(onClick = { removing = app }) { Icon(Icons.Outlined.DeleteOutline, "Remove ${app.name}") } })
            }
        }
    }
    if (browsing) androidx.compose.ui.window.Dialog(onDismissRequest = { browsing = false },
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        RemoteWorkspaceScreen(state.remote, model, archivesOnly = true, onClose = { browsing = false })
    }
    removing?.let { app -> AlertDialog(onDismissRequest = { removing = null }, title = { Text("Remove ${app.name}?") },
        text = { Text("Its saved status updates and permissions will also be deleted.") },
        confirmButton = { TextButton(onClick = { scope.launch {
            try { withContext(Dispatchers.IO) { library.remove(app.id) }; apps = withContext(Dispatchers.IO) { library.apps() } }
            catch (e: Exception) { error = e.localizedMessage.orEmpty() }
            removing = null
        } }) { Text("Remove") } }, dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } }) }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable fun WebXdcRunner(id: String, state: AppState, model: MaiViewModel, onClose: () -> Unit) {
    val context = LocalContext.current
    val library = remember { XdcLibrary(context) }
    val app = remember(id) { library.app(id) }
    val directory = remember(id) { library.directory(id) }
    val prefs = remember(id) { context.getSharedPreferences("xdc-$id", Context.MODE_PRIVATE) }
    var inference by remember(id) { mutableStateOf(prefs.getBoolean("inference", false)) }
    var internet by remember(id) { mutableStateOf(prefs.getBoolean("internet", false)) }
    var chatBridge by remember(id) { mutableStateOf(prefs.getBoolean("chat", false)) }
    var permissions by remember { mutableStateOf(false) }
    var requestedPermission by remember { mutableStateOf<JSONObject?>(null) }
    var draftToChat by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    val latestModel by rememberUpdatedState(model)
    val host = "$id.webxdc.local"
    val origin = "https://$host"
    val supported = remember { WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER) && WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT) }
    val pending = remember(id, internet) { mutableSetOf<String>() }
    var webView by remember { mutableStateOf<WebView?>(null) }
    val updatesFile = remember { directory.resolve("updates.json") }
    fun updates(): JSONArray = if (updatesFile.exists()) JSONArray(updatesFile.readText()) else JSONArray()
    fun js(function: String, argument: Any) {
        webView?.evaluateJavascript("window.$function && window.$function($argument)", null)
    }
    fun reply(request: JSONObject, result: Any? = null, code: String? = null, message: String = "") {
        val reply = JSONObject().put("id", request.optString("id"))
        if (code == null) reply.put("result", result ?: JSONObject.NULL)
        else reply.put("error", JSONObject().put("code", code).put("message", message))
        js("__pocketmaiReply", reply)
    }
    fun capabilities() = JSONObject().put("host", "pocketmai").put("version", 1)
        .put("permissions", JSONObject().put("inference", inference).put("synthesis", false).put("transcription", false))
        .put("features", JSONObject().put("streaming", true).put("cancellation", true).put("providerAPIs", true).put("chat", false).put("tools", false).put("microphone", false))
    Scaffold(topBar = { TopAppBar(title = { Text(app.name) }, navigationIcon = {
        IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Close app") }
    }, actions = {
        IconButton(onClick = { permissions = true }) { Icon(Icons.Outlined.Security, "App permissions") }
        IconButton(onClick = { webView?.reload() }) { Icon(Icons.Outlined.Refresh, "Reload app") }
    }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (error.isNotEmpty()) Text(error, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error)
            if (!supported) EmptyState(Icons.Outlined.Update, "Update Android System WebView", "This app needs document-start scripts and origin-scoped messaging to run WebXDC securely.")
            else key(id, internet) {
                AndroidView(modifier = Modifier.fillMaxSize(), factory = {
                    val loader = WebViewAssetLoader.Builder().setDomain(host)
                        .addPathHandler("/", WebViewAssetLoader.InternalStoragePathHandler(context, directory.resolve("content"))).build()
                    WebView(it).apply {
                        webView = this
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.allowFileAccess = false
                        settings.allowContentAccess = false
                        settings.javaScriptCanOpenWindowsAutomatically = false
                        settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                        settings.setSupportMultipleWindows(false)
                        settings.mediaPlaybackRequiresUserGesture = true
                        settings.blockNetworkLoads = !internet
                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
                        webChromeClient = object : WebChromeClient() {
                            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
                            override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) { callback.invoke(origin, false, false) }
                        }
                        webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                                request.url.scheme != "https" || request.url.host != host
                            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                                if (request.url.scheme == "https" && request.url.host == host) {
                                    if (request.url.path == "/webxdc.js") return WebResourceResponse("text/javascript", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                                    return loader.shouldInterceptRequest(request.url)?.apply {
                                        val remoteSources = if (internet) " https: wss:" else ""
                                        responseHeaders = responseHeaders.orEmpty() + mapOf(
                                            "Content-Security-Policy" to "default-src 'self' data: blob:$remoteSources; script-src 'self' 'unsafe-inline' 'unsafe-eval'$remoteSources; connect-src 'self'$remoteSources; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'self'",
                                            "Permissions-Policy" to "camera=(), microphone=(), geolocation=()")
                                    } ?: blocked()
                                }
                                return if (internet && request.url.scheme == "https") null else blocked()
                            }
                            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: android.net.http.SslError) { handler.cancel() }
                        }
                        WebViewCompat.addWebMessageListener(this, "PocketMaiHost", setOf(origin)) { _, message, source, mainFrame, _ ->
                            if (!mainFrame || source.toString().trimEnd('/') != origin) return@addWebMessageListener
                            try {
                                val body = JSONObject(message.data ?: return@addWebMessageListener)
                                when (body.optString("type")) {
                                    "ready" -> {
                                        val serial = body.optInt("serial")
                                        val all = updates(); val newer = JSONArray()
                                        for (i in 0 until all.length()) if (all.getJSONObject(i).getInt("serial") > serial) newer.put(all.getJSONObject(i))
                                        js("__webxdcDeliver", newer)
                                    }
                                    "sendUpdate" -> {
                                        val all = updates()
                                        require(all.length() < 10000 && updatesFile.length() < 8_000_000) { "App status update storage is full" }
                                        val payload = body.optString("payload", "null")
                                        require(payload.toByteArray().size <= 64000) { "Status update is too large" }
                                        val entry = JSONObject().put("serial", all.length() + 1).put("payloadJSON", payload)
                                        listOf("info", "document", "summary").forEach { key -> if (!body.isNull(key)) entry.put(key, body.getString(key).take(4096)) }
                                        all.put(entry)
                                        val temporary = directory.resolve("updates.tmp")
                                        temporary.writeText(all.toString()); check(temporary.renameTo(updatesFile)) { "Cannot save status update" }
                                        js("__webxdcDeliver", JSONArray().put(entry))
                                    }
                                    "sendToChat" -> if (chatBridge) draftToChat = body.optString("text").take(256000)
                                    "pocketmai" -> {
                                        val method = body.optString("method")
                                        when {
                                            method == "capabilities" -> reply(body, capabilities())
                                            method == "requestPermissions" -> {
                                                val requested = body.optJSONObject("options")?.optJSONArray("capabilities") ?: JSONArray()
                                                if (requested.length() !in 1..3 || (0 until requested.length()).any { requested.getString(it) != "inference" }) reply(body, code = "NotSupportedError", message = "This Android version supports inference; speech APIs are not implemented yet.")
                                                else if (inference) reply(body, capabilities()) else requestedPermission = body
                                            }
                                            method in listOf("providers", "models", "complete", "cancel") -> {
                                                val requestID = body.optString("id")
                                                if (method == "cancel" && requestID !in pending) return@addWebMessageListener
                                                if (!inference && method != "cancel") { reply(body, code = "NotAllowedError", message = "Allow inference in App permissions first."); return@addWebMessageListener }
                                                if (method != "cancel") pending.add(requestID)
                                                MaiKotlinBridge.maiWebRequest(body.toString()) { response -> post {
                                                    if (requestID in pending) {
                                                        val json = JSONObject(response)
                                                        if (!json.has("event")) pending.remove(requestID)
                                                        js("__pocketmaiReply", json)
                                                    }
                                                } }
                                            }
                                            else -> reply(body, code = "NotSupportedError", message = "This PocketMai API is not available on Android yet.")
                                        }
                                    }
                                }
                            } catch (e: Exception) { error = e.localizedMessage.orEmpty() }
                        }
                        val bootstrap = context.assets.open("webxdc.js").bufferedReader().use { it.readText() }
                        val sdk = context.assets.open("pocketmai.js").bufferedReader().use { it.readText() }
                        WebViewCompat.addDocumentStartJavaScript(this, bootstrap + "\n" + sdk, setOf(origin))
                        loadUrl("$origin/index.html")
                    }
                }, onRelease = { view ->
                    pending.toList().forEach { requestID -> MaiKotlinBridge.maiWebRequest(JSONObject().put("id", requestID).put("method", "cancel").toString()) { _ -> } }
                    pending.clear()
                    view.stopLoading(); view.removeAllViews(); view.destroy()
                    if (webView === view) webView = null
                })
            }
        }
    }
    if (permissions) AlertDialog(onDismissRequest = { permissions = false }, title = { Text("${app.name} permissions") },
        text = { Column {
            PermissionSwitch("Inference", "Use your configured provider and model", inference) { allowed ->
                inference = allowed; prefs.edit().putBoolean("inference", allowed).apply()
                if (!allowed) {
                    pending.toList().forEach { requestID ->
                        js("__pocketmaiReply", JSONObject().put("id", requestID).put("error", JSONObject().put("code", "AbortError").put("message", "Inference permission was revoked.")))
                        MaiKotlinBridge.maiWebRequest(JSONObject().put("id", requestID).put("method", "cancel").toString()) { _ -> }
                    }
                    pending.clear()
                }
            }
            PermissionSwitch("Internet", "Allow HTTPS requests to other services", internet) { internet = it; prefs.edit().putBoolean("internet", it).apply() }
            PermissionSwitch("Chat bridge", "Let the app propose text for your composer", chatBridge) { chatBridge = it; prefs.edit().putBoolean("chat", it).apply() }
            Text("Changing internet access restarts this app. Camera, microphone and location access are disabled.", style = MaterialTheme.typography.bodySmall)
        } }, confirmButton = { TextButton(onClick = { permissions = false }) { Text("Done") } })
    requestedPermission?.let { request -> AlertDialog(onDismissRequest = { reply(request, code = "NotAllowedError", message = "Permission denied"); requestedPermission = null },
        title = { Text("Allow ${app.name} to use inference?") }, text = { Text("It can send its input to your configured provider. Your API key stays in the native engine.") },
        confirmButton = { TextButton(onClick = {
            // Grant without restarting before the permission response is delivered.
            prefs.edit().putBoolean("inference", true).apply()
            inference = true
            reply(request, capabilities().put("permissions", JSONObject().put("inference", true).put("transcription", false).put("synthesis", false)))
            requestedPermission = null
        }) { Text("Allow") } }, dismissButton = { TextButton(onClick = { reply(request, code = "NotAllowedError", message = "Permission denied"); requestedPermission = null }) { Text("Deny") } }) }
    if (draftToChat.isNotEmpty()) AlertDialog(onDismissRequest = { draftToChat = "" }, title = { Text("Add this to your chat?") },
        text = { Text(draftToChat.take(2000)) }, confirmButton = { TextButton(onClick = { latestModel.draft(draftToChat); draftToChat = ""; onClose() }) { Text("Add to composer") } },
        dismissButton = { TextButton(onClick = { draftToChat = "" }) { Text("Cancel") } })
}

private fun blocked() = WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
@Composable private fun PermissionSwitch(title: String, description: String, checked: Boolean, change: (Boolean) -> Unit) {
    ListItem(headlineContent = { Text(title) }, supportingContent = { Text(description) }, trailingContent = { Switch(checked, change) })
}
