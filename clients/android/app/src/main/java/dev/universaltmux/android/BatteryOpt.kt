package dev.universaltmux.android

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings

/**
 * One-time prompt to exempt Argus from battery optimization. A foreground service
 * keeps the process running, but aggressive OEMs (Samsung especially) will still
 * "deep sleep" an optimized app and cut its network — stranding active forwards.
 * The exemption is what actually lets a background tunnel keep flowing.
 */
object BatteryOpt {
    @Volatile private var asked = false

    fun isExempt(ctx: Context): Boolean {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(ctx.packageName)
    }

    /** Show the system exemption dialog once per app run (no-op if already exempt). */
    @SuppressLint("BatteryLife") // intentional: a user-started tunnel must survive Doze; sideloaded, not Play-distributed
    fun maybePrompt(ctx: Context) {
        if (asked || isExempt(ctx)) return
        asked = true
        try {
            ctx.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${ctx.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Throwable) {}
    }
}
