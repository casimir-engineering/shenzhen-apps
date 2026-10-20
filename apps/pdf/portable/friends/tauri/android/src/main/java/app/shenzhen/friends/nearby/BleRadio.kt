// Bluetooth for the core (ADR 0004, ADR 0015 § 9): the radio the core's Bluetooth adapter drives. It advertises the
// Friends service (while visible, the public UUID first and the service UUID in the scan response: two 128-bit UUIDs
// do not fit one legacy advertisement),
// serves the presence characteristics from a GATT server, scans for the service, reads each device's values in one
// short connection, and listens and connects on LE L2CAP channels (Android 10 and later; before that it only finds
// people, and another route carries the session). It never turns the radio on or off.

package app.shenzhen.friends.nearby

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import app.tauri.plugin.Channel
import app.tauri.plugin.JSObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

private val SERVICE: UUID = UUID.fromString("22FB96F7-C35A-45B5-9673-1CAC64EC8E75")
private val PUBLIC: UUID = UUID.fromString("C8B26601-A773-4E6D-BC10-BA6F596D92C1")
private val PRESENCE_CHARACTERISTIC: UUID = UUID.fromString("9F2BC83C-9A97-49C4-9F30-19D368A135BA")
private val PUBLIC_CHARACTERISTIC: UUID = UUID.fromString("E66577A2-9C37-4D7B-876E-03127666B7DA")
/** Not read by anyone: it only holds handles (openServer). Its characteristics follow it, SPACER + 1, + 2, … */
private val SPACER: UUID = UUID.fromString("5A0E6F3D-6C1B-4C8E-9D27-3F1B2E8A4C00")
/** 24 characteristics: 49 handles, past a dead server's leftovers (8 on the phone where this was found). */
private const val SPACER_CHARACTERISTICS = 24

/** One line per radio event worth seeing in `adb logcat -s SZFriendsBle` (scripts/friends/ble-hardware-check.sh). */
private const val TAG = "SZFriendsBle"

@SuppressLint("MissingPermission") // Every call follows the person's grant: NearbyPlugin powers up only then.
class BleRadio(private val context: Context) {
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
    private val adapter: BluetoothAdapter? get() = manager?.adapter
    private val handler = Handler(Looper.getMainLooper())

