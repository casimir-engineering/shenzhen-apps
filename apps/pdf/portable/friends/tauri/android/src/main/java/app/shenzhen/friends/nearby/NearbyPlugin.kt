// The plugin's Android side (tauri/src/nearby.rs): the commands the core calls, which return at once, and the
// channels on which NsdDiscovery and BleRadio report. Commands run on the core's thread, so none of them waits.
// FriendsPlugin extends this class: Tauri keeps one Kotlin plugin per Tauri plugin, so the key store, sharing and
// Nearby answer as one (registered as FriendsPlugin, src/phone/native.rs).
//
// Permissions (ADR 0015 § 10) are asked only when the core powers Bluetooth up, which it does when the person opens
// Friends or taps Allow (or at launch once they allowed it): scanning, advertising and connecting from Android 12,
// location for scanning on Android 11 and earlier. The system's dialog answers through the plugin manager's result
// launcher. A refusal the system may still ask about again reads as not yet asked, so Nearby keeps its Allow; once the
// system stops showing the dialog, the refusal is for good and Nearby offers the app's settings page instead. The
// system then answers within a moment (Android 16 still opens and closes its transparent permission activity, so the
// app does pause), faster than anyone can read a dialog and refuse. That test does not rely on
// shouldShowRequestPermissionRationale, which HyperOS and MIUI always answer false. Network discovery (NsdManager)
// needs no runtime permission.
//
// POST_NOTIFICATIONS (Android 13 and later, ADR 0017) goes out in the same request, so the person meets one moment of
// questions, not two. A phone that allowed Bluetooth before notifications came asks for it alone, once, the next time
// Nearby starts; after that only Settings' Allow asks (askNotifications).

package app.shenzhen.friends.nearby

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Channel
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import app.tauri.plugin.PluginManager
import app.shenzhen.friends.notify.Notifications

@InvokeArg
class RegisterArgs {
    var serviceType: String = ""
    var name: String = ""
    var port: Int = 0
    var txt: List<List<String>> = emptyList()
}

@InvokeArg
class NameArgs {
    var name: String = ""
}

@InvokeArg
class BrowseArgs {
    var serviceType: String = ""
    lateinit var channel: Channel
}

@InvokeArg
class ChannelArgs {
    lateinit var channel: Channel
}

@InvokeArg
class AdvertiseArgs {
    var presence: String = ""
    var public: String? = null
}

@InvokeArg
class PublishArgs {
    var public: Boolean = false
}

@InvokeArg
class PsmArgs {
    var psm: Int = 0
}

@InvokeArg
class PeripheralArgs {
    var peripheral: String = ""
    var public: Boolean = false
}

@InvokeArg
class OpenArgs {
    var peripheral: String = ""
    var psm: Int = 0
    var dial: Long = 0
}

@InvokeArg
class LinkArgs {
    var network: String = ""
    var passphrase: String = ""
}

@InvokeArg
class StreamArgs {
    var stream: Long = 0
    var data: String = ""
}

private fun bytes(hex: String): ByteArray =
    ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

/** Set once the system answered a request without showing its dialog: only the app's settings page can allow it now. */
private const val REFUSED = "bluetooth_refused_for_good"
/** An answer sooner than this after the request came without a dialog anyone could have read. */
private const val NO_DIALOG_MS = 700L

@TauriPlugin
open class NearbyPlugin(private val activity: Activity) : Plugin(activity) {
    private val nsd = NsdDiscovery(activity.applicationContext)
    private val radio = BleRadio(activity.applicationContext)
    private val directWifi = DirectWifi(activity.applicationContext)
    private val handler = Handler(Looper.getMainLooper())
    /** A request is out, since when, and whether the app paused for it (a dialog, or the activity that would show one). */
    @Volatile private var asking = false
    @Volatile private var askedAt = 0L
    @Volatile private var dialogShown = false
    /** What the request out asks for: Bluetooth's permissions, POST_NOTIFICATIONS, or both. */
    @Volatile private var askingBluetooth = false
    @Volatile private var askingNotifications = false
    /** Bluetooth was reported unauthorized to an attached core: a grant from Settings powers it up on return. */
    @Volatile private var blocked = false

    private val preferences = activity.applicationContext.getSharedPreferences("szfriends_nearby", Context.MODE_PRIVATE)

    /** What Bluetooth needs on this version of Android. */
    private fun needed(): Array<String> = when {
        Build.VERSION.SDK_INT >= 31 -> arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT
        )
        else -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun granted(): Boolean = needed().all {
        ContextCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED
    }

