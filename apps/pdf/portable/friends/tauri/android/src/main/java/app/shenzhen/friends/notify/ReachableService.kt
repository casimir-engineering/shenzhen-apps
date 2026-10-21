// "Stay reachable in the background" (ADR 0017 § Android in the background): a foreground service of type specialUse
// that keeps the app's process, and so the Friends core in it, running after the app leaves the screen. It does no
// work of its own; its quiet ongoing notification ("Friends is reachable") opens Friends' settings when tapped. The
// switch (set_notifications background) starts and stops it; BootReceiver starts it again after a restart while the
// switch is on.

package app.shenzhen.friends.notify

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.shenzhen.friends.R

class ReachableService : Service() {
  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val preferences = Notifications.preferences(this)
    if (!preferences.getBoolean(Notifications.BACKGROUND_ON, false)) {
      stopSelf()
      return START_NOT_STICKY
    }
    Notifications.ensureChannel(this, Notifications.BACKGROUND)
    val builder = NotificationCompat.Builder(this, Notifications.BACKGROUND)
      .setSmallIcon(R.drawable.szfriends_notification)
      .setContentTitle(preferences.getString(Notifications.BACKGROUND_TITLE, null))
      .setContentText(preferences.getString(Notifications.BACKGROUND_BODY, null))
      .setOngoing(true)
      .setSilent(true)
      .setShowWhen(false)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .setCategory(NotificationCompat.CATEGORY_SERVICE)
      .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
    preferences.getString(Notifications.BACKGROUND_URL, null)?.let {
      builder.setContentIntent(Notifications.openIntent(this, it, null, null))
    }
    try {
      if (Build.VERSION.SDK_INT >= 34) {
        startForeground(ID, builder.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
      } else {
        startForeground(ID, builder.build())
      }
    } catch (e: Exception) {
      // Not allowed now (the app in the background without an exemption): the switch stays on, and the service
      // starts with the app next time.
      stopSelf()
      return START_NOT_STICKY
    }
    return START_STICKY
  }

  companion object {
    const val ID = 0x5a46
  }
}
