// Updates on Android (docs/UPDATES.md § Android): the app checks the GitHub releases of casimir-engineering/shenzhen-3D
// that its APK came from, pre-releases included, with no account. On launch and once a day (never on a metered
// connection unless the person asks), it looks for a release newer than this one with an APK for this phone's ABI and
// offers it. Updating downloads the APK, checks it against the release's SHA256SUMS.txt and against this app's
// package and signing certificate, and hands it to PackageInstaller, which asks the person to confirm. Android lets an
// app install only once the person allowed it to ("Install unknown apps"); the app explains that first and opens the
// setting, once.
//
// The page reaches it through src-tauri/src/android_updates.rs (window.shenzhenUpdates, src/core/android-updates.ts).
// Every command answers at once with the state; what follows arrives on the subscribed channels.
//
// Debuggable builds only: files/update-api.txt (written with `adb shell run-as`) names another API root, for the
// emulator test against a mock GitHub API (scripts/android-update-e2e.mjs).

package com.shenzhen3d.viewer

import android.app.Activity
import android.app.AlertDialog
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.webkit.WebView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Channel
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import org.json.JSONArray
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

@InvokeArg
class UpdateSubscribeArgs {
  lateinit var channel: Channel
}

@InvokeArg
class UpdateConfigureArgs {
  var automatic: Boolean? = null
}

private const val OWNER = "casimir-engineering"
private const val REPOSITORY = "shenzhen-3D"
private const val GITHUB_API = "https://api.github.com"
private const val SUMS = "SHA256SUMS.txt"
private const val DAY = 24L * 60 * 60 * 1000
private const val TAG = "ShenzhenUpdates"

/** One release's APK for this phone. */
private data class Offer(
  val version: String,
  val apkName: String,
  val apkUrl: String,
  val size: Long,
  val sumsUrl: String,
)

/** Numbers first (0.2.10 after 0.2.9); a version with a suffix (0.3.0-rc1) comes before the same one without. */
internal fun compareVersions(a: String, b: String): Int {
  fun parts(version: String): Pair<List<Int>, String> {
    val core = version.substringBefore('-')
    return core.split('.').map { it.toIntOrNull() ?: 0 } to version.substringAfter('-', "")
  }
  val (left, leftSuffix) = parts(a)
  val (right, rightSuffix) = parts(b)
  for (i in 0 until maxOf(left.size, right.size)) {
    val difference = left.getOrElse(i) { 0 }.compareTo(right.getOrElse(i) { 0 })
    if (difference != 0) return difference
  }
  return when {
    leftSuffix == rightSuffix -> 0
    leftSuffix.isEmpty() -> 1
    rightSuffix.isEmpty() -> -1
    else -> leftSuffix.compareTo(rightSuffix)
  }
}

@TauriPlugin
class UpdatePlugin(private val activity: Activity) : Plugin(activity) {
  private val context: Context = activity.applicationContext
  private val preferences = context.getSharedPreferences("shenzhen_updates", Context.MODE_PRIVATE)
  private val main = Handler(Looper.getMainLooper())
  private val worker = Executors.newSingleThreadExecutor()
  private val channels = CopyOnWriteArrayList<Channel>()
  private val folder = File(context.cacheDir, "updates")

  private var status = "idle"
  private var message = ""
  private var progress: Double? = null
  private var offer: Offer? = null
  /** The downloaded APK, checked, waiting for PackageInstaller. */
  private var verified: File? = null
  /** The person went to "Install unknown apps" and is expected back. */
  private var awaitingPermission = false
  private var receiver: BroadcastReceiver? = null

  private val installedVersion: String by lazy { packageInfo(0).versionName ?: "0" }

  @Suppress("DEPRECATION")
  private fun packageInfo(flags: Int): PackageInfo = context.packageManager.getPackageInfo(context.packageName, flags)

  private fun debuggable() = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

  private fun apiRoot(): String {
    if (debuggable()) {
      val file = File(context.filesDir, "update-api.txt")
      val root = if (file.isFile) file.readText().trim() else ""
      if (root.isNotEmpty()) return root.trimEnd('/')
    }
    return GITHUB_API
  }

  private fun metered(): Boolean {
    val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager?
    return connectivity?.isActiveNetworkMetered ?: false
  }

  private val automatic: Boolean get() = preferences.getBoolean("automatic", true)
  private val lastChecked: Long get() = preferences.getLong("lastChecked", 0)

