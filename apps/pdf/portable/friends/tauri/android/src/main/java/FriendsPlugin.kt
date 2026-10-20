// The Kotlin half of tauri-plugin-szfriends (ADR 0015 § 7, § 10, § 17). Rust calls it (src/phone/native.rs); the
// page never does. It starts nothing by itself: each command answers one call.
//
// - dirs: the no-backup directory Friends keeps its files in (Auto Backup and device transfers skip it), and the
//   Android version.
// - seal, unseal, forget: the Friends key, sealed with an AES-GCM key the Android Keystore holds and never exports.
// - share: a received file to Save… (the system's document picker) or Share… (the share sheet).
// - publishDownload: a received file into the public Downloads through MediaStore (Android 10 and later, no
//   permission), hidden while it is written (IS_PENDING), named "Name (2).ext" beside one of the same name.
// - openUrl: a web or mail link, or one of the system's settings screens.
//
// It extends NearbyPlugin, whose commands it answers too: Tauri keeps one Kotlin plugin per Tauri plugin, and a
// second one registered for szfriends replaced the first, so Nearby's calls never reached it.

package com.shenzhen.friends

import android.app.Activity
import android.app.AlertDialog
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.webkit.MimeTypeMap
import androidx.activity.result.ActivityResult
import androidx.core.content.FileProvider
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.shenzhen.friends.nearby.NearbyPlugin
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** "Name (2).ext", "Name (3).ext"… as the Friends core names a clash; the extension stays (16 characters at most). */
internal fun numberedName(name: String, n: Int): String {
  val dot = name.lastIndexOf('.')
  val extension = if (dot > 0 && dot < name.length - 1 && name.length - dot - 1 <= 16) name.substring(dot) else ""
  val base = if (extension.isEmpty()) name else name.substring(0, dot)
  return "$base ($n)$extension"
}

/** A received file the share sheet or the document picker gets: a file Friends published, or a MediaStore item. */
private class Received(val name: String, val open: () -> InputStream?)

/** Received files shared with other apps, as copies in the cache (res/xml/szfriends_share_paths.xml). */
class FriendsShareProvider : FileProvider()

@InvokeArg
class KeyArgs {
  lateinit var alias: String
  var data: String? = null
}

@InvokeArg
class PathArgs {
  lateinit var path: String
}

@InvokeArg
class PublishArgs {
  lateinit var path: String
  lateinit var name: String
}

@InvokeArg
class UrlArgs {
  lateinit var url: String
}

private const val KEYSTORE = "AndroidKeyStore"
private const val SEALED_VERSION: Byte = 1

private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

private fun unhex(text: String): ByteArray? {
  if (text.length % 2 != 0) return null
  return try {
    ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
  } catch (e: NumberFormatException) {
    null
  }
}

@TauriPlugin
class FriendsPlugin(private val activity: Activity) : NearbyPlugin(activity) {
  /** The file waiting for the document picker's answer (Save…). */
  private var saving: Received? = null

  @Command
  fun dirs(invoke: Invoke) {
    val result = JSObject()
    result.put("base", activity.noBackupFilesDir.absolutePath)
    // Android 10 (29) and later save received files to Downloads through MediaStore (publishDownload).
    result.put("sdk", Build.VERSION.SDK_INT)
    // What the person's other computers call this phone: the name in Settings ▸ About, else the model.
    val named = Settings.Global.getString(activity.contentResolver, Settings.Global.DEVICE_NAME)
    result.put("name", if (named.isNullOrBlank()) Build.MODEL else named)
    invoke.resolve(result)
  }

  @Command
  fun excludeFromBackup(invoke: Invoke) {
    // The no-backup directory is never backed up; nothing to mark.
    val result = JSObject()
    result.put("done", true)
    invoke.resolve(result)
  }

  private fun keystore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

  private fun key(alias: String, create: Boolean): SecretKey? {
    (keystore().getKey(alias, null) as? SecretKey)?.let { return it }
    if (!create) return null
    val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
    val purposes = KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
    generator.init(
      KeyGenParameterSpec.Builder(alias, purposes)
        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
        .setKeySize(256)
        .build()
    )
    return generator.generateKey()
  }

