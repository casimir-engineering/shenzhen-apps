// Byte streams the core reads and writes through the plugin (an L2CAP channel's socket): each has an id, its bytes
// go to the core on the channel that opened or accepted it, base64-encoded, and the end follows the last of them.

package app.shenzhen.friends.nearby

import android.util.Base64
import android.util.Log
import app.tauri.plugin.Channel
import app.tauri.plugin.JSObject
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

object Streams {
    private class Open(val output: OutputStream, val closeable: Closeable, val writer: ExecutorService) {
        val meter = Meter()
    }

    /**
     * What a stream moved, one logcat line (SZFriendsBle) per 2 s while it moves: how fast the radio takes and gives
     * bytes, and how long a write waited for room in the socket.
     */
    private class Meter {
        private var since = System.nanoTime()
        private var wrote = 0L
        private var read = 0L
        private var reads = 0
        private var waitedNanos = 0L

        @Synchronized
        fun note(id: Long, written: Int = 0, got: Int = 0, waited: Long = 0) {
            wrote += written
            read += got
            if (got > 0) reads++
            waitedNanos += waited
            val now = System.nanoTime()
            val seconds = (now - since) / 1e9
            if (seconds < 2) return
            if (wrote > 0 || read > 0) {
                Log.i(
                    "SZFriendsBle",
                    "stream $id: wrote %.1f KB/s (writes waited %.0f ms), read %.1f KB/s in %d reads over %.1f s".format(
                        wrote / 1e3 / seconds, waitedNanos / 1e6, read / 1e3 / seconds, reads, seconds
                    )
                )
            }
            since = now
            wrote = 0
            read = 0
            reads = 0
            waitedNanos = 0
        }
    }

    private val next = AtomicLong(1)
    private val open = ConcurrentHashMap<Long, Open>()

    /** Starts reading at once; returns the id the core names the stream by. */
    fun add(input: InputStream, output: OutputStream, closeable: Closeable, channel: Channel): Long {
        val id = next.getAndIncrement()
        val opened = Open(output, closeable, Executors.newSingleThreadExecutor())
        open[id] = opened
        Thread({
            val buffer = ByteArray(65_536)
            try {
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
                    opened.meter.note(id, got = count)
                    val data = Base64.encodeToString(buffer, 0, count, Base64.NO_WRAP)
                    channel.send(JSObject().put("kind", "bytes").put("stream", id).put("data", data))
                }
            } catch (_: Exception) {
            }
            channel.send(JSObject().put("kind", "closed").put("stream", id))
            close(id)
        }, "szfriends-stream-$id").start()
        return id
    }

    /**
     * In order, off the caller's thread, and `done` once the bytes are in the socket (or the stream failed). The core
     * counts a write as gone only then: its writer hands over the next one after `done`, so what waits for the radio
     * waits in the core, where a message can still overtake file data. Done at once, a write let the core push
     * megabytes into this queue at memory speed, and every message behind them (a HAVE, an ask) waited minutes on a
     * Bluetooth link.
     */
    fun write(id: Long, data: ByteArray, done: () -> Unit) {
        val stream = open[id] ?: return done()
        try {
            stream.writer.execute {
                try {
                    val started = System.nanoTime()
                    stream.output.write(data)
                    stream.output.flush()
                    stream.meter.note(id, written = data.size, waited = System.nanoTime() - started)
                } catch (_: Exception) {
                    close(id)
                } finally {
                    done()
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            done() // closed meanwhile
        }
    }

    /** After everything already written. */
    fun close(id: Long) {
        val stream = open.remove(id) ?: return
        stream.writer.execute {
            try {
                stream.output.flush()
            } catch (_: Exception) {
            }
            try {
                stream.closeable.close()
            } catch (_: Exception) {
            }
        }
        stream.writer.shutdown()
    }

    fun closeAll() {
        for (id in open.keys.toList()) close(id)
    }
}
