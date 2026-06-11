package dev.universaltmux.android

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * Closes the attention loop on the phone (mirrors the Mac's AttentionNotifier):
 * a notification when a session transitions INTO "waiting" (the agent is
 * blocked on you), with one-tap steering actions — Yes / No / ↵ — that answer
 * over a one-shot WebSocket without even opening the app.
 */
object AttentionNotifier {
    private const val CHANNEL = "ut.attention"

    fun ensureChannel(ctx: Context) {
        val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL, "Agent needs attention", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "An agent session is blocked waiting on your input"
            })
    }

    private fun canPost(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun notifId(broker: Broker, session: String) = ("${broker.id} $session").hashCode()

    /** Post (or refresh) the "blocked on you" notification for one session. */
    fun post(ctx: Context, broker: Broker, session: String) {
        if (!canPost(ctx)) return
        ensureChannel(ctx)

        // Tapping opens the app on that session.
        val open = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("host", broker.host)
            putExtra("session", session)
        }
        val openPI = PendingIntent.getActivity(ctx, notifId(broker, session), open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        // Awareness only — tap to open the session and navigate it yourself. No
        // quick-answer actions: they were Yes/No-shaped and meaningless for the
        // numbered/option menus most agents actually show.
        val n = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(session)
            .setContentText("Agent is waiting on you — ${broker.name}")
            .setContentIntent(openPI)
            .setAutoCancel(true)
            .build()
        val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        mgr.notify(notifId(broker, session), n)
    }

    /** Drop the notification once the session leaves "waiting" (or is viewed). */
    fun clear(ctx: Context, broker: Broker, session: String) {
        val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        mgr.cancel(notifId(broker, session))
    }
}
