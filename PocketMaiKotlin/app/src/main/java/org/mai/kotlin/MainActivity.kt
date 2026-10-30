package org.mai.kotlin

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    private var invitation by mutableStateOf("")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        invitation = intent.dataString?.takeIf { it.startsWith("pmai-acp://connect/") }.orEmpty()
        setContent {
            val prefs = remember { getSharedPreferences("appearance", MODE_PRIVATE) }
            var theme by remember { mutableStateOf(prefs.getString("theme", "system") ?: "system") }
            val dark = when (theme) { "dark" -> true; "light" -> false; else -> isSystemInDarkTheme() }
            val colors = if (android.os.Build.VERSION.SDK_INT >= 31) {
                if (dark) dynamicDarkColorScheme(this) else dynamicLightColorScheme(this)
            } else if (dark) darkColorScheme(primary = Color(0xFFB6C4FF)) else lightColorScheme(primary = Color(0xFF455CA8))
            MaterialTheme(colorScheme = colors) {
                val model: MaiViewModel = viewModel()
                val state by model.state.collectAsStateWithLifecycle()
                val draft by model.draft.collectAsStateWithLifecycle()
                val attachments by model.attachments.collectAsStateWithLifecycle()
                PocketMaiApp(state, draft, attachments, model, theme, onTheme = {
                    theme = it; prefs.edit().putString("theme", it).apply()
                }, invitation = invitation, consumeInvitation = { invitation = "" })
            }
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        invitation = intent.dataString?.takeIf { it.startsWith("pmai-acp://connect/") }.orEmpty()
    }
}
