package org.mai.kotlin

import android.app.Application
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import org.mai.kotlin.generated.MaiKotlinBridge

data class Message(val id: String, val role: String, val text: String, val status: String = "", val attachments: List<Attachment> = emptyList(), val remoteID: String = "")
data class ChatSummary(val id: String, val title: String, val subtitle: String, val updated: Long, val cwd: String = "", val folderID: String = "unfiled")
data class ProviderInfo(val id: String, val name: String, val baseURL: String, val apiKey: String, val model: String)
data class ChatFolder(val id: String, val name: String)
data class ToolGroupInfo(val id: String, val name: String, val description: String, val enabled: Boolean, val tools: List<String>)
data class Prompt(val id: String, val name: String, val text: String)
data class Host(val id: String, val name: String, val address: String, val pinned: Boolean, val connected: Boolean)
data class Folder(val cwd: String, val name: String)
data class RemoteFile(val path: String, val name: String, val directory: Boolean)
data class AgentToolInfo(val name: String, val description: String, val enabled: Boolean)
data class SkillInfo(val name: String, val description: String, val body: String, val toolName: String, val enabled: Boolean)
data class McpInfo(val id: String, val name: String, val url: String, val enabled: Boolean, val hasToken: Boolean)
data class LocalApproval(val id: String, val name: String, val description: String, val arguments: String)
data class AgentState(val enabled: Boolean = false, val loading: Boolean = false, val error: String = "",
    val tools: List<AgentToolInfo> = emptyList(), val servers: List<McpInfo> = emptyList(),
    val skills: List<SkillInfo> = emptyList(), val activity: List<Message> = emptyList(), val approvals: List<LocalApproval> = emptyList(), val groups: List<ToolGroupInfo> = emptyList())