  override fun load(webView: WebView) {
    // What an earlier run downloaded is either installed by now or stale.
    folder.deleteRecursively()
    main.postDelayed({ checkIfDue() }, 4_000)
    main.postDelayed(object : Runnable {
      override fun run() {
        checkIfDue()
        main.postDelayed(this, 60L * 60 * 1000)
      }
    }, 60L * 60 * 1000)
  }

  override fun onResume(activity: AppCompatActivity) {
    if (awaitingPermission) {
      awaitingPermission = false
      if (canInstall()) install() else update("ready", "Shenzhen 3D can’t install the update until it’s allowed to. Tap Install update to try again.")
    }
    checkIfDue()
  }

  /** The daily check: only when the person left it on, never on a metered connection, never over something else. */
  private fun checkIfDue() {
    if (!automatic || status != "idle" && status != "error") return
    if (System.currentTimeMillis() - lastChecked < DAY || metered()) return
    check(manual = false)
  }

  @Synchronized
  private fun state(): JSObject {
    val state = JSObject()
      .put("supported", true)
      .put("platform", "android")
      .put("version", installedVersion)
      .put("status", status)
      .put("automatic", automatic)
      .put("repository", OWNER)
      .put("access", "public")
      .put("prereleases", true)
      .put("connected", true)
      .put("message", message)
    offer?.let { state.put("availableVersion", it.version).put("downloadSize", it.size) }
    progress?.let { state.put("progress", it) }
    if (lastChecked > 0) state.put("lastChecked", lastChecked)
    return state
  }

  private fun update(status: String, message: String, progress: Double? = null) {
    synchronized(this) {
      this.status = status
      this.message = message
      this.progress = progress
    }
    val state = state()
    for (channel in channels) runCatching { channel.send(state) }
  }

  @Command
  fun getState(invoke: Invoke) {
    invoke.resolve(state())
  }

  @Command
  fun subscribe(invoke: Invoke) {
    channels.add(invoke.parseArgs(UpdateSubscribeArgs::class.java).channel)
    invoke.resolve(state())
  }

  @Command
  fun configure(invoke: Invoke) {
    invoke.parseArgs(UpdateConfigureArgs::class.java).automatic?.let {
      preferences.edit().putBoolean("automatic", it).apply()
    }
    invoke.resolve(state())
    checkIfDue()
  }

  @Command
  fun check(invoke: Invoke) {
    if (status != "downloading" && status != "installing") check(manual = true)
    invoke.resolve(state())
  }

  private fun check(manual: Boolean) {
    update("checking", "")
    worker.execute {
      try {
        val found = newest()
        preferences.edit().putLong("lastChecked", System.currentTimeMillis()).apply()
        synchronized(this) { offer = found }
        if (found == null) {
          update("idle", "Shenzhen 3D is up to date.")
        } else {
          update("available", "${megabytes(found.size)} from GitHub. Android then asks you to confirm the update; your files and Friends stay as they are.")
        }
      } catch (error: Exception) {
        Log.w(TAG, "check failed", error)
        update(
          if (manual) "error" else "idle",
          if (manual) "Couldn’t reach GitHub to check for updates. Check your connection and try again." else ""
        )
      }
    }
  }

  private fun megabytes(bytes: Long) = String.format(java.util.Locale.ROOT, "%.1f MB", bytes / 1e6)

  /** The ABI part of the release's APK names: shenzhen-3d-0.2.0-android-arm64-development.apk. */
  private fun abiNames(): List<String> = Build.SUPPORTED_ABIS.flatMap {
    when (it) {
      "arm64-v8a" -> listOf("arm64", "aarch64")
      "armeabi-v7a" -> listOf("armv7", "arm")
      "x86_64" -> listOf("x86_64")
      "x86" -> listOf("x86", "i686")
      else -> emptyList()
    }
  }

  private fun open(url: String): HttpURLConnection {
    val connection = URL(url).openConnection() as HttpURLConnection
    connection.connectTimeout = 20_000
    connection.readTimeout = 30_000
    connection.instanceFollowRedirects = true
    connection.setRequestProperty("User-Agent", "Shenzhen-3D-Android/$installedVersion")
    return connection
  }