  /** version, IV length, IV, then AES-GCM over the secret with the alias as associated data. */
  @Command
  fun seal(invoke: Invoke) {
    try {
      val args = invoke.parseArgs(KeyArgs::class.java)
      val secret = args.data?.let { unhex(it) } ?: return invoke.reject("no secret")
      val cipher = Cipher.getInstance("AES/GCM/NoPadding")
      cipher.init(Cipher.ENCRYPT_MODE, key(args.alias, true))
      cipher.updateAAD(args.alias.toByteArray())
      val iv = cipher.iv
      val body = cipher.doFinal(secret)
      secret.fill(0)
      val result = JSObject()
      result.put("sealed", hex(byteArrayOf(SEALED_VERSION, iv.size.toByte()) + iv + body))
      invoke.resolve(result)
    } catch (e: Exception) {
      invoke.reject("not sealed: ${e.javaClass.simpleName}")
    }
  }

  @Command
  fun unseal(invoke: Invoke) {
    try {
      val args = invoke.parseArgs(KeyArgs::class.java)
      val sealed = args.data?.let { unhex(it) } ?: return invoke.reject("nothing to open")
      val result = JSObject()
      val key = key(args.alias, false)
      if (key == null) {
        result.put("keyGone", true)
        return invoke.resolve(result)
      }
      if (sealed.size < 2 || sealed[0] != SEALED_VERSION) return invoke.reject("unknown format")
      val ivLength = sealed[1].toInt()
      if (sealed.size < 2 + ivLength + 16) return invoke.reject("too short")
      val iv = sealed.copyOfRange(2, 2 + ivLength)
      val cipher = Cipher.getInstance("AES/GCM/NoPadding")
      cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
      cipher.updateAAD(args.alias.toByteArray())
      val secret = cipher.doFinal(sealed, 2 + ivLength, sealed.size - 2 - ivLength)
      result.put("secret", hex(secret))
      secret.fill(0)
      invoke.resolve(result)
    } catch (e: Exception) {
      invoke.reject("not opened: ${e.javaClass.simpleName}")
    }
  }

  @Command
  fun forget(invoke: Invoke) {
    try {
      val args = invoke.parseArgs(KeyArgs::class.java)
      val store = keystore()
      if (store.containsAlias(args.alias)) store.deleteEntry(args.alias)
      val result = JSObject()
      result.put("done", true)
      invoke.resolve(result)
    } catch (e: Exception) {
      invoke.reject("not forgotten: ${e.javaClass.simpleName}")
    }
  }

  private fun done(invoke: Invoke, done: Boolean) {
    val result = JSObject()
    result.put("done", done)
    invoke.resolve(result)
  }

