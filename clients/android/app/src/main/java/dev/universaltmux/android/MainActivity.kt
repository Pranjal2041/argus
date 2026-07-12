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
        Forwards.appCtx = applicationContext // lets port-forward start/stop drive the foreground service
        JournalOutbox.init(applicationContext)
        JournalOutbox.onAdded = { vm.flushJournal() }   // ship resolved events immediately while foregrounded
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

    /** Attention notifications deep-link to either the exact Lab dossier or session. */
    private fun handleAttentionIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("openLab", false) == true) {
            val kind = runCatching {
                LabAttentionKind.valueOf(intent.getStringExtra("labKind") ?: "")
            }.getOrNull() ?: return
            val id = intent.getStringExtra("labID") ?: return
            vm.openLabAttention(kind, id)
            return
        }
        val host = intent?.getStringExtra("host") ?: return
        val session = intent.getStringExtra("session") ?: return
        val b = vm.brokers.firstOrNull { it.host == host } ?: return
        vm.selected = b to session
    }
}
