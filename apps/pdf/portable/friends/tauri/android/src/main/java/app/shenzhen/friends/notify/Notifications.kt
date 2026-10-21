// Friends' system notifications on Android (ADR 0017): the core decides what notifies and hands each request to the
// plugin (src/phone/notify.rs), which posts it here. Four channels: Messages, Files, Requests, and "Reachable in the
// background" for the ongoing notification of ReachableService. Their names come from the catalog, through Rust, and
// are kept so the boot receiver and the service can name their channel without the core.
//
// A notification's tap opens the app's launcher activity with the request's URL as an ACTION_VIEW intent
// (`<scheme>://friends/conversation/<id>`): the deep-link plugin hears it as it hears a Friends link. Reply, on a
// message, is RemoteInput; ReplyReceiver gives the text to the core.
//
// POST_NOTIFICATIONS (Android 13 and later) is asked in the same request as Nearby's Bluetooth permissions
// (NearbyPlugin), or alone when the person taps Allow in Settings. A refusal the system may still ask about reads as
// not yet asked, so Settings keeps its Allow; once the system answers without a dialog, the refusal is for good and
// Settings offers Open Settings, as Nearby does.

package app.shenzhen.friends.notify

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import app.tauri.plugin.Channel
import app.tauri.plugin.JSObject
import com.shenzhen.friends.R
import java.time.Instant

/** One notification as the core built it (ADR 0017 § The request). */
class Request(
  val key: String,
  val kind: String,
  val channel: String,
  val thread: String,
  val title: String,
  val body: String,
  val time: String?,
  val url: String,
  val reply: ReplyLabels?,
)

class ReplyLabels(val label: String, val placeholder: String, val send: String)

object Notifications {
  const val MESSAGES = "friends.messages"
  const val FILES = "friends.files"
  const val REQUESTS = "friends.requests"
  const val BACKGROUND = "friends.background"

  /** The extra a notification's tap carries: its key, for the core. */
  const val EXTRA_KEY = "app.shenzhen.friends.notification"
  const val EXTRA_THREAD = "app.shenzhen.friends.thread"
  const val REPLY_TEXT = "app.shenzhen.friends.reply"
  const val ACTION_REPLY = "app.shenzhen.friends.REPLY"

  private const val PREFERENCES = "szfriends_notify"
  /** Set once the system refused POST_NOTIFICATIONS without showing its dialog. */
  private const val REFUSED = "refused_for_good"
  /** Set once POST_NOTIFICATIONS went out with a Nearby request, or alone after Bluetooth was already allowed. */
  private const val ASKED_WITH_NEARBY = "asked_with_nearby"
  const val BACKGROUND_ON = "background_on"
  const val BACKGROUND_TITLE = "background_title"
  const val BACKGROUND_BODY = "background_body"
  const val BACKGROUND_URL = "background_url"
  private const val CHANNEL_NAME = "channel_name."

  /** Where responses go: the core's channel while it runs in this process. */
  @Volatile var responses: Channel? = null
  /** The permission last reported, so a change (in Settings) is reported once. */
  @Volatile private var reported: String? = null

  fun preferences(context: Context) =
    context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

  private fun manager(context: Context) =
    context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

  /** The channels with the catalog's names; their names are kept for the boot receiver and the service. */
  fun setChannels(context: Context, names: Map<String, String>) {
    val editor = preferences(context).edit()
    for ((id, name) in names) editor.putString(CHANNEL_NAME + id, name)
    editor.apply()
    for (id in listOf(MESSAGES, FILES, REQUESTS, BACKGROUND)) ensureChannel(context, id)
  }

  fun ensureChannel(context: Context, id: String) {
    if (Build.VERSION.SDK_INT < 26) return
    val name = preferences(context).getString(CHANNEL_NAME + id, null) ?: return
    val importance = when (id) {
      MESSAGES -> NotificationManager.IMPORTANCE_HIGH
      BACKGROUND -> NotificationManager.IMPORTANCE_LOW
      else -> NotificationManager.IMPORTANCE_DEFAULT
    }
    val channel = NotificationChannel(id, name, importance)
    if (id == BACKGROUND) {
      channel.setShowBadge(false)
      channel.setSound(null, null)
      channel.enableVibration(false)
    }
    // Creating an existing channel updates its name only; the person's own choices for it stay.
    manager(context).createNotificationChannel(channel)
  }

  private fun channelId(channel: String) = when (channel) {
    "messages" -> MESSAGES
    "files" -> FILES
    else -> REQUESTS
  }

  /** The app's launcher activity, opened on `url` as a link would open it. */
  fun openIntent(context: Context, url: String, key: String?, thread: String?): PendingIntent {
    val launcher = context.packageManager.getLaunchIntentForPackage(context.packageName)?.component
    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
      .setComponent(launcher)
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    if (key != null) intent.putExtra(EXTRA_KEY, key)
    if (thread != null) intent.putExtra(EXTRA_THREAD, thread)
    val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    return PendingIntent.getActivity(context, (key ?: url).hashCode(), intent, flags)
  }

  private fun millis(time: String?): Long =
    try {
      if (time != null && Build.VERSION.SDK_INT >= 26) Instant.parse(time).toEpochMilli() else System.currentTimeMillis()
    } catch (e: Exception) {
      System.currentTimeMillis()
    }

