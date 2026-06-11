package dev.universaltmux.android

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AttentionNotifier.ensureChannel(this)
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        setContent { App(vm) }
        handleAttentionIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAttentionIntent(intent)
    }

    /** A tapped "agent is waiting" notification deep-links to its session. */
    private fun handleAttentionIntent(intent: Intent?) {
        val host = intent?.getStringExtra("host") ?: return
        val session = intent.getStringExtra("session") ?: return
        val b = vm.brokers.firstOrNull { it.host == host } ?: return
        vm.selected = b to session
    }
}
