// Byte streams the core reads and writes through the plugin (an L2CAP channel's socket): each has an id, its bytes
// go to the core on the channel that opened or accepted it, base64-encoded, and the end follows the last of them.

package app.shenzhen.friends.nearby

import android.util.Base64
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
    private class Open(val output: OutputStream, val closeable: Closeable, val writer: ExecutorService)

    private val next = AtomicLong(1)
    private val open = ConcurrentHashMap<Long, Open>()

    /** Starts reading at once; returns the id the core names the stream by. */
    fun add(input: InputStream, output: OutputStream, closeable: Closeable, channel: Channel): Long {
        val id = next.getAndIncrement()
        open[id] = Open(output, closeable, Executors.newSingleThreadExecutor())
        Thread({
            val buffer = ByteArray(65_536)
            try {
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
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

    /** In order, off the caller's thread: the core's writer never waits on the radio. */
    fun write(id: Long, data: ByteArray) {
        val stream = open[id] ?: return
        stream.writer.execute {
            try {
                stream.output.write(data)
                stream.output.flush()
            } catch (_: Exception) {
                close(id)
            }
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
