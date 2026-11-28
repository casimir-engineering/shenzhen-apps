// The Bluetooth links the L2CAP channels run on (BleRadio), made fast while they carry bytes: the connection interval
// each one gets and the LE 2M PHY, and a log line for what the stack granted (`adb logcat -s SZFriendsBle`).

package app.shenzhen.friends.nearby

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Handler
import android.util.Log
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "SZFriendsBle"

/** A link this long without a byte either way goes back to the balanced interval. */
private const val IDLE_MILLIS = 3_000L

/** Whether log lines may name devices by their Bluetooth address: debuggable (test) builds only. */
@Volatile
private var namesDevices = false

/** A random salt per run, so a release build's log names a device the same way within one run and never across runs. */
private val salt = java.util.UUID.randomUUID().toString()

/**
 * A device as log lines name it: its address in a debuggable build, else a short hash of it, so a release build's
 * logcat never holds a Bluetooth address.
 */
internal fun logName(address: String?): String {
    if (address == null) return "?"
    if (namesDevices) return address
    val digest = MessageDigest.getInstance("SHA-256").digest((salt + address).toByteArray())
    return "device-" + digest.take(3).joinToString("") { "%02x".format(it) }
}

@SuppressLint("MissingPermission") // Only on channels BleRadio opened, after the person's grant.
internal class BleLinkSpeed(private val context: Context, private val handler: Handler) {
    init {
        namesDevices = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    /** Each link's connection interval as the stack last reported it (1.25 ms units), by device address. */
    private val intervals = ConcurrentHashMap<String, Int>()

    /** Exactly this interval (BluetoothGatt.requestLeConnectionUpdate, hidden; `false` or a failure where refused). */
    private fun askInterval(gatt: BluetoothGatt, units: Int): Result<Boolean> = runCatching {
        val update = BluetoothGatt::class.java.getMethod(
            "requestLeConnectionUpdate", Int::class.java, Int::class.java, Int::class.java, Int::class.java,
            Int::class.java, Int::class.java
        )
        update.invoke(gatt, units, units, 0, 500, 0, 0) as Boolean
    }

    /**
     * BluetoothGattCallback.onConnectionUpdated, hidden from the SDK but called on every callback: declared on ours
     * (not an override as far as the compiler knows) to learn the interval a link really got.
     */
    fun noteInterval(gatt: BluetoothGatt, interval: Int, latency: Int, status: Int) {
        val address = gatt.device?.address ?: return
        intervals[address] = interval
        Log.i(TAG, "link ${logName(address)}: interval ${interval * 1.25} ms, latency $latency (status $status)")
    }

    /**
     * One channel's link: fast while bytes move ([moved]), balanced again after [IDLE_MILLIS] without any, so an open
     * channel waiting for the next message does not keep the radio waking every few milliseconds. Closed with the
     * channel.
     *
     * The interval is what limits a Mac and a phone: a Mac sends or takes about 1.8 KB per connection event whatever
     * the interval, so 30 ms (a Mac's own choice as central, and Android's balanced priority) moved about 60 KB/s and
     * 15 ms twice that. CONNECTION_PRIORITY_HIGH asks for 11.25 to 15 ms, which a Mac as central refuses (Apple
     * accepts an interval range starting at 15 ms, or exactly 15 ms), so the link stayed at 30 ms whenever the Mac
     * had dialled. So the exact interval is asked for where the platform lets an app: 7.5 ms while this phone is the
     * central (it decides), exactly 15 ms while the Mac is; CONNECTION_PRIORITY_HIGH where it does not.
     */
    inner class Link(private val why: String, private val central: Boolean, private val address: String?) :
        java.io.Closeable {
        @Volatile private var gatt: BluetoothGatt? = null
        /** What else ends with the link (an accepted link's own GATT client). */
        @Volatile var alsoClose: (() -> Unit)? = null
        @Volatile private var lastMoved = 0L
        @Volatile private var ended = false
        private val fast = AtomicBoolean(false)
        private val idleCheck = Runnable { checkIdle() }

        /** The GATT connection the link is asked through, once it is up: the LE 2M PHY at once, the interval on use. */
        fun attach(connected: BluetoothGatt, socket: BluetoothSocket) {
            if (ended) return
            gatt = connected
            if (Build.VERSION.SDK_INT >= 26) {
                runCatching {
                    connected.setPreferredPhy(
                        BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_OPTION_NO_PREFERRED
                    )
                }
            }
            val sizes = if (Build.VERSION.SDK_INT >= 29) {
                runCatching { "tx ${socket.maxTransmitPacketSize} rx ${socket.maxReceivePacketSize}" }.getOrDefault("?")
            } else "?"
            Log.i(TAG, "link $why: packets $sizes")
            if (fast.get()) handler.post { askFast() }
        }

        /** Bytes went either way: cheap, called for every read and write. */
        fun moved() {
            lastMoved = System.nanoTime()
            if (!ended && fast.compareAndSet(false, true)) {
                handler.post {
                    askFast()
                    handler.postDelayed(idleCheck, IDLE_MILLIS)
                }
            }
        }

        private fun checkIdle() {
            if (ended) return
            val idle = (System.nanoTime() - lastMoved) / 1_000_000
            if (idle < IDLE_MILLIS) {
                handler.postDelayed(idleCheck, IDLE_MILLIS - idle)
                return
            }
            fast.set(false)
            val connected = gatt ?: return
            val balanced = runCatching { connected.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_BALANCED) }
            Log.i(TAG, "link $why: idle, balanced priority ${balanced.getOrNull()}")
        }

        private fun askFast() {
            val connected = gatt ?: return
            if (ended || !fast.get()) return
            val units = if (central) 6 else 12 // 1.25 ms each
            val exact = askInterval(connected, units)
            // "Central" is a guess: a dial rides on a link the Mac made (reading this phone) when one is up. A Mac as
            // central refuses 7.5 ms, so if the link is not at 15 ms or less soon, ask for exactly 15 ms.
            if (exact.getOrNull() == true && units < 12) {
                handler.postDelayed({
                    val now = address?.let { intervals[it] }
                    if (!ended && fast.get() && (now == null || now > 12)) {
                        val again = askInterval(connected, 12)
                        Log.i(TAG, "link $why: interval ${now?.let { it * 1.25 }} ms, asked for 15 ms: ${again.getOrNull()}")
                    }
                }, 3_000)
            }
            val asked = if (exact.getOrNull() == true) {
                "interval ${units * 1.25} ms"
            } else {
                val priority = runCatching { connected.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH) }
                "high priority ${priority.getOrNull()} (exact interval: ${exact.exceptionOrNull()?.javaClass?.simpleName ?: exact.getOrNull()})"
            }
            Log.i(TAG, "link $why: bytes moving, $asked")
        }