  /**
   * Save… or Share… for a received file. The person tapped Share… on it; they choose whether to keep a copy where
   * they like (the system's document picker) or send it with another app.
   */
  /** What `path` names: a file, or a content URI publishDownload answered (Android 10, where no path reads it). */
  private fun received(path: String): Received? {
    if (path.startsWith("content://")) {
      val uri = Uri.parse(path)
      if (uri.authority != MediaStore.AUTHORITY) return null
      val name = try {
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
          if (it.moveToFirst()) it.getString(0) else null
        }
      } catch (e: Exception) {
        null
      } ?: return null
      return Received(name) { activity.contentResolver.openInputStream(uri) }
    }
    val file = File(path)
    if (!file.isFile) return null
    return Received(file.name) { file.inputStream() }
  }

  private fun mimeType(name: String): String =
    MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
      ?: "application/octet-stream"

  /**
   * Save… or Share… for a received file. The person tapped Share… on it; they choose whether to keep a copy where
   * they like (the system's document picker) or send it with another app.
   */
  @Command
  fun share(invoke: Invoke) {
    val args = invoke.parseArgs(PathArgs::class.java)
    val file = received(args.path) ?: return done(invoke, false)
    activity.runOnUiThread {
      AlertDialog.Builder(activity)
        .setTitle(file.name)
        .setItems(arrayOf("Save…", "Share…")) { _, which ->
          if (which == 0) save(invoke, file) else send(invoke, file)
        }
        .setOnCancelListener { done(invoke, false) }
        .show()
    }
  }

  private fun save(invoke: Invoke, file: Received) {
    saving = file
    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
      .addCategory(Intent.CATEGORY_OPENABLE)
      .setType(mimeType(file.name))
      .putExtra(Intent.EXTRA_TITLE, file.name)
    startActivityForResult(invoke, intent, "saved")
  }

  @ActivityCallback
  fun saved(invoke: Invoke, result: ActivityResult) {
    val file = saving
    saving = null
    val target = result.data?.data
    if (result.resultCode != Activity.RESULT_OK || file == null || target == null) return done(invoke, false)
    Thread {
      val copied = try {
        activity.contentResolver.openOutputStream(target, "w")?.use { out ->
          file.open()?.use { it.copyTo(out) } != null
        } ?: false
      } catch (e: Exception) {
        false
      }
      done(invoke, copied)
    }.start()
  }

  private fun send(invoke: Invoke, file: Received) {
    Thread {
      try {
        // A copy in the cache, so no other app is ever handed a path into the Friends directory.
        val directory = File(activity.cacheDir, "szfriends-share")
        directory.deleteRecursively()
        directory.mkdirs()
        val copy = File(directory, file.name)
        val copied = copy.outputStream().use { out -> file.open()?.use { it.copyTo(out) } != null }
        if (!copied) return@Thread done(invoke, false)
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.szfriends.share", copy)
        val intent = Intent(Intent.ACTION_SEND)
          .setType(mimeType(file.name))
          .putExtra(Intent.EXTRA_STREAM, uri)
          .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.runOnUiThread { activity.startActivity(Intent.createChooser(intent, null)) }
        done(invoke, true)
      } catch (e: Exception) {
        done(invoke, false)
      }
    }.start()
  }

  /** Whether Downloads already shows `name` as one of this app's items, or as a file this app can see. */
  private fun taken(resolver: ContentResolver, collection: Uri, name: String): Boolean {
    val where = "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
    val relative = "${Environment.DIRECTORY_DOWNLOADS}/"
    val listed = try {
      resolver.query(collection, arrayOf(MediaStore.MediaColumns._ID), where, arrayOf(name, relative), null)
        ?.use { it.count > 0 } ?: false
    } catch (e: Exception) {
      false
    }
    @Suppress("DEPRECATION")
    val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    return listed || File(downloads, name).exists()
  }

  /**
   * A received file, checked by Friends, into the public Downloads (MediaStore.Downloads, Android 10 and later; no
   * permission): pending (invisible) until every byte is written and synced, under a name no other item has. Answers
   * where Friends finds it again: the file's path where this app can read it by path (Android 11 and later), else
   * the item's content URI; and the name it got. Android 9 and earlier: refused, and Friends keeps the file itself.
   */
  @Command
  fun publishDownload(invoke: Invoke) {
    val args = invoke.parseArgs(PublishArgs::class.java)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return invoke.reject("no MediaStore downloads")
    Thread {
      val resolver = activity.contentResolver
      val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
      var item: Uri? = null
      try {
        val source = File(args.path)
        var name = args.name
        var n = 2
        while (taken(resolver, collection, name) && n < 10000) name = numberedName(args.name, n++)
        val values = ContentValues().apply {
          put(MediaStore.MediaColumns.DISPLAY_NAME, name)
          put(MediaStore.MediaColumns.MIME_TYPE, mimeType(name))
          put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/")
          put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: throw IllegalStateException("not inserted")
        item = uri
        resolver.openFileDescriptor(uri, "w")?.use { descriptor ->
          FileOutputStream(descriptor.fileDescriptor).use { out ->
            source.inputStream().use { it.copyTo(out) }
            out.flush()
            out.fd.sync()
          }
        } ?: throw IllegalStateException("not opened")
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        // MediaStore may have changed the name to keep it unique among other apps' items.
        val shown = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
          if (it.moveToFirst()) it.getString(0) else null
        } ?: name
        @Suppress("DEPRECATION")
        val file = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), shown)
        val readable = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && file.canRead()
        val result = JSObject()
        result.put("location", if (readable) file.absolutePath else uri.toString())
        result.put("name", shown)
        invoke.resolve(result)
      } catch (e: Exception) {
        item?.let { try { resolver.delete(it, null, null) } catch (ignored: Exception) {} }
        invoke.reject("not saved: ${e.javaClass.simpleName}")
      }
    }.start()
  }

  @Command
  fun openUrl(invoke: Invoke) {
    val url = invoke.parseArgs(UrlArgs::class.java).url
    val intent = when (url) {
      "szfriends-settings:app" ->
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null))
      "szfriends-settings:bluetooth" -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
      "szfriends-settings:wifi" -> Intent(Settings.ACTION_WIFI_SETTINGS)
      else -> {
        val uri = Uri.parse(url)
        if (uri.scheme !in setOf("https", "http", "mailto")) return done(invoke, false)
        Intent(Intent.ACTION_VIEW, uri)
      }
    }
    activity.runOnUiThread {
      val opened = try {
        activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
      } catch (e: Exception) {
        false
      }
      done(invoke, opened)
    }
  }
}
