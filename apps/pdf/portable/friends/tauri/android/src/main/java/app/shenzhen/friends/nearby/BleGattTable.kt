// The attribute table the Friends GATT server serves (BleRadio): the Friends service with its two values, and a spacer
// added before it so the service never lands on a dead server's leftover handles.

package app.shenzhen.friends.nearby

import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattService
import java.util.UUID

internal val SERVICE: UUID = UUID.fromString("22FB96F7-C35A-45B5-9673-1CAC64EC8E75")
internal val PUBLIC: UUID = UUID.fromString("C8B26601-A773-4E6D-BC10-BA6F596D92C1")
internal val PRESENCE_CHARACTERISTIC: UUID = UUID.fromString("9F2BC83C-9A97-49C4-9F30-19D368A135BA")
internal val PUBLIC_CHARACTERISTIC: UUID = UUID.fromString("E66577A2-9C37-4D7B-876E-03127666B7DA")
/** Not read by anyone: it only holds handles (openServer). Its characteristics follow it, SPACER + 1, + 2, … */
internal val SPACER: UUID = UUID.fromString("5A0E6F3D-6C1B-4C8E-9D27-3F1B2E8A4C00")
/** 24 characteristics: 49 handles, past a dead server's leftovers (8 on the phone where this was found). */
internal const val SPACER_CHARACTERISTICS = 24

/** The Friends service, added once the spacer is in. */
internal fun friendsService(): BluetoothGattService {
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
internal fun spacerService(): BluetoothGattService {
    val service = BluetoothGattService(SPACER, BluetoothGattService.SERVICE_TYPE_PRIMARY)
    for (i in 1..SPACER_CHARACTERISTICS) {
        val id = UUID(SPACER.mostSignificantBits, SPACER.leastSignificantBits + i)
        service.addCharacteristic(
            BluetoothGattCharacteristic(id, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ)
        )
    }
    return service
}
