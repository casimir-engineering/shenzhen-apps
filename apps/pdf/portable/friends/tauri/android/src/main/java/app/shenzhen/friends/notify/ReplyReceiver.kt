// Reply on a message notification (RemoteInput): the text goes to the core, which sends it in that conversation and
// marks it read, which withdraws the notification. Without a core in this process (it stopped since the notification
// was posted) the text cannot go anywhere, and the notification goes so the system stops waiting on it.

package app.shenzhen.friends.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import app.tauri.plugin.JSObject

class ReplyReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action != Notifications.ACTION_REPLY) return
    val key = intent.getStringExtra(Notifications.EXTRA_KEY) ?: return
    val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(Notifications.REPLY_TEXT)?.toString()
    if (text.isNullOrBlank()) return
    Notifications.send(JSObject().put("kind", "reply").put("key", key).put("text", text))
    // The system shows a spinner on the reply until the notification changes: it goes now; the core withdraws the
    // rest of the conversation once the reply marks it read.
    Notifications.cancel(context, key)
  }
}
