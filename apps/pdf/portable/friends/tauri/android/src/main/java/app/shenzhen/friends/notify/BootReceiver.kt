// After a restart of the phone (or an update of the app), "Stay reachable in the background" starts again while its
// switch is on.

package app.shenzhen.friends.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
    if (!Notifications.preferences(context).getBoolean(Notifications.BACKGROUND_ON, false)) return
    try {
      ContextCompat.startForegroundService(context, Intent(context, ReachableService::class.java))
    } catch (e: Exception) {
      // Refused by the system: the service starts with the app next time.
    }
  }
}
