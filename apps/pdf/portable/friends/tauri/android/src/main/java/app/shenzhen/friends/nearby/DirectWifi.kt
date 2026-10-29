// The Wi-Fi Direct boost on Android (ADR 0019; the core's side is szfriends-helper's nearby/direct_wifi.rs, bridged
// in tauri/src/nearby.rs). The phone hosts a Wi-Fi Direct group under the name and passphrase the core made for this
// one boost (a Mac or an iPhone joins it as an ordinary WPA2 network; the group owner is 192.168.49.1), or joins
// another phone's group as a Wi-Fi Direct client. Both run beside the phone's own Wi-Fi connection on hardware that
// runs station and Wi-Fi Direct at once; where that is not known, the core counts the phone's Wi-Fi as lost, so a
// phone with no mobile data asks first.
//
// Android 13 and later only: NEARBY_WIFI_DEVICES, which belongs to the same "Nearby devices" permission as
// Bluetooth's and is asked with them. Android 10 to 12 would need precise location for Wi-Fi Direct, which Friends
// never asks for, so the boost is not offered there. The network's name is never read (that needs location too):
// the question says "your Wi-Fi".
//
// Every call answers once, from the main thread's callbacks or a short poll; none blocks the core's thread.

package app.shenzhen.friends.nearby

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat

/** Set once this phone kept its Wi-Fi validated while hosting a group. */
private const val KEPT_WIFI = "direct_wifi_kept_wifi"

class DirectWifi(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val p2p: WifiP2pManager? = context.getSystemService(WifiP2pManager::class.java)
    private val wifi: WifiManager? = context.getSystemService(WifiManager::class.java)
    private val connectivity: ConnectivityManager? = context.getSystemService(ConnectivityManager::class.java)
    private var channel: WifiP2pManager.Channel? = null

    /** This phone could host and join (Android 13 and later, with Wi-Fi Direct). */
    fun supported(): Boolean =
        Build.VERSION.SDK_INT >= 33 && p2p != null &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)

    /** Hosting and joining are possible here and allowed. */
    fun available(): Boolean =
        supported() &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.NEARBY_WIFI_DEVICES) ==
            PackageManager.PERMISSION_GRANTED

    private val preferences = context.getSharedPreferences("szfriends_nearby", Context.MODE_PRIVATE)

    /**
     * Whether the phone keeps its own Wi-Fi beside a group. Android has no public answer for station plus Wi-Fi
     * Direct: hardware that runs station plus access point at once (Android 11's question) does both, and a phone
     * that kept its Wi-Fi validated while it last hosted is known to (the emulator does, without the first). Unsure
     * means no, so the core treats the phone's Wi-Fi as lost (ADR 0019 § 3).
     */
    fun keepsWifi(): Boolean =
        preferences.getBoolean(KEPT_WIFI, false) ||
            (Build.VERSION.SDK_INT >= 30 && (wifi?.isStaApConcurrencySupported ?: false))

    /** On Wi-Fi with Internet now (checked while hosting: what keepsWifi() learns from). */
    private fun wifiValidated(): Boolean {
        val manager = connectivity ?: return false
        @Suppress("DEPRECATION")
        return manager.allNetworks.any { network ->
            val caps = manager.getNetworkCapabilities(network)
            caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }
    }

    /** On Wi-Fi, on mobile data, on a cable: any network that reaches the Internet. */
    fun connectivity(): Triple<Boolean, Boolean, Boolean> {
        val manager = connectivity ?: return Triple(false, false, false)
        var onWifi = false
        var mobile = false
        var wired = false
        @Suppress("DEPRECATION")
        for (network in manager.allNetworks) {
            val caps = manager.getNetworkCapabilities(network) ?: continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) onWifi = true
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) mobile = true
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) wired = true
        }
        return Triple(onWifi, mobile, wired)
    }

    /** The default network reaches the Internet (validated by the system: no traffic of ours). */
    fun online(): Boolean {
        val manager = connectivity ?: return false
        val caps = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    private fun channel(): WifiP2pManager.Channel? {
        val manager = p2p ?: return null
        return channel ?: manager.initialize(context, Looper.getMainLooper(), null).also { channel = it }
    }

    /** Hosts a group named `network` with `passphrase`; answers with the group owner's address, or why not. */
    @SuppressLint("MissingPermission")
    fun host(network: String, passphrase: String, done: (String?, String?) -> Unit) {
        val manager = p2p
        val channel = channel()
        if (!available() || manager == null || channel == null) return done(null, "unavailable")
        val config = WifiP2pConfig.Builder()
            .setNetworkName(network)
            .setPassphrase(passphrase)
            .enablePersistentMode(false)
            .setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_AUTO)
            .build()
        // A group left over from an earlier boost would refuse the new one.
        manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = create()
            override fun onFailure(reason: Int) = create()
            fun create() = manager.createGroup(channel, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = waitForGroup(manager, channel, owner = true, tries = 40) { address, why ->
                    if (address != null && wifiValidated()) preferences.edit().putBoolean(KEPT_WIFI, true).apply()
                    done(address, why)
                }
                override fun onFailure(reason: Int) = done(null, "createGroup failed: $reason")
            })
        })
    }

    /** Joins the group named `network` as a Wi-Fi Direct client (another phone hosts it). */
    @SuppressLint("MissingPermission")
    fun join(network: String, passphrase: String, done: (Boolean) -> Unit) {
        val manager = p2p
        val channel = channel()
        if (!available() || manager == null || channel == null) return done(false)
        val config = WifiP2pConfig.Builder().setNetworkName(network).setPassphrase(passphrase).build()
        manager.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = waitForGroup(manager, channel, owner = false, tries = 60) { address, _ ->
                done(address != null)
            }
            override fun onFailure(reason: Int) = done(false)
        })
    }

    /** Polls every half second until the group formed with this phone in the expected role. */
    @SuppressLint("MissingPermission")
    private fun waitForGroup(
        manager: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        owner: Boolean,
        tries: Int,
        done: (String?, String?) -> Unit,
    ) {
        manager.requestConnectionInfo(channel) { info ->
            val address = info?.groupOwnerAddress?.hostAddress
            when {
                info != null && info.groupFormed && info.isGroupOwner == owner && address != null -> done(address, null)
                tries <= 0 -> done(null, "the group did not form")
                else -> handler.postDelayed({ waitForGroup(manager, channel, owner, tries - 1, done) }, 500)
            }
        }
    }

    /** Takes the group down: hosted, or joined as a client. The phone's own Wi-Fi never left (or comes back). */
    fun leave(done: () -> Unit) {
        val manager = p2p
        val channel = channel
        if (manager == null || channel == null) return done()
        manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = done()
            override fun onFailure(reason: Int) = done()
        })
    }
}