    /** Whether this phone has Bluetooth LE at all. */
    val present: Boolean
        get() = context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) && adapter != null

    @Volatile private var channel: Channel? = null
    @Volatile private var presence = ByteArray(0)
    @Volatile private var publicValue: ByteArray? = null
    private var receiver: BroadcastReceiver? = null
    private var server: BluetoothGattServer? = null
    private var advertising: AdvertiseCallback? = null
    private var advertisedPublic = false
    private var scanning: ScanCallback? = null
    private val channels = ConcurrentHashMap<Int, BluetoothServerSocket>()
    /** When each device was last reported, and with which public flag: scans report devices many times a second. */
    private val reported = ConcurrentHashMap<String, Pair<Boolean, Long>>()

    private fun send(event: JSObject) {
        channel?.send(event)
    }

    fun reportPower(power: String) = send(JSObject().put("kind", "power").put("power", power))

    private fun power(): String = when {
        adapter == null -> "unsupported"
        adapter?.isEnabled == true -> "on"
        else -> "off"
    }

    @Synchronized
    fun attach(channel: Channel) {
        this.channel = channel
    }

    /** After the person's grant. Reports the radio's state now and whenever it changes. */
    @Synchronized
    fun powerUp() {
        if (receiver == null) {
            val watcher = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    val on = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, 0) == BluetoothAdapter.STATE_ON
                    val off = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, 0) == BluetoothAdapter.STATE_OFF
                    if (on) openServer()
                    if (on || off) {
                        if (off) forgetRadioSide()
                        reportPower(if (on) "on" else "off")
                    }
                }
            }
            context.registerReceiver(watcher, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
            receiver = watcher
        }
        if (power() == "on") openServer()
        reportPower(power())
    }

    @Synchronized
    fun powerDown() {
        forgetRadioSide()
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
        channel = null
    }

    @Synchronized
    private fun forgetRadioSide() {
        stopScanning()
        stopAdvertising()
        for (socket in channels.values) runCatching { socket.close() }
        channels.clear()
        server?.close()
        server = null
        Streams.closeAll()
    }

    @Synchronized
    private fun openServer() {
        if (server != null) return
        val callback = object : BluetoothGattServerCallback() {
            override fun onServiceAdded(status: Int, service: BluetoothGattService) {
                Log.i(TAG, "service ${service.uuid.toString().take(8)} at handle ${service.instanceId} status=$status")
                if (service.uuid == SPACER) synchronized(this@BleRadio) { server?.addService(friendsService()) }
            }

            override fun onCharacteristicReadRequest(
                device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic
            ) {
                val value = when (characteristic.uuid) {
                    PRESENCE_CHARACTERISTIC -> presence
                    PUBLIC_CHARACTERISTIC -> publicValue ?: ByteArray(0)
                    else -> ByteArray(0)
                }
                Log.i(TAG, "served ${characteristic.uuid.toString().take(8)} to ${device.address} offset=$offset size=${value.size}")
                val gatt = server ?: return
                if (offset > value.size) {
                    gatt.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                } else {
                    val rest = value.copyOfRange(offset, value.size)
                    gatt.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, rest)
                }
            }
        }
        val opened = manager?.openGattServer(context, callback) ?: return
        // The spacer goes first and the Friends service only once it is in (a server takes one service at a time).
        opened.addService(spacer())
        server = opened
    }

    /** The Friends service, added once the spacer is in. */
    private fun friendsService(): BluetoothGattService {
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        for (id in listOf(PRESENCE_CHARACTERISTIC, PUBLIC_CHARACTERISTIC)) {
            val read = BluetoothGattCharacteristic.PROPERTY_READ
            val readable = BluetoothGattCharacteristic.PERMISSION_READ
            service.addCharacteristic(BluetoothGattCharacteristic(id, read, readable))
        }
        return service
    }

    // Handles nobody may answer on. A GATT server that went away without the stack forgetting its handles (seen on
    // HyperOS 2 / Android 16: a dead server's four characteristics stayed in the stack's handle map) leaves them
    // behind at the end of the attribute table, exactly where the next service lands. Reads of the Friends values
    // then went to the dead server and were never answered, so no Mac could read this phone. The spacer takes those
    // handles, so the Friends service starts past them; readers look the Friends service up by its UUID.
    private fun spacer(): BluetoothGattService {
        val service = BluetoothGattService(SPACER, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        for (i in 1..SPACER_CHARACTERISTICS) {
            val id = UUID(SPACER.mostSignificantBits, SPACER.leastSignificantBits + i)
            service.addCharacteristic(
                BluetoothGattCharacteristic(id, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ)
            )
        }
        return service
    }

    @Synchronized
    fun startScanning() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        stopScanning()
        reported.clear()
        val callback = object : ScanCallback() {
            override fun onScanResult(type: Int, result: ScanResult) {
                val uuids = result.scanRecord?.serviceUuids.orEmpty()
                if (ParcelUuid(SERVICE) !in uuids && ParcelUuid(PUBLIC) !in uuids) return
                val public = ParcelUuid(PUBLIC) in uuids || moreUuidsElsewhere(result.scanRecord?.bytes)
                val address = result.device.address
                val now = System.currentTimeMillis()
                val last = reported[address]
                if (last != null && last.first == public && now - last.second < 10_000) return
                if (last == null || last.first != public) {
                    Log.i(TAG, "seen $address public=$public rssi=${result.rssi} record=${hex(result.scanRecord?.bytes)}")
                }
                reported[address] = Pair(public, now)
                send(JSObject().put("kind", "discovered").put("peripheral", address).put("public", public))
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "scan failed: $errorCode")
            }
        }
        // Either UUID: a visible phone puts the public UUID first and the service UUID in its scan response.
        val filters = listOf(SERVICE, PUBLIC).map { ScanFilter.Builder().setServiceUuid(ParcelUuid(it)).build() }
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build()
        scanner.startScan(filters, settings, callback)
        scanning = callback
        Log.i(TAG, "scanning")
    }

    @Synchronized
    fun stopScanning() {
        scanning?.let { callback -> runCatching { adapter?.bluetoothLeScanner?.stopScan(callback) } }
        scanning = null
    }

    /** Serves both values from now on; advertises again only when the public UUID comes or goes. */
    @Synchronized
    fun advertise(presence: ByteArray, publicValue: ByteArray?) {
        this.presence = presence
        this.publicValue = publicValue
        val public = publicValue != null
        if (advertising != null && advertisedPublic == public) return
        stopAdvertising()
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()
        // Two 128-bit UUIDs do not fit one legacy advertisement, so one goes in the scan response. While visible the
        // public UUID is the one in the advertisement: a Mac scanning without duplicates reports a device once, from
        // its first advertisement, and never saw a public UUID that came only in the scan response, so it never
        // listed a visible phone. Every Friends scanner looks for either UUID; the GATT service is the same.
        val (first, second) = if (public) PUBLIC to SERVICE else SERVICE to null
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(first)).setIncludeDeviceName(false).build()
        val response = AdvertiseData.Builder().apply { if (second != null) addServiceUuid(ParcelUuid(second)) }.build()
        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                Log.i(TAG, "advertising public=$public")
            }

            override fun onStartFailure(errorCode: Int) {
                Log.w(TAG, "advertising failed: $errorCode public=$public")
            }
        }
        advertiser.startAdvertising(settings, data, response, callback)
        advertising = callback
        advertisedPublic = public
    }

    @Synchronized
    fun stopAdvertising() {
        advertising?.let { callback -> runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(callback) } }
        advertising = null
    }

    /** A new L2CAP channel; Android 9 and older have none, which the core hears as psm 0. */
    fun publish(public: Boolean) {
        val radio = adapter
        if (Build.VERSION.SDK_INT < 29 || radio == null) {
            send(JSObject().put("kind", "published").put("psm", 0).put("public", public))
            return
        }
        Thread({
            val socket = runCatching { radio.listenUsingInsecureL2capChannel() }.getOrNull()
            val psm = socket?.psm ?: 0
            if (socket != null) channels[psm] = socket
            Log.i(TAG, "published psm=$psm public=$public")
            send(JSObject().put("kind", "published").put("psm", psm).put("public", public))
            val opened = channel
            while (socket != null && opened != null) {
                val accepted = runCatching { socket.accept() }.getOrNull() ?: break
                val id = Streams.add(accepted.inputStream, accepted.outputStream, accepted, opened)
                val peer = accepted.remoteDevice?.address
                Log.i(TAG, "accepted channel from $peer public=$public")
                send(JSObject().put("kind", "accepted").put("stream", id).put("public", public).put("peer", peer))
            }
        }, "szfriends-l2cap-listen").start()
    }

    fun unpublish(psm: Int) {
        channels.remove(psm)?.let { runCatching { it.close() } }
    }

    /** Both values in one short connection; nothing read is reported as a failed read. */
    fun read(peripheral: String, public: Boolean) {
        val device = runCatching { adapter?.getRemoteDevice(peripheral) }.getOrNull()
        if (device == null) {
            send(JSObject().put("kind", "read").put("peripheral", peripheral))
            return
        }
        var value: ByteArray? = null
        var publicRead: ByteArray? = null
        var done = false
        lateinit var gatt: BluetoothGatt
        fun finish() {
            synchronized(this) {
                if (done) return
                done = true
            }
            runCatching { gatt.disconnect() }
            runCatching { gatt.close() }
            Log.i(TAG, "read $peripheral value=${hex(value)} public=${hex(publicRead)}")
            send(
                JSObject().put("kind", "read").put("peripheral", peripheral).put("value", hex(value))
                    .put("publicValue", hex(publicRead))
            )
        }

        fun readNext(connected: BluetoothGatt) {
            val service = connected.getService(SERVICE) ?: return finish()
            // The public value is read even when the advertisement showed no public UUID: a Mac advertising both
            // UUIDs puts the second in Apple's overflow area, which only Apple devices decode. Its value is empty
            // while that device is not visible.
            val next = when {
                value == null -> service.getCharacteristic(PRESENCE_CHARACTERISTIC)
                publicRead == null -> service.getCharacteristic(PUBLIC_CHARACTERISTIC)
                else -> null
            } ?: return finish()
            if (!connected.readCharacteristic(next)) finish()
        }

        fun got(connected: BluetoothGatt, characteristic: BluetoothGattCharacteristic, bytes: ByteArray?, ok: Boolean) {
            if (!ok) return finish()
            if (characteristic.uuid == PRESENCE_CHARACTERISTIC) value = bytes ?: ByteArray(0)
            if (characteristic.uuid == PUBLIC_CHARACTERISTIC) publicRead = bytes ?: ByteArray(0)
            readNext(connected)
        }

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(connected: BluetoothGatt, status: Int, state: Int) {
                when (state) {
                    BluetoothProfile.STATE_CONNECTED -> if (!connected.discoverServices()) finish()
                    BluetoothProfile.STATE_DISCONNECTED -> finish()
                }
            }

            override fun onServicesDiscovered(connected: BluetoothGatt, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) readNext(connected) else finish()
            }

            override fun onCharacteristicRead(
                connected: BluetoothGatt, characteristic: BluetoothGattCharacteristic, bytes: ByteArray, status: Int
            ) = got(connected, characteristic, bytes, status == BluetoothGatt.GATT_SUCCESS)

            @Deprecated("Android 12 and older")
            @Suppress("DEPRECATION")
            override fun onCharacteristicRead(
                connected: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int
            ) = got(connected, characteristic, characteristic.value, status == BluetoothGatt.GATT_SUCCESS)
        }
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE) ?: run {
            send(JSObject().put("kind", "read").put("peripheral", peripheral))
            return
        }
        handler.postDelayed({ finish() }, 10_000)
    }

    /**
     * The channel a dial asked for, reported as opened with a stream or with none.
     *
     * The channel rides on a GATT connection that has read the Friends value first and stays up while the channel
     * lives. A Mac accepts an L2CAP channel only from a central its Friends service has already served on that link:
     * a bare connection to the PSM is rejected ("Could not find a session, endpoint or pipe"), which is what every
     * dial from a phone to a Mac got. Apple centrals never notice, because they always touch the GATT database
     * themselves when they connect.
     */
    fun open(peripheral: String, psm: Int, dial: Long) {
        val radio = adapter
        val device = runCatching { radio?.getRemoteDevice(peripheral) }.getOrNull()
        if (Build.VERSION.SDK_INT < 29 || radio == null || device == null) {
            send(JSObject().put("kind", "opened").put("dial", dial))
            return
        }
        var settled = false
        var gatt: BluetoothGatt? = null
        fun closeGatt() {
            runCatching { gatt?.disconnect() }
            runCatching { gatt?.close() }
        }
        fun fail(why: String) {
            synchronized(this) {
                if (settled) return
                settled = true
            }
            Log.i(TAG, "open $peripheral psm=$psm failed: $why")
            closeGatt()
            send(JSObject().put("kind", "opened").put("dial", dial))
        }
        fun connectChannel() = Thread({
            val opened = channel
            // The Mac sets up its side of the link (it reads this phone's GATT database) right after the first read;
            // a channel asked for before that is refused like one with no GATT at all. So wait, and try once more.
            var socket: Result<BluetoothSocket> = Result.failure(IllegalStateException("not tried"))
            for (attempt in 1..3) {
                Thread.sleep(if (attempt == 1) 1_500L else 2_000L)
                if (settled) break
                socket = runCatching { device.createInsecureL2capChannel(psm).apply { connect() } }
                Log.i(TAG, "open $peripheral psm=$psm attempt $attempt: ${socket.exceptionOrNull()?.message ?: "ok"}")
                if (socket.isSuccess) break
            }
            val connected = socket.getOrNull()
            synchronized(this) {
                if (settled || connected == null || opened == null) {
                    runCatching { connected?.close() }
                    if (!settled) {
                        settled = true
                        closeGatt()
                        Log.i(TAG, "open $peripheral psm=$psm failed: ${socket.exceptionOrNull()?.message}")
                        send(JSObject().put("kind", "opened").put("dial", dial))
                    }
                    return@Thread
                }
                settled = true
            }
            val link = connected ?: return@Thread
            val reports = opened ?: return@Thread
            Log.i(TAG, "open $peripheral psm=$psm ok")
            val owner = java.io.Closeable {
                runCatching { link.close() }
                closeGatt()
            }
            val id = Streams.add(link.inputStream, link.outputStream, owner, reports)
            send(JSObject().put("kind", "opened").put("dial", dial).put("stream", id))
        }, "szfriends-l2cap-open").start()

        var started = false
        fun startChannelOnce() {
            synchronized(this) {
                if (started || settled) return
                started = true
            }
            connectChannel()
        }
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(connected: BluetoothGatt, status: Int, state: Int) {
                when (state) {
                    BluetoothProfile.STATE_CONNECTED -> if (!connected.discoverServices()) startChannelOnce()
                    BluetoothProfile.STATE_DISCONNECTED -> fail("disconnected (status $status)")
                }
            }

            override fun onServicesDiscovered(connected: BluetoothGatt, status: Int) {
                val presence = connected.getService(SERVICE)?.getCharacteristic(PRESENCE_CHARACTERISTIC)
                if (presence == null || !connected.readCharacteristic(presence)) startChannelOnce()
            }

            override fun onCharacteristicRead(
                connected: BluetoothGatt, characteristic: BluetoothGattCharacteristic, bytes: ByteArray, status: Int
            ) = startChannelOnce()

            @Deprecated("Android 12 and older")
            override fun onCharacteristicRead(
                connected: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int
            ) = startChannelOnce()
        }
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        if (gatt == null) return fail("no GATT connection")
        handler.postDelayed({ if (!started) fail("timed out") }, 10_000)
    }
}
