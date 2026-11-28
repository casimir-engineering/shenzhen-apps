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

/** About half a second of a fast link (BleLinkSpeed.shrinkSendBuffer). */
private const val SEND_BUFFER_BYTES = 64 * 1024

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
     * A small send buffer under a channel's socket. What the core writes waits there for the radio, beyond the core's
     * reach: with the default (hundreds of KB), a phone sending a file pushed seconds of data ahead of its own asks and
     * HAVEs. The core keeps its messages ahead of file data in its own queues, so the less waits here, the sooner they
     * go. BluetoothSocket has no setter: its socket is reached by reflection where the platform allows it, and left
     * alone where not. Answers what was set, or why not.
     */
    private fun shrinkSendBuffer(socket: BluetoothSocket): String = runCatching {
        val field = BluetoothSocket::class.java.getDeclaredField("mSocket")
        field.isAccessible = true
        val local = field.get(socket) as android.net.LocalSocket
        val before = local.sendBufferSize
        local.sendBufferSize = SEND_BUFFER_BYTES
        "$before -> ${local.sendBufferSize}"
    }.getOrElse { it.javaClass.simpleName }

    /**
     * One channel's link: fast while bytes move ([moved]), balanced again after [IDLE_MILLIS] without any, so an open
     * channel waiting for the next message does not keep the radio waking every few milliseconds. Closed with the
     * channel.
     *
     * The central decides the interval. CONNECTION_PRIORITY_HIGH asks for 11.25 to 15 ms: on a link this phone dialled
     * it gets 15 ms; on one a Mac dialled the Mac refuses it (Apple accepts only ranges from 15 ms up) and keeps 30 ms.
     * Measured 2026-11-28 (a POCO F7 and a MacBook Pro): 85 to 98 KB/s each way on a link this phone dialled, 20 to
     * 57 KB/s on one the Mac dialled, so a Mac waits for an Android phone to dial it (the Mac's +PhoneDials).
     * BluetoothGatt.requestLeConnectionUpdate, which could ask a Mac for exactly 15 ms, is not there for apps on this
     * phone (NoSuchMethodException).
     */
    inner class Link(private val why: String, private val address: String?) :
        java.io.Closeable {
        @Volatile private var gatt: BluetoothGatt? = null
        /** What else ends with the link (an accepted link's own GATT client). */
        @Volatile var alsoClose: (() -> Unit)? = null
        @Volatile private var lastMoved = 0L
        @Volatile private var ended = false
        private val fast = AtomicBoolean(false)
        private val idleCheck = Runnable { checkIdle() }

        /**
         * The GATT connection the link is asked through, once it is up: the LE 2M PHY at once, the interval on use.
         * [mtuAsked]: this phone already asked for the MTU on it, before the channel opened.
         */
        fun attach(connected: BluetoothGatt, socket: BluetoothSocket, mtuAsked: Boolean = false) {
            if (ended) return
            gatt = connected
            if (!mtuAsked) preferFastPhy(connected)
            // The ATT MTU exchange is what makes Android lengthen this side's LE packets (Data Length Extension, 27 to
            // 251 bytes): the L2CAP channel alone never does. Without it a link this phone dialled sent the Mac 27-byte
            // packets, and the phone's data crossed at 9 to 26 KB/s while the Mac's came back at 85 (bluetoothd: "Rx
            // [27 -> 27]" on the phone's link, 2026-11-28). A Mac that dials asks for the MTU itself.
            val mtu = if (mtuAsked) "before the channel" else runCatching { connected.requestMtu(517) }.getOrNull()
            val buffer = shrinkSendBuffer(socket)
            val sizes = if (Build.VERSION.SDK_INT >= 29) {
                runCatching { "tx ${socket.maxTransmitPacketSize} rx ${socket.maxReceivePacketSize}" }.getOrDefault("?")
            } else "?"
            Log.i(TAG, "link $why: MTU asked $mtu, send buffer $buffer, packets $sizes")
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
            val priority = runCatching { connected.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH) }
            Log.i(TAG, "link $why: bytes moving, high priority ${priority.getOrNull()}")
        }

        /** The channel ended: nothing more is asked, and the link's interval is forgotten. */
        override fun close() {
            ended = true
            handler.removeCallbacks(idleCheck)
            address?.let { intervals.remove(it) }
            alsoClose?.invoke()
        }
    }

    /** The LE 2M PHY both ways, asked once a GATT connection is up. */
    fun preferFastPhy(connected: BluetoothGatt) {
        if (Build.VERSION.SDK_INT < 26) return
        runCatching {
            connected.setPreferredPhy(
                BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_OPTION_NO_PREFERRED
            )
        }
    }

    /** The link of a channel this phone opened as central, on the GATT connection it dialled through. */
    fun dialled(gatt: BluetoothGatt?, socket: BluetoothSocket, address: String, why: String, mtuAsked: Boolean): Link =
        Link(why, address).also { link -> gatt?.let { link.attach(it, socket, mtuAsked) } }

    /** A GATT client on the link the friend's central made, only to ask for the interval; closed with the channel. */
    @SuppressLint("MissingPermission")
    fun accepted(accepted: BluetoothSocket): Link {
        val device = accepted.remoteDevice
        val name = logName(device?.address)
        val link = Link("accepted from $name", device?.address)
        if (device == null) return link
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(connected: BluetoothGatt, status: Int, state: Int) {
                if (state == BluetoothProfile.STATE_CONNECTED) link.attach(connected, accepted)
            }

            override fun onPhyUpdate(connected: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
                Log.i(TAG, "link accepted from $name: PHY tx $txPhy rx $rxPhy (status $status)")
            }

            override fun onMtuChanged(connected: BluetoothGatt, mtu: Int, status: Int) {
                Log.i(TAG, "link accepted from $name: MTU $mtu (status $status)")
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
