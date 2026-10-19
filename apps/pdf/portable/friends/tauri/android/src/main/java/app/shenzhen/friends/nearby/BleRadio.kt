// Bluetooth for the core (ADR 0004, ADR 0015 § 9): the radio the core's Bluetooth adapter drives. It advertises the
// Friends service (the public UUID in the scan response: two 128-bit UUIDs do not fit one legacy advertisement),
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
import app.tauri.plugin.Channel
import app.tauri.plugin.JSObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

private val SERVICE: UUID = UUID.fromString("22FB96F7-C35A-45B5-9673-1CAC64EC8E75")
private val PUBLIC: UUID = UUID.fromString("C8B26601-A773-4E6D-BC10-BA6F596D92C1")
private val PRESENCE_CHARACTERISTIC: UUID = UUID.fromString("9F2BC83C-9A97-49C4-9F30-19D368A135BA")
private val PUBLIC_CHARACTERISTIC: UUID = UUID.fromString("E66577A2-9C37-4D7B-876E-03127666B7DA")

private fun hex(bytes: ByteArray?): String? = bytes?.joinToString("") { "%02x".format(it) }

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
            override fun onCharacteristicReadRequest(
                device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic
            ) {
                val value = when (characteristic.uuid) {
                    PRESENCE_CHARACTERISTIC -> presence
                    PUBLIC_CHARACTERISTIC -> publicValue ?: ByteArray(0)
                    else -> ByteArray(0)
                }
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
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        for (id in listOf(PRESENCE_CHARACTERISTIC, PUBLIC_CHARACTERISTIC)) {
            val read = BluetoothGattCharacteristic.PROPERTY_READ
            val readable = BluetoothGattCharacteristic.PERMISSION_READ
            service.addCharacteristic(BluetoothGattCharacteristic(id, read, readable))
        }
        opened.addService(service)
        server = opened
    }

    @Synchronized
    fun startScanning() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        stopScanning()
        reported.clear()
        val callback = object : ScanCallback() {
            override fun onScanResult(type: Int, result: ScanResult) {
                val uuids = result.scanRecord?.serviceUuids.orEmpty()
                if (ParcelUuid(SERVICE) !in uuids) return
                val public = ParcelUuid(PUBLIC) in uuids
                val address = result.device.address
                val now = System.currentTimeMillis()
                val last = reported[address]
                if (last != null && last.first == public && now - last.second < 10_000) return
                reported[address] = Pair(public, now)
                send(JSObject().put("kind", "discovered").put("peripheral", address).put("public", public))
            }
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build()
        scanner.startScan(filters, settings, callback)
        scanning = callback
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
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).build()
        val response = AdvertiseData.Builder().apply { if (public) addServiceUuid(ParcelUuid(PUBLIC)) }.build()
        val callback = object : AdvertiseCallback() {}
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
            send(JSObject().put("kind", "published").put("psm", psm).put("public", public))
            val opened = channel
            while (socket != null && opened != null) {
                val accepted = runCatching { socket.accept() }.getOrNull() ?: break
                val id = Streams.add(accepted.inputStream, accepted.outputStream, accepted, opened)
                val peer = accepted.remoteDevice?.address
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
            send(
                JSObject().put("kind", "read").put("peripheral", peripheral).put("value", hex(value))
                    .put("publicValue", hex(publicRead))
            )
        }

        fun readNext(connected: BluetoothGatt) {
            val service = connected.getService(SERVICE) ?: return finish()
            val next = when {
                value == null -> service.getCharacteristic(PRESENCE_CHARACTERISTIC)
                public && publicRead == null -> service.getCharacteristic(PUBLIC_CHARACTERISTIC)
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

    /** The channel a dial asked for, reported as opened with a stream or with none. */
    fun open(peripheral: String, psm: Int, dial: Long) {
        val radio = adapter
        if (Build.VERSION.SDK_INT < 29 || radio == null) {
            send(JSObject().put("kind", "opened").put("dial", dial))
            return
        }
        Thread({
            val opened = channel
            val socket = runCatching {
                radio.getRemoteDevice(peripheral).createInsecureL2capChannel(psm).apply { connect() }
            }.getOrNull()
            if (socket == null || opened == null) {
                runCatching { socket?.close() }
                send(JSObject().put("kind", "opened").put("dial", dial))
            } else {
                val id = Streams.add(socket.inputStream, socket.outputStream, socket, opened)
                send(JSObject().put("kind", "opened").put("dial", dial).put("stream", id))
            }
        }, "szfriends-l2cap-open").start()
    }
}
