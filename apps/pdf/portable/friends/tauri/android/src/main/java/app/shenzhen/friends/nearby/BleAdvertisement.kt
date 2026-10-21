// What BleRadio reads of a scan result and writes to the log (ADR 0004, ADR 0015 § 9): hex for logs and the core's
// values, and the advertisement's list of 128-bit service UUIDs.

package app.shenzhen.friends.nearby

internal fun hex(bytes: ByteArray?): String? = bytes?.joinToString("") { "%02x".format(it) }

/**
 * Whether the advertisement says its list of 128-bit service UUIDs is incomplete (AD type 0x06). A Mac advertising the
 * Friends service and the public UUID gets only the first into the advertisement; macOS puts the second in Apple's
 * overflow area, which only Apple devices can read, and marks the list incomplete. The only UUID Friends ever adds is
 * the public one, so an incomplete list is a visible Mac. A wrong guess costs one read, whose public value comes back
 * empty.
 */
internal fun moreUuidsElsewhere(record: ByteArray?): Boolean {
    var at = 0
    while (record != null && at < record.size) {
        val length = record[at].toInt() and 0xff
        if (length == 0 || at + length >= record.size) return false
        if (record[at + 1].toInt() == 0x06) return true
        at += length + 1
    }
    return false
}
