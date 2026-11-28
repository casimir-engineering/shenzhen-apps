// The Bluetooth links the L2CAP channels run on (BleRadio), made fast: the connection interval each one gets and the
// LE 2M PHY, and a log line for what the stack granted (`adb logcat -s SZFriendsBle`).

package app.shenzhen.friends.nearby

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Build
import android.os.Handler
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "SZFriendsBle"

@SuppressLint("MissingPermission") // Only on channels BleRadio opened, after the person's grant.
internal class BleLinkSpeed(private val context: Context, private val handler: Handler) {
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
        Log.i(TAG, "link $address: interval ${interval * 1.25} ms, latency $latency (status $status)")
    }

    /**
     * The link a channel runs on, made fast: a short connection interval and the LE 2M PHY where both radios have it
     * (ADR 0018 § 9.8). Only the link's own parameters change: nothing on the wire.
     *
     * The interval is what limits a Mac and a phone: a Mac sends or takes about 1.8 KB per connection event whatever
     * the interval, so 30 ms (a Mac's own choice as central, and Android's balanced priority) moved about 60 KB/s and
     * 15 ms twice that. CONNECTION_PRIORITY_HIGH asks for 11.25 to 15 ms, which a Mac as central refuses (Apple
     * accepts an interval range starting at 15 ms, or exactly 15 ms), so the link stayed at 30 ms whenever the Mac
     * had dialled. So the exact interval is asked for where the platform lets an app: 7.5 ms while this phone is the
     * central (it decides), exactly 15 ms while the Mac is; CONNECTION_PRIORITY_HIGH where it does not.
     */
    fun speedUp(gatt: BluetoothGatt, socket: BluetoothSocket, why: String, central: Boolean) {
        val units = if (central) 6 else 12 // 1.25 ms each
        val exact = askInterval(gatt, units)
        // "Central" is a guess: a dial rides on a link the Mac made (reading this phone) when one is up. A Mac as central
        // refuses 7.5 ms, so if the link is not at 15 ms or less soon, ask for exactly 15 ms.
        if (exact.getOrNull() == true && units < 12) {
            val address = gatt.device?.address
            handler.postDelayed({
                val now = address?.let { intervals[it] }
                if (now == null || now > 12) {
                    val again = askInterval(gatt, 12)
                    Log.i(TAG, "link $why: interval ${now?.let { it * 1.25 }} ms, asked for 15 ms: ${again.getOrNull()}")
                }
            }, 3_000)
        }
        val asked = if (exact.getOrNull() == true) {
            "interval ${units * 1.25} ms"
        } else {
            val priority = runCatching { gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH) }
            "high priority ${priority.getOrNull()} (exact interval: ${exact.exceptionOrNull()?.javaClass?.simpleName ?: exact.getOrNull()})"
        }
        if (Build.VERSION.SDK_INT >= 26) {
            runCatching {
                gatt.setPreferredPhy(
                    BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_OPTION_NO_PREFERRED
                )
            }
        }
        val sizes = if (Build.VERSION.SDK_INT >= 29) {
            runCatching { "tx ${socket.maxTransmitPacketSize} rx ${socket.maxReceivePacketSize}" }.getOrDefault("?")
        } else "?"
        Log.i(TAG, "link $why: $asked, packets $sizes")
    }

    /** A GATT client on the link the friend's central made, only to ask for [speedUp]; closed with the channel. */
    @SuppressLint("MissingPermission")
    fun speedUpAccepted(accepted: BluetoothSocket): java.io.Closeable {
        val device = accepted.remoteDevice ?: return java.io.Closeable {}
        var gatt: BluetoothGatt? = null
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(connected: BluetoothGatt, status: Int, state: Int) {
                if (state == BluetoothProfile.STATE_CONNECTED) speedUp(connected, accepted, "accepted from ${device.address}", central = false)
            }

            override fun onPhyUpdate(connected: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
                Log.i(TAG, "link accepted from ${device.address}: PHY tx $txPhy rx $rxPhy (status $status)")
            }

            @Suppress("unused") // called by the platform (noteInterval)
            fun onConnectionUpdated(connected: BluetoothGatt, interval: Int, latency: Int, timeout: Int, status: Int) =
                noteInterval(connected, interval, latency, status)
        }
        gatt = runCatching { device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE) }.getOrNull()
        return java.io.Closeable { runCatching { gatt?.close() } }
    }
}
