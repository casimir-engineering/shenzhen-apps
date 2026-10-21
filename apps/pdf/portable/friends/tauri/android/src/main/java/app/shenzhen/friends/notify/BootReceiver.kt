// After a restart of the phone (or an update of the app) while "Stay reachable in the background" is on. Friends runs
// inside the app, and Android lets no app start itself in the background (a foreground service started here would say
// "Friends is reachable" with nothing running): the phone says Friends stopped, and its tap opens the app, which starts
// Friends and the background service again.

package app.shenzhen.friends.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
    if (!Notifications.preferences(context).getBoolean(Notifications.BACKGROUND_ON, false)) return
    Notifications.postRestarted(context)
  }
}