  private fun text(url: String, accept: String): String {
    val connection = open(url)
    connection.setRequestProperty("Accept", accept)
    try {
      if (connection.responseCode != 200) throw IllegalStateException("HTTP ${connection.responseCode}")
      return connection.inputStream.bufferedReader().use { it.readText() }
    } finally {
      connection.disconnect()
    }
  }

  /** The newest release above this version with an APK for this phone and its checksums; null when there is none. */
  private fun newest(): Offer? {
    val releases = JSONArray(text("${apiRoot()}/repos/$OWNER/$REPOSITORY/releases?per_page=30", "application/vnd.github+json"))
    val abis = abiNames()
    var best: Offer? = null
    for (index in 0 until releases.length()) {
      val release = releases.getJSONObject(index)
      if (release.optBoolean("draft")) continue
      val version = release.optString("tag_name").dropWhile { !it.isDigit() }
      if (version.isEmpty() || compareVersions(version, installedVersion) <= 0) continue
      if (best != null && compareVersions(version, best.version) <= 0) continue
      val assets = release.optJSONArray("assets") ?: continue
      var apk: Offer? = null
      var sums: String? = null
      for (a in 0 until assets.length()) {
        val asset = assets.getJSONObject(a)
        val name = asset.optString("name")
        val url = asset.optString("browser_download_url")
        if (name == SUMS) sums = url
        if (apk == null && name.endsWith(".apk") && abis.any { name.contains("-android-$it-") }) {
          apk = Offer(version, name, url, asset.optLong("size"), "")
        }
      }
      if (apk != null && sums != null) best = apk.copy(sumsUrl = sums)
    }
    return best
  }

  @Command
  fun download(invoke: Invoke) {
    val chosen = offer
    if (status == "ready" && verified != null) {
      invoke.resolve(state())
      return activity.runOnUiThread { install() }
    }
    if (status != "available" || chosen == null) return invoke.resolve(state())
    invoke.resolve(state())
    if (metered()) {
      activity.runOnUiThread {
        AlertDialog.Builder(activity)
          .setTitle("Download on a metered connection?")
          .setMessage("This update is ${megabytes(chosen.size)}. Your connection is marked as metered, so the download may count against your data plan.")
          .setPositiveButton("Download") { _, _ -> fetch(chosen) }
          .setNegativeButton("Not now", null)
          .show()
      }
    } else {
      fetch(chosen)
    }
  }

  @Command
  fun install(invoke: Invoke) {
    invoke.resolve(state())
    if (verified != null) activity.runOnUiThread { install() }
  }

  /** Download, check against SHA256SUMS.txt, then against this app's package, version and certificate. */
  private fun fetch(chosen: Offer) {
    update("downloading", "Downloading version ${chosen.version}…", 0.0)
    worker.execute {
      try {
        val expected = text(chosen.sumsUrl, "application/octet-stream").lineSequence()
          .map { it.trim().split(Regex("\\s+\\*?"), limit = 2) }
          .firstOrNull { it.size == 2 && it[1] == chosen.apkName }?.get(0)?.lowercase()
          ?: return@execute fail("This release lists no checksum for its Android app, so it wasn’t installed.")
        folder.deleteRecursively()
        folder.mkdirs()
        val file = File(folder, chosen.apkName)
        val digest = MessageDigest.getInstance("SHA-256")
        val connection = open(chosen.apkUrl)
        connection.setRequestProperty("Accept", "application/octet-stream")
        try {
          if (connection.responseCode != 200) return@execute fail("The download failed. Check your connection and try again.")
          val total = connection.contentLengthLong.takeIf { it > 0 } ?: chosen.size
          var done = 0L
          var shown = -1
          connection.inputStream.use { input ->
            file.outputStream().use { output ->
              val buffer = ByteArray(64 * 1024)
              while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                output.write(buffer, 0, read)
                digest.update(buffer, 0, read)
                done += read
                val percent = if (total > 0) (done * 100 / total).toInt() else 0
                if (percent != shown) {
                  shown = percent
                  update("downloading", "Downloading version ${chosen.version}…", percent.toDouble())
                }
              }
            }
          }
        } finally {
          connection.disconnect()
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (actual != expected) {
          file.delete()
          return@execute fail("The download didn’t match its published checksum, so it wasn’t installed. Try again.")
        }
        checkPackage(file)?.let {
          file.delete()
          return@execute fail(it)
        }
        synchronized(this) { verified = file }
        update("installing", "Checking…")
        activity.runOnUiThread { install() }
      } catch (error: Exception) {
        Log.w(TAG, "download failed", error)
        fail("The download failed. Check your connection and try again.")
      }
    }
  }