        /** The channel ended: nothing more is asked, and the link's interval is forgotten. */
        override fun close() {
            ended = true
            handler.removeCallbacks(idleCheck)
            address?.let { intervals.remove(it) }
            alsoClose?.invoke()
        }
    }

    /** The link of a channel this phone opened as central, on the GATT connection it dialled through. */
    fun dialled(gatt: BluetoothGatt?, socket: BluetoothSocket, address: String, why: String): Link =
        Link(why, central = true, address).also { link -> gatt?.let { link.attach(it, socket) } }

    /** A GATT client on the link the friend's central made, only to ask for the interval; closed with the channel. */
    @SuppressLint("MissingPermission")
    fun accepted(accepted: BluetoothSocket): Link {
        val device = accepted.remoteDevice
        val name = logName(device?.address)
        val link = Link("accepted from $name", central = false, device?.address)
        if (device == null) return link
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(connected: BluetoothGatt, status: Int, state: Int) {
                if (state == BluetoothProfile.STATE_CONNECTED) link.attach(connected, accepted)
            }

            override fun onPhyUpdate(connected: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
                Log.i(TAG, "link accepted from $name: PHY tx $txPhy rx $rxPhy (status $status)")
            }

            @Suppress("unused") // called by the platform (noteInterval)
            fun onConnectionUpdated(connected: BluetoothGatt, interval: Int, latency: Int, timeout: Int, status: Int) =
                noteInterval(connected, interval, latency, status)
        }
        val gatt = runCatching { device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE) }.getOrNull()
        link.alsoClose = { runCatching { gatt?.close() } }
        return link
    }
}