    @Command
    fun nearbyCapabilities(invoke: Invoke) {
        invoke.resolve(JSObject().put("ownsConnections", false).put("bluetooth", radio.present))
    }

    // ----- the Wi-Fi Direct boost (ADR 0019, DirectWifi.kt) -----

    @Command
    fun directWifiAbilities(invoke: Invoke) {
        val available = directWifi.available()
        val keeps = available && directWifi.keepsWifi()
        invoke.resolve(
            JSObject().put("supported", directWifi.supported()).put("host", available).put("join", available)
                .put("hostKeepsWifi", keeps).put("joinKeepsWifi", keeps).put("systemAsks", false)
        )
    }

    @Command
    fun directWifiConnectivity(invoke: Invoke) {
        val (onWifi, mobile, wired) = directWifi.connectivity()
        // The network's name needs location on Android: never read. "wifi" only says there is one to come back to.
        invoke.resolve(
            JSObject().put("onWifi", onWifi).put("mobile", mobile).put("wired", wired)
                .put("network", if (onWifi) "wifi" else null)
        )
    }

    @Command
    fun directWifiHost(invoke: Invoke) {
        val args = invoke.parseArgs(LinkArgs::class.java)
        handler.post {
            directWifi.host(args.network, args.passphrase) { address, why ->
                if (address != null) invoke.resolve(JSObject().put("address", address)) else invoke.reject(why ?: "failed")
            }
        }
    }

    @Command
    fun directWifiStopHosting(invoke: Invoke) {
        handler.post { directWifi.leave { invoke.resolve() } }
    }

    @Command
    fun directWifiJoin(invoke: Invoke) {
        val args = invoke.parseArgs(LinkArgs::class.java)
        handler.post { directWifi.join(args.network, args.passphrase) { invoke.resolve(JSObject().put("joined", it)) } }
    }

    /** Leaves a joined group: the phone's own Wi-Fi stayed (or the system rejoins its saved network by itself). */
    @Command
    fun directWifiRejoin(invoke: Invoke) {
        handler.post { directWifi.leave { invoke.resolve(JSObject().put("ok", true)) } }
    }

    @Command
    fun directWifiOnline(invoke: Invoke) {
        invoke.resolve(JSObject().put("online", directWifi.online()))
    }

    @Command
    fun nearbyRegister(invoke: Invoke) {
        val args = invoke.parseArgs(RegisterArgs::class.java)
        try {
            nsd.register(args.serviceType, args.name, args.port, args.txt)
            invoke.resolve()
        } catch (error: Exception) {
            invoke.reject(error.message ?: "registration failed")
        }
    }

    @Command
    fun nearbyUnregister(invoke: Invoke) {
        nsd.unregister(invoke.parseArgs(NameArgs::class.java).name)
        invoke.resolve()
    }

    @Command
    fun nearbyWithdraw(invoke: Invoke) {
        nsd.unregister(invoke.parseArgs(NameArgs::class.java).name)
        invoke.resolve()
    }

    @Command
    fun nearbyBrowse(invoke: Invoke) {
        val args = invoke.parseArgs(BrowseArgs::class.java)
        try {
            nsd.browse(args.serviceType, args.channel)
            invoke.resolve()
        } catch (error: Exception) {
            invoke.reject(error.message ?: "browsing failed")
        }
    }

    @Command
    fun nearbyStop(invoke: Invoke) {
        nsd.stop()
        invoke.resolve()
    }

    @Command
    fun nearbyConnect(invoke: Invoke) {
        // The core dials Android's instances itself.
        invoke.reject("not supported")
    }

    private fun refusedForGood(): Boolean = preferences.getBoolean(REFUSED, false)

    /** Read without asking: allowed; denied for good (Settings only); or not determined, when the system may still ask. */
    @Command
    fun radioPermission(invoke: Invoke) {
        val state = when {
            !radio.present -> "unknown"
            granted() -> "allowed"
            refusedForGood() -> "denied"
            else -> "notDetermined"
        }
        invoke.resolve(JSObject().put("permission", state))
    }

    @Command
    fun radioPowerUp(invoke: Invoke) {
        radio.attach(invoke.parseArgs(ChannelArgs::class.java).channel)
        invoke.resolve()
        if (!radio.present) return radio.reportPower("unsupported")
        if (granted()) {
            powerUp()
            if (Notifications.wantedOnceAlone(activity)) activity.runOnUiThread { ask(bluetooth = false, notifications = true) }
            return
        }
        if (refusedForGood()) return refuse()
        radio.reportPower("unknown")
        activity.runOnUiThread { ask(bluetooth = true, notifications = Notifications.wanted(activity)) }
    }