  private fun fail(why: String) {
    update("available", why)
  }

  @Suppress("DEPRECATION")
  private fun signatures(info: PackageInfo?): Set<String> {
    if (info == null) return emptySet()
    val signatures = if (Build.VERSION.SDK_INT >= 28) {
      info.signingInfo?.let { if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory }
    } else {
      info.signatures
    }
    return signatures.orEmpty().map { it.toCharsString() }.toSet()
  }

  /** Why Android would refuse this APK over the installed app, or null. Android checks again when it installs. */
  @Suppress("DEPRECATION")
  private fun checkPackage(file: File): String? {
    val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    val archive = context.packageManager.getPackageArchiveInfo(file.path, flags)
      ?: return "The download isn’t a valid Android app, so it wasn’t installed."
    if (archive.packageName != context.packageName) return "The download is a different app, so it wasn’t installed."
    val installed = packageInfo(flags)
    val newer = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode >= installed.longVersionCode
      else archive.versionCode >= installed.versionCode
    if (!newer) return "The download is older than the installed app, so it wasn’t installed."
    val ours = signatures(installed)
    if (ours.isEmpty() || signatures(archive).intersect(ours).isEmpty()) {
      return "The update is signed differently from the installed app, so Android won’t install it over this one."
    }
    return null
  }

  private fun canInstall(): Boolean =
    Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()

  /** On the main thread: the permission first, explained, then PackageInstaller. */
  private fun install() {
    val file = verified ?: return
    if (!canInstall()) {
      update("ready", "Shenzhen 3D needs your permission to install its updates.")
      AlertDialog.Builder(activity)
        .setTitle("Allow Shenzhen 3D to install updates")
        .setMessage(
          "Android asks you once to let Shenzhen 3D install its own updates. On the next screen, turn on " +
            "“Allow from this source”, then come back here to finish the update."
        )
        .setPositiveButton("Continue") { _, _ ->
          awaitingPermission = true
          val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
          try {
            activity.startActivity(intent)
          } catch (error: Exception) {
            // Some builds of Android have no per-app page: the list of apps instead.
            runCatching { activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)) }
          }
        }
        .setNegativeButton("Not now", null)
        .show()
      return
    }
    update("installing", "Confirm the update in Android’s dialog.")
    worker.execute {
      try {
        listen()
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(context.packageName)
        params.setSize(file.length())
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
          session.openWrite("shenzhen-3d.apk", 0, file.length()).use { output ->
            file.inputStream().use { it.copyTo(output) }
            session.fsync(output)
          }
          var flags = PendingIntent.FLAG_UPDATE_CURRENT
          if (Build.VERSION.SDK_INT >= 31) flags = flags or PendingIntent.FLAG_MUTABLE
          val status = Intent(statusAction()).setPackage(context.packageName)
          session.commit(PendingIntent.getBroadcast(context, id, status, flags).intentSender)
        }
      } catch (error: Exception) {
        Log.w(TAG, "install failed", error)
        update("ready", "The update couldn’t be installed. Tap Install update to try again.")
      }
    }
  }

  private fun statusAction() = "${context.packageName}.UPDATE_STATUS"

  private fun listen() {
    if (receiver != null) return
    val watcher = object : BroadcastReceiver() {
      override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
          PackageInstaller.STATUS_PENDING_USER_ACTION -> {
            @Suppress("DEPRECATION")
            val confirm = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
              else intent.getParcelableExtra(Intent.EXTRA_INTENT)
            if (confirm != null) activity.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
          }
          // Android stops this app to replace it; the new version starts when it is opened again.
          PackageInstaller.STATUS_SUCCESS -> update("installing", "Installing…")
          PackageInstaller.STATUS_FAILURE_ABORTED -> update("ready", "The update wasn’t installed. Tap Install update when you’re ready.")
          PackageInstaller.STATUS_FAILURE_CONFLICT, PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
            update("ready", "Android refused this update: it doesn’t fit the installed app.")
          else -> update("ready", "The update couldn’t be installed. Tap Install update to try again.")
        }
      }
    }
    ContextCompat.registerReceiver(context, watcher, IntentFilter(statusAction()), ContextCompat.RECEIVER_NOT_EXPORTED)
    receiver = watcher
  }
}
