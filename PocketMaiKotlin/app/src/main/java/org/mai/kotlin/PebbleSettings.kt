package org.mai.kotlin

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import org.json.JSONObject

data class PebbleState(
    val enabled: Boolean = false,
    val listening: Boolean = false,
    val paired: Boolean = false,
    val pairing: Boolean = false,
    val code: String = "",
    val error: String = "",
    val prompts: List<Prompt> = emptyList(),
) {
    companion object {
        fun decode(json: JSONObject?): PebbleState {
            json ?: return PebbleState()
            return PebbleState(json.optBoolean("enabled"), json.optBoolean("listening"),
                json.optBoolean("paired"), json.optBoolean("pairing"), json.optString("code"),
                json.optString("error"), json.optJSONArray("prompts").objects().map {
                    Prompt(it.getString("id"), it.getString("name"), it.getString("text"))
                })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun PebbleSettings(state: PebbleState, model: MaiViewModel, modifier: Modifier) {
    var editing by remember { mutableStateOf<Prompt?>(null) }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ListItem(headlineContent = { Text("Enable Pebble") }, trailingContent = {
            Switch(checked = state.enabled, onCheckedChange = { model.command("pebbleEnable", "enabled" to it.toString()) })
        })
        Text("Keep PocketMai open while using the watch. Enable Keep Awake to prevent the screen from locking.")
        if (state.error.isNotEmpty()) Text(state.error, color = MaterialTheme.colorScheme.error)
        when {
            state.paired -> TextButton(onClick = { model.command("pebbleForget") }) { Text("Forget Watch") }
            state.code.isNotEmpty() -> {
                Text("Watch code: ${state.code}", fontFamily = FontFamily.Monospace)
                Button(onClick = { model.command("pebbleApprove") }) { Text("Confirm Matching Code") }
                TextButton(onClick = { model.command("pebblePair") }) { Text("Start Over") }
            }
            state.pairing -> Text("Select Pair Phone on the watch.")
            else -> Button(onClick = { model.command("pebblePair") }, enabled = state.listening) { Text("Pair a Watch") }
        }
        HorizontalDivider()
        Text("Favorite Prompts", style = MaterialTheme.typography.titleLarge)
        state.prompts.forEach { prompt ->
            ListItem(headlineContent = { Text(prompt.name) }, trailingContent = {
                TextButton(onClick = { editing = prompt }) { Text("Edit") }
            })
        }
        Button(onClick = { editing = Prompt("", "", "") }, enabled = state.prompts.size < 8) { Text("Add Prompt") }
    }
    editing?.let { prompt ->
        var name by remember(prompt) { mutableStateOf(prompt.name) }
        var text by remember(prompt) { mutableStateOf(prompt.text) }
        ModalBottomSheet(onDismissRequest = { editing = null }) {
            Column(Modifier.fillMaxWidth().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Pebble Prompt", style = MaterialTheme.typography.headlineSmall)
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(text, { text = it }, label = { Text("Message") }, minLines = 3, modifier = Modifier.fillMaxWidth())
                Button(onClick = {
                    model.command("pebblePrompt", "id" to prompt.id, "name" to name, "text" to text)
                    editing = null
                }, enabled = name.isNotBlank() && text.isNotBlank()) { Text("Save Prompt") }
                if (prompt.id.isNotEmpty()) TextButton(onClick = {
                    model.command("pebblePrompt", "id" to prompt.id, "remove" to "true")
                    editing = null
                }) { Text("Delete Prompt") }
            }
        }
    }
}
