// The plugin's Android side (tauri/src/nearby.rs): the commands the core calls, which return at once, and the
// channels on which NsdDiscovery and BleRadio report. Commands run on the core's thread, so none of them waits.
//
// Permissions (ADR 0015 § 10) are asked only when the core powers Bluetooth up, which it does when the person opens
// Friends (or at launch once they allowed it): scanning, advertising and connecting from Android 12, location for
// scanning on Android 10 and 11. The answer arrives when the app resumes after the system's dialog; a refusal is
// reported as the radio being unauthorized, which the Nearby page explains. Network discovery needs no runtime
// permission.

package app.shenzhen.friends.nearby

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Channel
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin

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
class StreamArgs {
    var stream: Long = 0
    var data: String = ""
}

private fun bytes(hex: String): ByteArray =
    ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

private const val PERMISSION_REQUEST = 0x5a46
private const val ASKED = "bluetooth_asked"

@TauriPlugin
class NearbyPlugin(private val activity: Activity) : Plugin(activity) {
    private val nsd = NsdDiscovery(activity.applicationContext)
    private val radio = BleRadio(activity.applicationContext)
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var waitingForGrant = false

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

    /** Read without asking: allowed, denied (asked before and refused), or not yet asked. */
    @Command
    fun radioPermission(invoke: Invoke) {
        val state = when {
            !radio.present -> "unknown"
            granted() -> "allowed"
            preferences.getBoolean(ASKED, false) -> "denied"
            else -> "notDetermined"
        }
        invoke.resolve(JSObject().put("permission", state))
    }

    @Command
    fun radioPowerUp(invoke: Invoke) {
        radio.attach(invoke.parseArgs(ChannelArgs::class.java).channel)
        invoke.resolve()
        if (!radio.present) return radio.reportPower("unsupported")
        if (granted()) return radio.powerUp()
        val refusedForGood = preferences.getBoolean(ASKED, false) &&
            needed().none { ActivityCompat.shouldShowRequestPermissionRationale(activity, it) }
        if (refusedForGood) return radio.reportPower("unauthorized")
        preferences.edit().putBoolean(ASKED, true).apply()
        waitingForGrant = true
        radio.reportPower("unknown")
        activity.runOnUiThread { ActivityCompat.requestPermissions(activity, needed(), PERMISSION_REQUEST) }
        // Should no dialog come up at all, the answer is read anyway.
        handler.postDelayed({ answered() }, 30_000)
    }

    override fun onResume(activity: AppCompatActivity) {
        answered()
    }

    private fun answered() {
        if (!waitingForGrant) return
        waitingForGrant = false
        if (granted()) radio.powerUp() else radio.reportPower("unauthorized")
    }

    @Command
    fun radioPowerDown(invoke: Invoke) {
        waitingForGrant = false
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