    /** Settings' Allow for notifications (`allow_notifications`): the system's dialog, while it may still show it. */
    protected fun askNotifications(): Boolean {
        if (!Notifications.wanted(activity)) return false
        activity.runOnUiThread { ask(bluetooth = false, notifications = true) }
        return true
    }

    private fun powerUp() {
        blocked = false
        preferences.edit().remove(REFUSED).apply()
        radio.powerUp()
    }

    private fun refuse() {
        blocked = true
        radio.reportPower("unauthorized")
    }

    /** The system's dialog, on the main thread. */
    private fun ask(bluetooth: Boolean, notifications: Boolean) {
        if (asking) return
        asking = true
        askingBluetooth = bluetooth
        askingNotifications = notifications
        askedAt = SystemClock.elapsedRealtime()
        dialogShown = false
        // Wi-Fi Direct's permission (ADR 0019) belongs to the same "Nearby devices" permission as Bluetooth's on
        // Android 13 and later, so it rides along; granted() still asks only about Bluetooth.
        val wifiDirect = if (bluetooth && Build.VERSION.SDK_INT >= 33) {
            arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            emptyArray()
        }
        val permissions = (if (bluetooth) needed() + wifiDirect else emptyArray()) +
            (if (notifications) arrayOf(Manifest.permission.POST_NOTIFICATIONS) else emptyArray())
        if (notifications) Notifications.markAsked(activity)
        try {
            PluginManager.requestPermissions(permissions) { handler.post { answered() } }
        } catch (error: Exception) {
            asking = false
            if (bluetooth) refuse()
        }
    }

    override fun onPause(activity: AppCompatActivity) {
        if (asking) dialogShown = true
    }

    override fun onResume(activity: AppCompatActivity) {
        // Back from the dialog, should its answer have gone astray; or back from Settings with access granted there.
        if (asking && dialogShown) handler.postDelayed({ if (asking) answered() }, 1_000)
        if (blocked && !asking && granted()) powerUp()
        // Back from Settings, where notifications may have been turned on or off.
        if (!asking) Notifications.report(activity)
    }

    private fun answered() {
        if (!asking) return
        asking = false
        // No dialog, or none anyone could have read: the system refused by itself, as it does once the person refused
        // for good.
        val noDialog = !dialogShown || SystemClock.elapsedRealtime() - askedAt < NO_DIALOG_MS
        if (askingNotifications) Notifications.answered(activity, alone = !askingBluetooth, noDialog = noDialog)
        if (!askingBluetooth) return
        if (granted()) return powerUp()
        if (noDialog) {
            preferences.edit().putBoolean(REFUSED, true).apply()
        }
        refuse()
    }

    @Command
    fun radioPowerDown(invoke: Invoke) {
        blocked = false
        radio.powerDown()
        invoke.resolve()
    }

    @Command
    fun radioStartScanning(invoke: Invoke) {
        radio.startScanning()
        invoke.resolve()
    }

    @Command
    fun radioStopScanning(invoke: Invoke) {
        radio.stopScanning()
        invoke.resolve()
    }

    @Command
    fun radioAdvertise(invoke: Invoke) {
        val args = invoke.parseArgs(AdvertiseArgs::class.java)
        radio.advertise(bytes(args.presence), args.public?.let(::bytes))
        invoke.resolve()
    }

    @Command
    fun radioStopAdvertising(invoke: Invoke) {
        radio.stopAdvertising()
        invoke.resolve()
    }

    @Command
    fun radioPublish(invoke: Invoke) {
        radio.publish(invoke.parseArgs(PublishArgs::class.java).public)
        invoke.resolve()
    }

    @Command
    fun radioUnpublish(invoke: Invoke) {
        radio.unpublish(invoke.parseArgs(PsmArgs::class.java).psm)
        invoke.resolve()
    }

    @Command
    fun radioRead(invoke: Invoke) {
        val args = invoke.parseArgs(PeripheralArgs::class.java)
        radio.read(args.peripheral, args.public)
        invoke.resolve()
    }

    @Command
    fun radioOpen(invoke: Invoke) {
        val args = invoke.parseArgs(OpenArgs::class.java)
        radio.open(args.peripheral, args.psm, args.dial)
        invoke.resolve()
    }

    @Command
    fun streamWrite(invoke: Invoke) {
        val args = invoke.parseArgs(StreamArgs::class.java)
        Streams.write(args.stream, Base64.decode(args.data, Base64.NO_WRAP))
        invoke.resolve()
    }

    @Command
    fun streamClose(invoke: Invoke) {
        Streams.close(invoke.parseArgs(StreamArgs::class.java).stream)
        invoke.resolve()
    }
}