data class RemoteState(
    val hostID: String = "", val folder: String = "", val conversationID: String = "",
    val connected: Boolean = false, val busy: Boolean = false, val status: String = "",
    val error: String = "", val hosts: List<Host> = emptyList(), val folders: List<Folder> = emptyList(),
    val sessions: List<ChatSummary> = emptyList(), val messages: List<Message> = emptyList(),
    val permission: JSONObject? = null,
    val browserPath: String = ".", val downloadPath: String = "", val files: List<RemoteFile> = emptyList(),
    val options: List<JSONObject> = emptyList(),
    val canRewind: Boolean = false,
)
data class AppState(
    val ready: Boolean = false, val error: String = "", val baseURL: String = "",
    val apiKey: String = "", val model: String = "", val chatID: String = "",
    val title: String = "New chat", val generating: Boolean = false, val loadingModels: Boolean = false,
    val streamed: String = "", val reasoning: String = "", val status: String = "",
    val selectedPromptID: String = "", val models: List<String> = emptyList(),
    val prompts: List<Prompt> = emptyList(), val messages: List<Message> = emptyList(),
    val chats: List<ChatSummary> = emptyList(), val remote: RemoteState = RemoteState(),
    val agent: AgentState = AgentState(),
    val providers: List<ProviderInfo> = emptyList(), val selectedProviderID: String = "",
    val folders: List<ChatFolder> = emptyList(), val folderID: String = "all",
) {
    val isRemote get() = remote.hostID.isNotEmpty()
    val busy get() = if (isRemote) remote.busy else generating || loadingModels
    val activeMessages get() = if (isRemote) remote.messages else messages
    val activeTitle get() = if (isRemote) remote.sessions.firstOrNull { it.id == remote.conversationID }?.title ?: "Remote chat" else title

    companion object {
        fun decode(json: String): AppState {
            val j = JSONObject(json)
            val r = j.optJSONObject("remote") ?: JSONObject()
            val a = j.optJSONObject("agent") ?: JSONObject()
            val organization = j.optJSONObject("organization") ?: JSONObject()
            fun messages(a: JSONArray?) = a.objects().map {
                Message(it.getString("id"), it.getString("role"), it.getString("text"), it.optString("status"),
                    it.optJSONArray("attachments").objects().map { attachment -> Attachment(attachment.optString("path"), attachment.getString("name"), attachment.getString("mime")) }, it.optString("remoteID"))
            }
            return AppState(
                ready = j.optBoolean("ready"), error = j.optString("error"),
                baseURL = j.optString("baseURL"), apiKey = j.optString("apiKey"), model = j.optString("model"),
                chatID = j.optString("chatID"), title = j.optString("title", "New chat"),
                generating = j.optBoolean("isGenerating"), loadingModels = j.optBoolean("isLoadingModels"),
                streamed = j.optString("streamedText"), reasoning = j.optString("streamedReasoning"),
                status = j.optString("status"), selectedPromptID = j.optString("selectedPromptID"),
                models = j.optJSONArray("models").objects().map { it.getString("id") },
                prompts = j.optJSONArray("prompts").objects().map { Prompt(it.getString("id"), it.getString("name"), it.getString("text")) },
                messages = messages(j.optJSONArray("messages")),
                chats = j.optJSONArray("chats").objects().map {
                    ChatSummary(it.getString("id"), it.getString("title"), it.optString("model"), (it.optDouble("updatedAt") * 1000).toLong(), folderID = it.optString("folderID", "unfiled"))
                },
                remote = RemoteState(
                    hostID = r.optString("selectedHostID"), folder = r.optString("selectedFolder"), conversationID = r.optString("conversationID"),
                    connected = r.optBoolean("connected"), busy = r.optBoolean("busy"), status = r.optString("status"), error = r.optString("error"),
                    hosts = r.optJSONArray("hosts").objects().map { Host(it.getString("id"), it.getString("name"), it.getString("address"), it.getBoolean("pinned"), it.getBoolean("connected")) },
                    folders = r.optJSONArray("folders").objects().map { Folder(it.getString("cwd"), it.getString("name")) },
                    sessions = r.optJSONArray("sessions").objects().map { ChatSummary(it.getString("id"), it.getString("title"), it.getString("cwd"), (it.optDouble("updatedAt") * 1000).toLong(), it.getString("cwd")) },
                    messages = messages(r.optJSONArray("messages")), permission = r.optJSONObject("permission"),
                    browserPath = r.optString("browserPath", "."), downloadPath = r.optString("downloadPath"),
                    files = r.optJSONArray("files").objects().map { RemoteFile(it.getString("path"), it.getString("name"), it.getBoolean("directory")) },
                    options = r.optJSONArray("options").objects(),
                    canRewind = r.optBoolean("canRewind"),
                ),
                agent = AgentState(enabled = a.optBoolean("enabled"), loading = a.optBoolean("loading"), error = a.optString("error"),
                    tools = a.optJSONArray("tools").objects().map { AgentToolInfo(it.getString("name"), it.getString("description"), it.getBoolean("enabled")) },
                    servers = a.optJSONArray("servers").objects().map { McpInfo(it.getString("id"), it.getString("name"), it.getString("url"), it.getBoolean("enabled"), it.getBoolean("hasToken")) },
                    skills = a.optJSONArray("skills").objects().map { SkillInfo(it.getString("name"), it.getString("description"), it.getString("body"), it.getString("toolName"), it.getBoolean("enabled")) },
                    activity = a.optJSONArray("activity").objects().map { Message(it.getString("id"), "tool", it.getString("name") + "\n" + it.getString("text"), it.getString("state")) },
                    approvals = a.optJSONArray("approvals").objects().map { LocalApproval(it.getString("id"), it.getString("name"), it.getString("description"), it.getString("arguments")) },
                    groups = a.optJSONArray("groups").objects().map { group -> ToolGroupInfo(group.getString("id"), group.getString("name"), group.getString("description"), group.getBoolean("enabled"),
                        group.getJSONArray("tools").let { names -> (0 until names.length()).map { names.getString(it) } }) }),
                providers = j.optJSONArray("providers").objects().map { ProviderInfo(it.getString("id"), it.getString("name"), it.getString("baseURL"), it.getString("apiKey"), it.getString("model")) },
                selectedProviderID = j.optString("selectedProviderID"), folderID = organization.optString("selected", "all"),
                folders = organization.optJSONArray("folders").objects().map { ChatFolder(it.getString("id"), it.getString("name")) },
            )
        }
    }
}

