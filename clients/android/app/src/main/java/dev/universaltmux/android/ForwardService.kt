package dev.universaltmux.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.content.ContextCompat
import kotlin.concurrent.thread

/**
 * Foreground service that keeps the Argus PROCESS (and therefore the embedded
 * tsnet node + every active port-forward listener) alive while a forward is
 * running. Without it, the instant you switch to the browser Android backgrounds
 * Argus and freezes its threads within seconds — so the forward "works for a few
 * seconds then dies" (worst on Samsung). A foreground service with an ongoing
 * notification is the platform-sanctioned way to keep serving in the background,
 * exactly how Tailscale/VPN/music apps stay alive.
 *
 * It also: holds a partial wake-lock so the CPU keeps pumping bytes while the
 * screen is off, re-warms the tsnet path on every network change (Wi-Fi↔cellular
 * handoff), and polls each forward's reachability to drive the live/broken dot.
 */
class ForwardService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var netCb: ConnectivityManager.NetworkCallback? = null
    @Volatile private var polling = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
        acquireWakeLock()
        registerNetworkCallback()
        startHealthPoller()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_ALL) {
            Forwards.clearAll()           // stop every tunnel...
            stopSelf()                    // ...then drop the service (onDestroy cleans up)
            return START_NOT_STICKY
        }
        // Always (re)assert foreground with a fresh notification within the 5s window.
        val notif = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notif)
        }
        // If we were started but there's nothing to forward (raced a stop), bow out.
        if (Forwards.active.isEmpty()) stopSelf()
        return START_NOT_STICKY // the forwards die with the process; don't half-resurrect
    }

    override fun onDestroy() {
        polling = false
        netCb?.let {
            try { (getSystemService(ConnectivityManager::class.java)).unregisterNetworkCallback(it) } catch (_: Throwable) {}
        }
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Throwable) {}
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ut:forward").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun registerNetworkCallback() {
        val cm = getSystemService(ConnectivityManager::class.java)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = rewarmAll()
            override fun onLost(network: Network) = rewarmAll()
        }
        try {
            cm.registerNetworkCallback(NetworkRequest.Builder().build(), cb)
            netCb = cb
        } catch (_: Throwable) {}
    }

    /** A network changed — nudge every active forward's tsnet path back up. */
    private fun rewarmAll() {
        val e = TsnetCore.engine ?: return
        thread(name = "ut-rewarm") {
            Forwards.active.toList().distinctBy { it.brokerHost }.forEach {
                try { e.warmUp(it.brokerHost, it.scheme) } catch (_: Throwable) {}
            }
        }
    }

    /** Poll each forward's reachability (over tsnet) so the UI shows live/broken. */
    private fun startHealthPoller() {
        if (polling) return
        polling = true
        thread(name = "ut-fwd-health") {
            while (polling) {
                val e = TsnetCore.engine
                Forwards.active.toList().forEach { af ->
                    af.health = when {
                        e == null -> "broken"
                        try { e.reachable(af.brokerHost, af.scheme) } catch (_: Throwable) { false } -> "live"
                        else -> "broken"
                    }
                }
                try { Thread.sleep(8000) } catch (_: InterruptedException) { break }
            }
        }
    }

    private fun buildNotification(): Notification {
        val n = Forwards.active.size
        val lines = Forwards.active.joinToString("\n") {
            "${it.brokerName}:${it.remotePort} → localhost:${it.localPort}"
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopAll = PendingIntent.getService(
            this, 1,
            Intent(this, ForwardService::class.java).setAction(ACTION_STOP_ALL),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(if (n == 1) "Forwarding 1 port" else "Forwarding $n ports")
            .setContentText(Forwards.active.firstOrNull()?.let { "${it.brokerName}:${it.remotePort} → localhost:${it.localPort}" } ?: "")
            .setStyle(Notification.BigTextStyle().bigText(lines))
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(
                android.R.drawable.ic_menu_close_clear_cancel, "Stop all", stopAll).build())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "ut.forward"
        private const val NOTIF_ID = 4711
        const val ACTION_STOP_ALL = "dev.universaltmux.android.STOP_FORWARDS"

        private fun ensureChannel(ctx: Context) {
            val mgr = ctx.getSystemService(NotificationManager::class.java)
            mgr.createNotificationChannel(
                NotificationChannel(CHANNEL, "Port forwarding", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Keeps active port-forwards alive in the background"
                    setShowBadge(false)
                })
        }

        /**
         * Reconcile the service with the current set of forwards: start/refresh it
         * (foreground) when any forward is active, stop it when none remain. Call
         * after every start/stop.
         */
        fun sync(ctx: Context) {
            val app = ctx.applicationContext
            val intent = Intent(app, ForwardService::class.java)
            if (Forwards.active.isNotEmpty()) {
                ContextCompat.startForegroundService(app, intent)
            } else {
                app.stopService(intent)
            }
        }
    }
}
