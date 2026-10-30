@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.mai.kotlin

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.json.JSONObject

@Composable internal fun AgentSettings(state: AppState, model: MaiViewModel, section: String, modifier: Modifier) {
    var query by rememberSaveable(section) { mutableStateOf("") }
    var addingMcp by remember { mutableStateOf(false) }
    var editingMcp by remember { mutableStateOf<McpInfo?>(null) }
    var addingSkill by remember { mutableStateOf(false) }
    var editingSkill by remember { mutableStateOf<SkillInfo?>(null) }
    var removeMcp by remember { mutableStateOf<McpInfo?>(null) }
    var removeSkill by remember { mutableStateOf<SkillInfo?>(null) }
    val editable = !state.generating
    LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (section != "Remote") item {
            Text("On this device", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            if (state.isRemote) Text("These settings apply to local chats. The Remote tab controls the connected host.", style = MaterialTheme.typography.bodySmall)
        }
        when (section) {
            "Tools" -> {
                item { Text("Give your assistant tools", style = MaterialTheme.typography.headlineSmall) }
                item { ListItem(headlineContent = { Text("Enable tools, MCP and skills") },
                    supportingContent = { Text("Tool calls ask for approval. File tools use the app’s private workspace.") },
                    trailingContent = { Switch(state.agent.enabled, { model.command("toolsEnabled", "enabled" to it.toString()) }, enabled = editable) }) }
                item { OutlinedTextField(query, { query = it }, label = { Text("Find a tool") }, leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true, modifier = Modifier.fillMaxWidth()) }
                if (state.agent.loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                items(state.agent.groups.filter { group -> group.name.contains(query, true) || group.tools.any { name -> name.contains(query, true) } }, key = { it.id }) { group ->
                    var expanded by rememberSaveable(group.id) { mutableStateOf(false) }
                    val tools = state.agent.tools.filter { it.name in group.tools }
                    ElevatedCard(Modifier.fillMaxWidth()) {
                        ListItem(headlineContent = { Text(group.name) }, supportingContent = { Text("${tools.count { it.enabled }} of ${tools.size} tools selected") },
                            leadingContent = { Icon(if (expanded || query.isNotBlank()) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, if (expanded) "Collapse group" else "Expand group") },
                            modifier = Modifier.clickable { expanded = !expanded },
                            trailingContent = { Switch(group.enabled, { model.command("groupEnabled", "id" to group.id, "enabled" to it.toString()) }, enabled = editable) })
                        if (expanded || query.isNotBlank()) {
                            Text(group.description, Modifier.padding(horizontal = 20.dp, vertical = 8.dp), style = MaterialTheme.typography.bodySmall)
                            tools.filter { query.isBlank() || group.name.contains(query, true) || it.name.contains(query, true) }.forEach { tool ->
                                ListItem(headlineContent = { Text(tool.name) }, supportingContent = { Text(tool.description, maxLines = 3, overflow = TextOverflow.Ellipsis) },
                                    trailingContent = { Switch(tool.enabled, { model.command("toolEnabled", "name" to tool.name, "enabled" to it.toString()) }, enabled = editable && group.enabled) })
                            }
                        }
                    }
                }
            }
            "MCP" -> {
                item { Text("Connect more capabilities", style = MaterialTheme.typography.headlineSmall) }
                item { Text("Add Streamable HTTP MCP servers. MaiCore discovers their tools and handles the protocol; tool calls use the same approval flow as built-in tools.") }
                item { Button(onClick = { addingMcp = true }, enabled = editable) { Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp)); Text("Add MCP server") } }
                if (!state.agent.enabled) item { Text("Enable tools in the Tools tab to use MCP servers in chat.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(state.agent.servers, key = { it.id }) { server ->
                    ElevatedCard(Modifier.fillMaxWidth()) {
                        ListItem(headlineContent = { Text(server.name) }, supportingContent = { Text(server.url) },
                            trailingContent = { Switch(server.enabled, { model.command("mcpEnabled", "id" to server.id, "enabled" to it.toString()) }, enabled = editable) })
                        Row(Modifier.padding(horizontal = 12.dp)) {
                            TextButton(onClick = { editingMcp = server }, enabled = editable) { Text("Edit") }
                            TextButton(onClick = { removeMcp = server }, enabled = editable) { Text("Remove") }
                        }
                    }
                }
                if (state.agent.servers.isEmpty()) item { EmptyState(Icons.Outlined.Extension, "No servers yet", "Connect an MCP service to make its tools available to your local assistant.") }
            }
            "Skills" -> {
                item { Text("Teach a repeatable workflow", style = MaterialTheme.typography.headlineSmall) }
                item { Text("Skills use the same SKILL.md format as pmai and iOS. Enabled skills are exposed as tools, and you approve their use in chat.") }
                item { Button(onClick = { addingSkill = true }, enabled = editable) { Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp)); Text("Add skill") } }
                if (!state.agent.enabled) item { Text("Enable tools in the Tools tab to use skills in chat.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(state.agent.skills, key = { it.name }) { skill ->
                    ElevatedCard(Modifier.fillMaxWidth()) {
                        ListItem(headlineContent = { Text(skill.name) }, supportingContent = { Text(skill.description) },
                            trailingContent = { Switch(skill.enabled, { model.command("toolEnabled", "name" to skill.toolName, "enabled" to it.toString()) }, enabled = editable) })
                        Row(Modifier.padding(horizontal = 12.dp)) {
                            TextButton(onClick = { editingSkill = skill }, enabled = editable) { Text("Edit") }
                            TextButton(onClick = { removeSkill = skill }, enabled = editable) { Text("Remove") }
                        }
                    }
                }
                if (state.agent.skills.isEmpty()) item { EmptyState(Icons.Outlined.AutoAwesome, "Build your own playbook", "Add instructions for a task you repeat, with a description of when the assistant should use them.") }
            }
            "Remote" -> {
                item { Text("Remote chat settings", style = MaterialTheme.typography.headlineSmall) }
                item { Text("These options come from the connected host. Its tools, skills and MCP services run there; permission requests appear on this device.") }
                if (state.remote.options.isEmpty()) item { EmptyState(Icons.Outlined.Tune, "Open a remote chat", "Connect to a saved conversation to load the host’s available models and tool settings.") }
                items(state.remote.options, key = { it.getString("id") }) { option ->
                    val id = option.getString("id")
                    if (option.getString("type") == "boolean") ListItem(headlineContent = { Text(option.getString("name")) },
                        supportingContent = { Text(option.optString("description")) },
                        trailingContent = { Switch(option.getBoolean("currentValue"), { model.command("remoteOption", "id" to id, "value" to it.toString()) }, enabled = !state.remote.busy) })
                    else {
                        var menu by remember { mutableStateOf(false) }
                        val choices = option.optJSONArray("options").objects()
                        val current = option.getString("currentValue")
                        ListItem(headlineContent = { Text(option.getString("name")) }, supportingContent = {
                            Text(choices.firstOrNull { it.getString("value") == current }?.getString("name") ?: current)
                        }, trailingContent = { Box {
                            IconButton(onClick = { menu = true }, enabled = !state.remote.busy) { Icon(Icons.Outlined.ArrowDropDown, "Choose ${option.getString("name")}") }
                            DropdownMenu(menu, { menu = false }) { choices.forEach { choice ->
                                DropdownMenuItem(text = { Text(choice.getString("name")) }, onClick = {
                                    menu = false; model.command("remoteOption", "id" to id, "value" to JSONObject.quote(choice.getString("value")))
                                })
                            } }
                        } })
                    }
                }
            }
        }
    }
    if (addingMcp || editingMcp != null) {
        var name by remember(editingMcp?.id) { mutableStateOf(editingMcp?.name.orEmpty()) }
        var url by remember(editingMcp?.id) { mutableStateOf(editingMcp?.url.orEmpty()) }
        var token by remember { mutableStateOf("") }
        ModalBottomSheet(onDismissRequest = { addingMcp = false; editingMcp = null }) {
            Column(Modifier.fillMaxWidth().imePadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(if (addingMcp) "Add MCP server" else "Edit MCP server", style = MaterialTheme.typography.headlineSmall)
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(url, { url = it }, label = { Text("MCP endpoint URL") }, placeholder = { Text("https://example.com/mcp") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(token, { token = it }, label = { Text(if (editingMcp?.hasToken == true) "New bearer token (blank keeps current)" else "Bearer token (optional)") },
                    visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
                Button(onClick = { model.command("saveMcp", "id" to editingMcp?.id.orEmpty(), "name" to name, "url" to url.trim(), "token" to token); addingMcp = false; editingMcp = null },
                    enabled = name.isNotBlank() && (url.startsWith("https://") || url.startsWith("http://")), modifier = Modifier.fillMaxWidth()) { Text("Save server") }
            }
        }
    }
    if (addingSkill || editingSkill != null) {
        var name by remember(editingSkill?.name) { mutableStateOf(editingSkill?.name.orEmpty()) }
        var description by remember(editingSkill?.name) { mutableStateOf(editingSkill?.description.orEmpty()) }
        var body by remember(editingSkill?.name) { mutableStateOf(editingSkill?.body.orEmpty()) }
        ModalBottomSheet(onDismissRequest = { addingSkill = false; editingSkill = null }) {
            Column(Modifier.fillMaxWidth().imePadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(if (addingSkill) "Add skill" else "Edit skill", style = MaterialTheme.typography.headlineSmall)
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, readOnly = editingSkill != null, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(description, { description = it }, label = { Text("When to use it") }, minLines = 2, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(body, { body = it }, label = { Text("Instructions") }, minLines = 6, maxLines = 15, modifier = Modifier.fillMaxWidth())
                Button(onClick = { model.command("saveSkill", "name" to name.trim(), "description" to description, "body" to body); addingSkill = false; editingSkill = null },
                    enabled = name.isNotBlank() && description.isNotBlank() && body.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text("Save skill") }
            }
        }
    }
    removeMcp?.let { server -> ConfirmRemoval(server.name, { removeMcp = null }) { model.command("removeMcp", "id" to server.id); removeMcp = null } }
    removeSkill?.let { skill -> ConfirmRemoval(skill.name, { removeSkill = null }) { model.command("removeSkill", "name" to skill.name); removeSkill = null } }
}

@Composable private fun ConfirmRemoval(name: String, dismiss: () -> Unit, remove: () -> Unit) {
    AlertDialog(onDismissRequest = dismiss, title = { Text("Remove $name?") },
        confirmButton = { TextButton(onClick = remove) { Text("Remove") } }, dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } })
}
