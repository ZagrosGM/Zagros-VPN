package ai.zagros.tunnel.l2tp

import java.nio.ByteBuffer

/**
 * L2TPv2 (RFC 2661) wire encoding for the Zagros raw-L2TP engine.
 *
 * Original Zagros code (propreitary) implementing the public RFC 2661
 * datagram format; interop target is the SoftEther L2TP listener validated
 * in Phase 1 (xl2tpd 1.3.16 reference client).
 */
internal const val L2TP_MESSAGE_SCCRQ: Short = 1
internal const val L2TP_MESSAGE_SCCRP: Short = 2
internal const val L2TP_MESSAGE_SCCCN: Short = 3
internal const val L2TP_MESSAGE_STOPCCN: Short = 4
internal const val L2TP_MESSAGE_HELLO: Short = 6
// RFC 2661 §3.2.2/3.2.3: client-placed calls use the INCOMING call sequence
// (10/11/12) — 7/8/9 are the LNS-initiated OUTGOING call messages and are
// rejected by SoftEther's L2TP listener.
internal const val L2TP_MESSAGE_ICRQ: Short = 10
internal const val L2TP_MESSAGE_ICRP: Short = 11
internal const val L2TP_MESSAGE_ICCN: Short = 12
internal const val L2TP_MESSAGE_CDN: Short = 10

internal const val L2TP_AVP_MESSAGE_TYPE: Short = 0
internal const val L2TP_AVP_RESULT_CODE: Short = 1
internal const val L2TP_AVP_PROTOCOL_VERSION: Short = 2
internal const val L2TP_AVP_FRAMING_CAPABILITIES: Short = 3
internal const val L2TP_AVP_HOST_NAME: Short = 7
internal const val L2TP_AVP_VENDOR_NAME: Short = 8
internal const val L2TP_AVP_ASSIGNED_TUNNEL_ID: Short = 9
internal const val L2TP_AVP_RECEIVE_WINDOW: Short = 10
internal const val L2TP_AVP_ASSIGNED_SESSION_ID: Short = 14
internal const val L2TP_AVP_CALL_SERIAL_NUMBER: Short = 15
internal const val L2TP_AVP_TX_CONNECT_SPEED: Short = 16
internal const val L2TP_AVP_FRAMING_TYPE: Short = 17

private const val FLAG_TYPE = 0x8000
private const val FLAG_LENGTH = 0x4000
private const val FLAG_SEQUENCE = 0x0800
private const val FLAG_OFFSET = 0x0200
private const val VERSION_L2TP = 0x0002

internal class L2tpAvp(val type: Short, val value: ByteArray) {
    internal val encodedSize: Int
        get() = 6 + value.size

    internal fun write(buffer: ByteBuffer) {
        buffer.putShort((0x8000 or value.size + 6).toShort()) // mandatory, not hidden
        buffer.putShort(0) // vendor id
        buffer.putShort(type)
        buffer.put(value)
    }

    internal companion object {
        internal fun u16(type: Short, value: Int): L2tpAvp =
            L2tpAvp(type, ByteBuffer.allocate(2).putShort(value.toShort()).array())

        internal fun u32(type: Short, value: Int): L2tpAvp =
            L2tpAvp(type, ByteBuffer.allocate(4).putInt(value).array())

        internal fun bytes(type: Short, value: ByteArray): L2tpAvp = L2tpAvp(type, value)

        internal fun ascii(type: Short, value: String): L2tpAvp =
            L2tpAvp(type, value.toByteArray(Charsets.US_ASCII))
    }
}

internal class L2tpPacket(
    val isControl: Boolean,
    var tunnelId: Int = 0,
    var sessionId: Int = 0,
    var ns: Int = 0,
    var nr: Int = 0,
    val avps: ArrayList<L2tpAvp> = ArrayList(),
    var payload: ByteArray? = null,
) {
    internal val messageType: Short
        get() = avps.firstOrNull { it.type == L2TP_AVP_MESSAGE_TYPE }
            ?.let { ByteBuffer.wrap(it.value).short } ?: -1

    internal fun avpU16(type: Short): Int? =
        avps.firstOrNull { it.type == type }?.let { ByteBuffer.wrap(it.value).short.toInt() and 0xFFFF }

    internal fun avpBytes(type: Short): ByteArray? = avps.firstOrNull { it.type == type }?.value

    internal fun encode(): ByteArray {
        val body: ByteArray = if (isControl) {
            val avpBuffer = ByteBuffer.allocate(avps.sumOf { it.encodedSize })
            avps.forEach { it.write(avpBuffer) }
            avpBuffer.array()
        } else {
            payload ?: ByteArray(0)
        }

        val headerFlags: Int
        val buffer = ByteBuffer.allocate(16 + body.size)

        if (isControl) {
            headerFlags = FLAG_TYPE or FLAG_LENGTH or FLAG_SEQUENCE or VERSION_L2TP
            buffer.putShort(headerFlags.toShort())
            buffer.putShort((12 + body.size).toShort())
            buffer.putShort(tunnelId.toShort())
            buffer.putShort(sessionId.toShort())
            buffer.putShort(ns.toShort())
            buffer.putShort(nr.toShort())
        } else {
            headerFlags = FLAG_LENGTH or VERSION_L2TP
            buffer.putShort(headerFlags.toShort())
            buffer.putShort((8 + body.size).toShort())
            buffer.putShort(tunnelId.toShort())
            buffer.putShort(sessionId.toShort())
        }

        buffer.put(body)
        return buffer.array().copyOfRange(0, buffer.position())
    }

    internal companion object {
        /** Parses a datagram; returns null for malformed/unsupported frames. */
        internal fun parse(datagram: ByteArray, size: Int): L2tpPacket? {
            if (size < 8) return null
            val buffer = ByteBuffer.wrap(datagram, 0, size)
            val flags = buffer.short.toInt() and 0xFFFF
            val isControl = flags and FLAG_TYPE != 0
            val hasLength = flags and FLAG_LENGTH != 0
            val hasSequence = flags and FLAG_SEQUENCE != 0
            val hasOffset = flags and FLAG_OFFSET != 0
            if (flags and 0x0003 != VERSION_L2TP) return null

            if (hasLength) buffer.short
            val tunnelId = buffer.short.toInt() and 0xFFFF
            val sessionId = buffer.short.toInt() and 0xFFFF

            val packet = L2tpPacket(isControl = isControl, tunnelId = tunnelId, sessionId = sessionId)

            if (hasSequence) {
                packet.ns = buffer.short.toInt() and 0xFFFF
                packet.nr = buffer.short.toInt() and 0xFFFF
            }
            if (hasOffset) {
                val offset = buffer.short.toInt() and 0xFFFF
                buffer.position(buffer.position() + offset)
            }

            if (!isControl) {
                val remaining = buffer.remaining()
                if (remaining <= 0) return packet
                val payload = ByteArray(remaining)
                buffer.get(payload)
                packet.payload = payload
                return packet
            }

            while (buffer.remaining() >= 6) {
                val avpFlags = buffer.short.toInt() and 0xFFFF
                val avpLength = avpFlags and 0x03FF
                if (avpLength < 6 || buffer.remaining() < avpLength - 2) return null
                buffer.short // vendor id
                val type = buffer.short
                val value = ByteArray(avpLength - 6)
                buffer.get(value)
                packet.avps.add(L2tpAvp(type, value))
            }

            return packet
        }
    }
}