  fun post(context: Context, request: Request): Boolean {
    if (!allowed(context)) return false
    val id = channelId(request.channel)
    ensureChannel(context, id)
    val builder = NotificationCompat.Builder(context, id)
      .setSmallIcon(R.drawable.szfriends_notification)
      .setContentTitle(request.title)
      .setContentText(request.body)
      .setStyle(NotificationCompat.BigTextStyle().bigText(request.body))
      .setWhen(millis(request.time))
      .setShowWhen(true)
      .setAutoCancel(true)
      .setGroup(request.thread)
      .setCategory(if (request.kind == "message") NotificationCompat.CATEGORY_MESSAGE else NotificationCompat.CATEGORY_SOCIAL)
      .setPriority(if (id == MESSAGES) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
      .setContentIntent(openIntent(context, request.url, request.key, request.thread))
    val reply = request.reply
    if (reply != null && responses != null) builder.addAction(replyAction(context, request, reply))
    return try {
      NotificationManagerCompat.from(context).notify(request.key, 0, builder.build())
      true
    } catch (e: SecurityException) {
      false
    }
  }

  private fun replyAction(context: Context, request: Request, labels: ReplyLabels): NotificationCompat.Action {
    val input = RemoteInput.Builder(REPLY_TEXT).setLabel(labels.placeholder).build()
    val intent = Intent(context, ReplyReceiver::class.java)
      .setAction(ACTION_REPLY)
      .setData(Uri.parse("szfriends-reply:${Uri.encode(request.key)}"))
      .putExtra(EXTRA_KEY, request.key)
    // RemoteInput fills the intent in, so it must stay mutable (Android 12 and later ask to say so).
    val mutable = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
    val pending = PendingIntent.getBroadcast(
      context, request.key.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or mutable)
    return NotificationCompat.Action.Builder(R.drawable.szfriends_notification, labels.label, pending)
      .addRemoteInput(input)
      .setAllowGeneratedReplies(false)
      .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
      .setShowsUserInterface(false)
      .build()
  }

  /** Removes the delivered notifications of one conversation. */
  fun withdraw(context: Context, thread: String) {
    if (Build.VERSION.SDK_INT < 23) return
    val manager = manager(context)
    for (shown in manager.activeNotifications) {
      if (shown.notification.group == thread && shown.notification.channelIdCompat() != BACKGROUND) {
        manager.cancel(shown.tag, shown.id)
      }
    }
  }

  fun cancel(context: Context, key: String) {
    NotificationManagerCompat.from(context).cancel(key, 0)
  }

  private fun android.app.Notification.channelIdCompat(): String? =
    if (Build.VERSION.SDK_INT >= 26) channelId else null

  private fun permissionGranted(context: Context): Boolean =
    Build.VERSION.SDK_INT < 33 ||
      ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
      PackageManager.PERMISSION_GRANTED

  fun allowed(context: Context): Boolean =
    permissionGranted(context) && NotificationManagerCompat.from(context).areNotificationsEnabled()

  /** `granted`, `denied` (Settings only), or `not_asked` while the system may still ask. */
  fun permission(context: Context): String = when {
    allowed(context) -> "granted"
    permissionGranted(context) -> "denied" // turned off in Settings
    preferences(context).getBoolean(REFUSED, false) -> "denied"
    else -> "not_asked"
  }

  /** Whether a request for Nearby's permissions should carry POST_NOTIFICATIONS. */
  fun wanted(context: Context): Boolean =
    Build.VERSION.SDK_INT >= 33 && !permissionGranted(context) && !preferences(context).getBoolean(REFUSED, false)

  /** Bluetooth was allowed before this build asked for notifications: ask once, the next time Nearby asks. */
  fun wantedOnceAlone(context: Context): Boolean =
    wanted(context) && !preferences(context).getBoolean(ASKED_WITH_NEARBY, false)

  fun markAsked(context: Context) {
    preferences(context).edit().putBoolean(ASKED_WITH_NEARBY, true).apply()
  }

  /** The system's answer to a request that carried POST_NOTIFICATIONS. */
  fun answered(context: Context, alone: Boolean, noDialog: Boolean) {
    if (permissionGranted(context)) {
      preferences(context).edit().remove(REFUSED).apply()
    } else if (alone && noDialog) {
      preferences(context).edit().putBoolean(REFUSED, true).apply()
    }
    report(context)
  }

  /** Tells the core the permission when it changed (an answer, or a switch flipped in Settings). */
  fun report(context: Context, always: Boolean = false) {
    val state = permission(context)
    if (!always && state == reported) return
    reported = state
    send(JSObject().put("kind", "permission").put("state", state))
  }

  fun send(event: JSObject): Boolean {
    val channel = responses ?: return false
    return try {
      channel.send(event)
      true
    } catch (e: Exception) {
      false
    }
  }

  /** "Stay reachable in the background": the service runs while the switch is on, and again after a restart. */
  fun setBackground(context: Context, on: Boolean, title: String?, body: String?, url: String?) {
    val editor = preferences(context).edit().putBoolean(BACKGROUND_ON, on)
    if (title != null) editor.putString(BACKGROUND_TITLE, title)
    if (body != null) editor.putString(BACKGROUND_BODY, body)
    if (url != null) editor.putString(BACKGROUND_URL, url)
    editor.apply()
    val intent = Intent(context, ReachableService::class.java)
    if (on) {
      ContextCompat.startForegroundService(context, intent)
    } else {
      context.stopService(intent)
    }
  }
}
