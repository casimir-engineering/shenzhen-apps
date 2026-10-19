// DNS-SD for the core with Android's NsdManager (ADR 0015 § 9): registers the core's own listeners and resolves what
// it browses, then reports addresses and TXT for the core to dial. Before Android 14 NsdManager resolves one service
// at a time (a second resolve fails with FAILURE_ALREADY_ACTIVE), so resolves wait in a queue, newest sighting first,
// each with a timeout; from 14 a service-info callback follows each instance instead. A multicast lock is held while
// browsing, since many devices drop multicast without one.

package app.shenzhen.friends.nearby

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import app.tauri.plugin.Channel
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.Executors

class NsdDiscovery(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager?
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    private val registrations = HashMap<String, NsdManager.RegistrationListener>()
    /** The names our entries actually got (NsdManager renames on a conflict): never reported as someone else. */
    private val own = HashSet<String>()
    private var channel: Channel? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var lock: WifiManager.MulticastLock? = null

    // Before Android 14: one resolve at a time.
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving: String? = null
    // From Android 14: one callback per instance.
    private val followed = HashMap<String, NsdManager.ServiceInfoCallback>()

    private fun send(event: JSObject) {
        channel?.send(event)
    }

    @Synchronized
    fun register(serviceType: String, name: String, port: Int, txt: List<List<String>>) {
        registrations.remove(name)?.let { runCatching { nsd.unregisterService(it) } }
        val info = NsdServiceInfo().apply {
            serviceName = name
            this.serviceType = serviceType
            this.port = port
            for (pair in txt) if (pair.size == 2) setAttribute(pair[0], pair[1])
        }
        own.add(name)
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(registered: NsdServiceInfo) {
                synchronized(this@NsdDiscovery) { own.add(registered.serviceName) }
            }

            override fun onRegistrationFailed(failed: NsdServiceInfo, code: Int) {}
            override fun onServiceUnregistered(gone: NsdServiceInfo) {}
            override fun onUnregistrationFailed(gone: NsdServiceInfo, code: Int) {}
        }
        registrations[name] = listener
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    @Synchronized
    fun unregister(name: String) {
        registrations.remove(name)?.let { runCatching { nsd.unregisterService(it) } }
    }

    @Synchronized
    fun browse(serviceType: String, channel: Channel) {
        stopBrowsing()
        this.channel = channel
        lock = wifi?.createMulticastLock("szfriends-nearby")?.apply {
            setReferenceCounted(false)
            acquire()
        }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) = send(JSObject().put("kind", "ready"))
            override fun onStartDiscoveryFailed(type: String, code: Int) =
                send(JSObject().put("kind", "failed").put("why", "discovery failed: $code"))

            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onServiceFound(info: NsdServiceInfo) = found(info)
            override fun onServiceLost(info: NsdServiceInfo) = lost(info.serviceName)
        }
        discovery = listener
        nsd.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    @Synchronized
    private fun found(info: NsdServiceInfo) {
        val name = info.serviceName
        if (name in own) return
        if (Build.VERSION.SDK_INT >= 34) {
            if (followed.containsKey(name)) return
            val callback = object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(code: Int) {}
                override fun onServiceUpdated(updated: NsdServiceInfo) = report(updated)
                override fun onServiceLost() = lost(name)
                override fun onServiceInfoCallbackUnregistered() {}
            }
            followed[name] = callback
            nsd.registerServiceInfoCallback(info, executor, callback)
            return
        }
        queue.removeAll { it.serviceName == name }
        queue.addFirst(info)
        pump()
    }

    /** One resolve at a time, newest sighting first, each given up after ten seconds. */
    @Synchronized
    private fun pump() {
        if (resolving != null) return
        val info = queue.removeFirstOrNull() ?: return
        val name = info.serviceName
        resolving = name
        @Suppress("DEPRECATION")
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onServiceResolved(resolved: NsdServiceInfo) {
                report(resolved)
                resolved(name)
            }

            override fun onResolveFailed(failed: NsdServiceInfo, code: Int) = resolved(name)
        })
        handler.postDelayed({ resolved(name) }, 10_000)
    }

    @Synchronized
    private fun resolved(name: String) {
        if (resolving != name) return
        resolving = null
        pump()
    }

    private fun address(host: InetAddress, port: Int): String {
        if (host is Inet6Address) {
            val bare = host.hostAddress?.substringBefore('%') ?: return ""
            val scope = if (host.scopeId != 0) "%${host.scopeId}" else ""
            return "[$bare$scope]:$port"
        }
        return "${host.hostAddress}:$port"
    }

    private fun report(info: NsdServiceInfo) {
        val hosts: List<InetAddress> = if (Build.VERSION.SDK_INT >= 34) {
            info.hostAddresses
        } else {
            @Suppress("DEPRECATION")
            listOfNotNull(info.host)
        }
        val addresses = JSArray()
        for (host in hosts) address(host, info.port).takeIf { it.isNotEmpty() }?.let { addresses.put(it) }
        val txt = JSArray()
        for ((key, value) in info.attributes) {
            txt.put(JSArray().apply {
                put(key)
                put((value ?: ByteArray(0)).joinToString("") { "%02x".format(it) })
            })
        }
        send(JSObject().put("kind", "found").put("name", info.serviceName).put("addresses", addresses).put("txt", txt))
    }

    @Synchronized
    private fun lost(name: String) {
        queue.removeAll { it.serviceName == name }
        if (Build.VERSION.SDK_INT >= 34) {
            followed.remove(name)?.let { runCatching { nsd.unregisterServiceInfoCallback(it) } }
        }
        send(JSObject().put("kind", "lost").put("name", name))
    }

    @Synchronized
    private fun stopBrowsing() {
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        queue.clear()
        resolving = null
        if (Build.VERSION.SDK_INT >= 34) {
            for (callback in followed.values) runCatching { nsd.unregisterServiceInfoCallback(callback) }
        }
        followed.clear()
        lock?.let { if (it.isHeld) it.release() }
        lock = null
    }

    /** Ends browsing and every registration. */
    @Synchronized
    fun stop() {
        stopBrowsing()
        for (listener in registrations.values) runCatching { nsd.unregisterService(listener) }
        registrations.clear()
        channel = null
    }
}
