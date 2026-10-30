@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.mai.kotlin

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import java.util.UUID

@Composable internal fun ProviderManager(state: AppState, model: MaiViewModel) {
    var adding by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<ProviderInfo?>(null) }
    var removing by remember { mutableStateOf<ProviderInfo?>(null) }
    val enabled = !state.generating && !state.loadingModels
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text("Providers", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            IconButton(onClick = { adding = true }, enabled = enabled) { Icon(Icons.Outlined.Add, "Add provider") }
        }
        Text("Save multiple endpoints and choose the provider for your chat. Each keeps its own key and default model.")
        state.providers.forEach { provider ->
            ElevatedCard(Modifier.fillMaxWidth()) {
                ListItem(headlineContent = { Text(provider.name) }, supportingContent = { Column {
                    Text(provider.baseURL, style = MaterialTheme.typography.bodySmall)
                    if (provider.model.isNotEmpty()) Text(provider.model, style = MaterialTheme.typography.labelMedium)
                } }, leadingContent = { RadioButton(provider.id == state.selectedProviderID, onClick = null) },
                    modifier = Modifier.clickable(enabled = enabled) { model.command("selectProvider", "id" to provider.id) },
                    trailingContent = { IconButton(onClick = { editing = provider }, enabled = enabled) { Icon(Icons.Outlined.Edit, "Edit ${provider.name}") } })
                Row(Modifier.padding(horizontal = 12.dp)) {
                    if (provider.id == state.selectedProviderID) TextButton(onClick = { model.command("models") }, enabled = enabled) { Text("Find models") }
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = { removing = provider }, enabled = enabled && state.providers.size > 1) { Text("Remove") }
                }
            }
        }
        OutlinedButton(onClick = { adding = true }, enabled = enabled, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp)); Text("Add provider") }
    }
    if (adding || editing != null) {
        val id = remember(editing?.id) { editing?.id ?: UUID.randomUUID().toString() }
        var name by remember(id) { mutableStateOf(editing?.name.orEmpty()) }
        var url by remember(id) { mutableStateOf(editing?.baseURL ?: "https://api.openai.com/v1") }
        var key by remember(id) { mutableStateOf(editing?.apiKey.orEmpty()) }
        var selectedModel by remember(id) { mutableStateOf(editing?.model.orEmpty()) }
        var reveal by remember { mutableStateOf(false) }
        ModalBottomSheet(onDismissRequest = { adding = false; editing = null }) {
            Column(Modifier.fillMaxWidth().imePadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(if (adding) "Add provider" else "Edit provider", style = MaterialTheme.typography.headlineSmall)
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(url, { url = it }, label = { Text("API base URL") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(key, { key = it }, label = { Text("API key") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                    visualTransformation = if (reveal) VisualTransformation.None else PasswordVisualTransformation(), trailingIcon = {
                        IconButton(onClick = { reveal = !reveal }) { Icon(if (reveal) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, if (reveal) "Hide API key" else "Show API key") }
                    })
                OutlinedTextField(selectedModel, { selectedModel = it }, label = { Text("Default model ID") }, supportingText = { Text("Enter a model ID or use Find models after saving.") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Button(onClick = {
                    model.command("provider", "id" to id, "name" to name.trim(), "baseURL" to url.trim(), "apiKey" to key, "model" to selectedModel.trim())
                    adding = false; editing = null
                }, enabled = name.isNotBlank() && (url.startsWith("http://") || url.startsWith("https://")), modifier = Modifier.fillMaxWidth()) { Text("Save provider") }
            }
        }
    }
    removing?.let { provider -> AlertDialog(onDismissRequest = { removing = null }, title = { Text("Remove ${provider.name}?") },
        text = { Text("Saved conversations are kept. You’ll need to choose another provider before using its old chats.") },
        confirmButton = { TextButton(onClick = { model.command("removeProvider", "id" to provider.id); removing = null }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } }) }
}