internal fun JSONArray?.objects(): List<JSONObject> =
    if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }

class MaiApplication : Application() {
    lateinit var repository: MaiRepository
        private set
    override fun onCreate() {
        super.onCreate()
        repository = MaiRepository(this)
    }
}

/** Process-owned: rotating an Activity never loses or restarts a Swift request. */
class MaiRepository(application: Application) {
    private val mutableState = MutableStateFlow(AppState())
    val state = mutableState.asStateFlow()
    private val main = Handler(Looper.getMainLooper())
    init {
        try {
            System.loadLibrary("SwiftJava")
            System.loadLibrary("MaiKotlinBridge")
            val identity = ForwirohIdentity.load(application)
            MaiKotlinBridge.maiStart(application, application.filesDir.resolve("pocketmai").path, identity) { json ->
                main.post {
                    try { mutableState.value = AppState.decode(json) }
                    catch (error: Exception) { mutableState.value = AppState(error = "Cannot read application state: ${error.localizedMessage}") }
                }
            }
        } catch (error: Exception) {
            mutableState.value = AppState(error = "Could not open saved data: ${error.localizedMessage}")
        } catch (error: UnsatisfiedLinkError) {
            mutableState.value = AppState(error = "Native library could not load: ${error.localizedMessage}")
        }
    }
    fun execute(action: String, vararg fields: Pair<String, String>) {
        if (!state.value.ready) return
        val command = JSONObject().put("action", action)
        fields.forEach { (key, value) -> command.put(key, value) }
        MaiKotlinBridge.maiExecute(command.toString())
    }
}

class MaiViewModel(application: Application, private val saved: SavedStateHandle) : AndroidViewModel(application) {
    private val repository = (application as MaiApplication).repository
    val state = repository.state
    val draft = saved.getStateFlow("draft", "")
    private val mutableAttachments = MutableStateFlow(Attachment.decode(saved.get<String>("attachments") ?: "[]"))
    val attachments = mutableAttachments.asStateFlow()
    private data class PendingSend(val text: String, val previousUser: String?, val attachments: List<Attachment>, val remote: Boolean)
    private var pending: PendingSend? = null
    init { viewModelScope.launch { state.collect { current ->
        val sent = pending ?: return@collect
        val user = (if (sent.remote) current.remote.messages else current.messages).lastOrNull { it.role == "user" }?.id
        if (user != null && user != sent.previousUser) {
            if (draft.value == sent.text) draft("")
            sent.attachments.forEach { java.io.File(it.path).delete() }
            setAttachments(mutableAttachments.value.filter { item -> sent.attachments.none { it.path == item.path } })
            pending = null
        } else if (!current.busy && current.error.isNotEmpty()) { pending = null }
    } } }
    fun draft(value: String) { saved["draft"] = value }
    fun command(action: String, vararg fields: Pair<String, String>) = repository.execute(action, *fields)
    private fun setAttachments(items: List<Attachment>) { mutableAttachments.value = items; saved["attachments"] = Attachment.encode(items) }
    fun addAttachments(items: List<Attachment>) {
        require(mutableAttachments.value.size + items.size <= 12) { "Attach at most 12 items per message." }
        setAttachments(mutableAttachments.value + items)
    }
    fun removeAttachment(item: Attachment) { java.io.File(item.path).delete(); setAttachments(mutableAttachments.value.filter { it.path != item.path }) }
    fun send() {
        val current = state.value
        val text = draft.value
        if (!current.ready || current.busy || (text.isBlank() && attachments.value.isEmpty())) return
        if (current.isRemote && (!current.remote.connected || current.remote.conversationID.isEmpty())) return
        if (!current.isRemote && current.model.isBlank()) return
        pending = PendingSend(text, current.activeMessages.lastOrNull { it.role == "user" }?.id, attachments.value, current.isRemote)
        command(if (current.isRemote) "remoteSend" else "send", "text" to text, "attachments" to Attachment.encode(attachments.value))
    }
}
