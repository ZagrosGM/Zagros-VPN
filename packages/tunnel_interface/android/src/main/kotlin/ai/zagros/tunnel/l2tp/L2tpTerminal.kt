package ai.zagros.tunnel.l2tp

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import javax.net.ssl.SSLEngineResult
import kittoku.osc.ControlMessage
import kittoku.osc.Result
import kittoku.osc.SharedBridge
import kittoku.osc.Where
import kittoku.osc.terminal.DataTerminal
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

internal const val L2TP_PORT = 1701
internal const val L2TP_HELLO_INTERVAL_MS = 25_000L
internal const val L2TP_RETRANSMIT_INTERVAL_MS = 2_000L
internal const val L2TP_RETRANSMIT_COUNT = 5
internal const val L2TP_APP_BUFFER_SIZE = 4096

// pseudo-SSTP wrapper emitted by the vendored (MIT) PPP clients; see Frame.writeHeader.
// kittoku's marker is 0x1000 (NOT the on-the-wire MS-SSTP 0x4001) — both the
// strip check below and the inbound wrap MUST use the exact same constant as
// kittoku's Frame.writeHeader/readHeader or the PPP exchange deadlocks.
private val KITTOKU_PPP_FRAME_MARKER: Short = kittoku.osc.unit.sstp.SSTP_PACKET_TYPE_DATA

/**
 * L2TP UDP terminal: owns the control state machine (tunnel + call setup,
 * retransmission, ZLB acknowledgement, HELLO keepalive) and the data channel
 * carrying PPP frames. Implements the vendored DataTerminal abstraction so
 * the upstream PPP clients run unchanged over UDP.
 */
internal class L2tpTerminal(private val bridge: SharedBridge) : DataTerminal {
    private val controlMutex = Mutex()

    private var socket: DatagramSocket? = null
    private var readerJob: Job? = null
    private var helloJob: Job? = null

    /**
     * When non-null the L2TP transport is L2TP/IPsec: IKEv1 Main-Mode PSK +
     * Quick Mode + ESP (all userspace, ai.zagros.tunnel.l2tp.ipsec) carry the
     * same L2TP byte stream inside UDP/4500 instead of raw UDP/1701.
     * Set by the engine before the controller launches; null = raw UDP.
     */
    @Volatile internal var ipsecPsk: ByteArray? = null

    @Volatile private var espChannel: ai.zagros.tunnel.l2tp.ipsec.EspChannel? = null

    private val incomingControls = Channel<L2tpPacket>(Channel.BUFFERED)
    private val dataChannel = Channel<ByteArray>(Channel.BUFFERED)

    @Volatile private var peerAddress: InetSocketAddress? = null

    @Volatile var isTunnelUp = false
        private set

    @Volatile var isCallUp = false
        private set

    @Volatile private var assignedTunnelId = 0
    @Volatile private var assignedSessionId = 0

    @Volatile private var localSessionId = 0

    private var nextNs = 0

    @Volatile private var expectedNr = 0

    @Volatile private var lastConfirmedNs = -1

    private fun okResult(): SSLEngineResult =
        SSLEngineResult(SSLEngineResult.Status.OK, SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING, 0, 0)

    // ------------------------------------------------------------------ UDP

    override fun initialize() {
        readerJob = bridge.scope.launch(bridge.handler) {
            val input = ByteArray(65536)
            val datagram = DatagramPacket(input, input.size)
            while (isActive) {
                // The socket is created later, inside establishTunnel; wait for
                // it instead of exiting (an early exit silently orphans the
                // L2TP connection: replies are never consumed).
                val sock = socket
                if (sock == null) {
                    delay(50)
                    continue
                }
                // IPsec mode: the blocking IKE handshake owns the socket until
                // the ESP channel exists — an active reader here would steal
                // the ISAKMP replies and deadlock the handshake.
                if (ipsecPsk != null && espChannel == null) {
                    delay(50)
                    continue
                }
                try {
                    sock.receive(datagram)
                } catch (_: Throwable) {
                    break
                }
                val esp = espChannel
                if (esp != null) {
                    val inner = esp.unwrap(input.copyOf(datagram.length)) ?: continue
                    onDatagram(inner, inner.size)
                } else {
                    onDatagram(input, datagram.length)
                }
            }
        }

        helloJob = bridge.scope.launch(bridge.handler) {
            while (isActive) {
                delay(L2TP_HELLO_INTERVAL_MS)
                if (isTunnelUp) {
                    val hello = L2tpPacket(isControl = true, tunnelId = assignedTunnelId)
                    hello.avps.add(L2tpAvp.u16(L2TP_AVP_MESSAGE_TYPE, L2TP_MESSAGE_HELLO.toInt()))
                    sendControl(hello)
                }
            }
        }
    }

    private fun onDatagram(input: ByteArray, size: Int) {
        val packet = L2tpPacket.parse(input, size) ?: return

        if (packet.isControl) {
            onControl(packet)
            return
        }

        if (!isCallUp) return
        if (packet.sessionId != assignedSessionId && packet.sessionId != localSessionId) return
        L2tpTrace.markData("data_rx")

        val pppFrame = packet.payload ?: return
        val hasHdlc = pppFrame.size >= 2 &&
            (pppFrame[0].toInt() and 0xFF) == 0xFF &&
            (pppFrame[1].toInt() and 0xFF) == 0x03

        val hdlc = if (hasHdlc) pppFrame else byteArrayOf(0xFF.toByte(), 0x03.toByte()) + pppFrame

        // Wrap into the pseudo-SSTP framing the vendored PPP parsers expect:
        // [0x4001][total length][0xFF03][protocol][PPP payload...]
        val wrapped = ByteBuffer.allocate(4 + hdlc.size)
        wrapped.putShort(KITTOKU_PPP_FRAME_MARKER)
        wrapped.putShort((4 + hdlc.size).toShort())
        wrapped.put(hdlc)

        if (!dataChannel.trySend(wrapped.array().copyOf(wrapped.position())).isSuccess) {
            bridge.controlMailbox.trySend(
                ControlMessage(Where.INCOMING, Result.ERR_INVALID_PACKET_SIZE)
            )
        }
    }

    private fun onControl(packet: L2tpPacket) {
        expectedNr = packet.ns + 1
        if (packet.nr > 0) lastConfirmedNs = packet.nr - 1

        when (packet.messageType.toInt()) {
            L2TP_MESSAGE_HELLO.toInt() -> ack()
            L2TP_MESSAGE_STOPCCN.toInt() -> {
                L2tpTrace.mark("stopccn_rx")
                bridge.controlMailbox.trySend(
                ControlMessage(Where.PPP, Result.ERR_DISCONNECT_REQUESTED)
                )
            }
            else -> incomingControls.trySend(packet)
        }

        if (packet.avps.isNotEmpty()) ack() // RFC 2661: ack data-carrying control messages
    }

    private fun ack() {
        val zlb = L2tpPacket(isControl = true, tunnelId = assignedTunnelId)
        zlb.nr = expectedNr
        runCatching { sendRaw(zlb) }
    }

    private fun sendRaw(packet: L2tpPacket) {
        val bytes = packet.encode()
        val esp = espChannel
        if (esp != null) {
            runCatching { esp.sendUdp(L2TP_PORT, L2TP_PORT, bytes) }
            return
        }
        val sock = socket ?: return
        val address = peerAddress ?: return
        sock.send(DatagramPacket(bytes, bytes.size, address))
    }

    /**
     * Sends a control message with RFC 2661 retransmission; returns once the
     * peer's Nr confirms it (or the attempt budget is exhausted).
     */
    internal suspend fun sendControl(packet: L2tpPacket): Boolean {
        return controlMutex.withLock {
            if (isTunnelUp) packet.tunnelId = assignedTunnelId

            repeat(L2TP_RETRANSMIT_COUNT) {
                packet.ns = nextNs
                packet.nr = expectedNr
                runCatching { sendRaw(packet) }

                val confirmed = withTimeoutOrNull(L2TP_RETRANSMIT_INTERVAL_MS) {
                    while (lastConfirmedNs < packet.ns) delay(50)
                    true
                }

                if (confirmed == true) {
                    nextNs += 1
                    return@withLock true
                }
            }

            false
        }
    }

    /** Consumes the next control message matching the accepted set. */
    internal suspend fun awaitMessage(timeoutMs: Long, accepted: Set<Short>): L2tpPacket? {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) return null
            val packet = withTimeoutOrNull(remaining) { incomingControls.receive() } ?: return null
            if (packet.messageType in accepted) return packet
            // unrelated (e.g. ZLB or out-of-stage) — keep draining
        }
        return null
    }

    // ------------------------------------------------------------- dialing

    // ---- JVM test hooks (harness-only; no production caller) ----
    internal fun testSocket(): java.net.DatagramSocket? = socket
    internal fun testUnwrap(datagram: ByteArray): ByteArray? = espChannel?.unwrap(datagram)

    /** Best-effort local IPv4 for the phase-1 IDi payload (0.0.0.0 fallback). */
    private fun localIpv4(): ByteArray = runCatching {
        java.net.NetworkInterface.getNetworkInterfaces().asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.asSequence() }
            .filterIsInstance<java.net.Inet4Address>()
            .firstOrNull { !it.isLoopbackAddress }
            ?.address
    }.getOrNull() ?: byteArrayOf(0, 0, 0, 0)

    internal suspend fun establishTunnel(host: String, port: Int, hostname: String): Boolean {
        val sock = DatagramSocket()
        try {
            if (!bridge.protectDatagram(sock)) {
                bridge.controlMailbox.send(
                    ControlMessage(Where.PPP, Result.ERR_VERIFICATION_FAILED, "socket protect failed")
                )
                sock.close()
                return false
            }
        } catch (_: Throwable) {
            sock.close()
            return false
        }

        var initiator: ai.zagros.tunnel.l2tp.ipsec.IkeInitiator? = null
        if (ipsecPsk != null) {
            L2tpTrace.mark("ike_start")
            initiator = ai.zagros.tunnel.l2tp.ipsec.IkeInitiator(
                sock,
                java.net.InetAddress.getByName(host),
                ipsecPsk!!,
                log = { msg ->
                    // LogWriter.report is suspending; the IKE initiator logs
                    // from blocking code, so hop into the engine scope.
                    bridge.scope.launch { bridge.logWriter?.report("IKE: $msg") }
                },
                onSocketRebound = { rebound ->
                    // Re-protect after the NAT-T float (the TUN would
                    // otherwise swallow the ESP-in-UDP traffic).
                    runCatching { bridge.protectDatagram(rebound) }
                },
            )
            try {
                initiator.establishPhase1(localIpv4())
                initiator.negotiateChild()
            } catch (e: Throwable) {
                // Surface the real failure (no msg2 / no QM msg2 / HASH mismatch
                // / PSK wrong) instead of a bare ERR_UNEXPECTED.
                throw IllegalStateException("IKE: ${e.message}", e)
            }
            val esp = initiator.esp
                ?: throw IllegalStateException("IKE: no ESP SA")
            espChannel = ai.zagros.tunnel.l2tp.ipsec.EspChannel(
                initiator.channelSocket(),
                java.net.InetAddress.getByName(host),
                esp,
            )
            L2tpTrace.mark("ike_esp_ok")
        }

        // IPsec: IKE may have REPLACED the socket on the NAT-T float (the old
        // one is closed) — always adopt the initiator's current socket.
        val ike = initiator
        val active = if (ike != null) ike.channelSocket() else sock
        val activePort = if (ike != null && ike.floated) 4500 else port
        val address = InetSocketAddress(host, activePort)
        runCatching { active.connect(address) } // a floated socket is already in use; connect is best-effort
        socket = active
        peerAddress = address
        L2tpTrace.mark("sock_ok")

        val request = L2tpPacket(isControl = true)
        request.avps.add(L2tpAvp.u16(L2TP_AVP_MESSAGE_TYPE, L2TP_MESSAGE_SCCRQ.toInt()))
        request.avps.add(L2tpAvp.bytes(L2TP_AVP_PROTOCOL_VERSION, byteArrayOf(1, 0)))
        request.avps.add(L2tpAvp.u32(L2TP_AVP_FRAMING_CAPABILITIES, 3))
        request.avps.add(L2tpAvp.ascii(L2TP_AVP_HOST_NAME, hostname.take(60)))
        request.avps.add(L2tpAvp.u16(L2TP_AVP_ASSIGNED_TUNNEL_ID, localId()))
        request.avps.add(L2tpAvp.u16(L2TP_AVP_RECEIVE_WINDOW, 8))
        request.avps.add(L2tpAvp.ascii(L2TP_AVP_VENDOR_NAME, "Zagros"))

        L2tpTrace.mark("sccrq_tx")
        if (!sendControl(request)) return false

        val reply = awaitMessage(8_000, setOf(L2TP_MESSAGE_SCCRP)) ?: return false
        assignedTunnelId = reply.avpU16(L2TP_AVP_ASSIGNED_TUNNEL_ID) ?: return false
        isTunnelUp = true
        L2tpTrace.mark("sccrp_rx")

        val confirm = L2tpPacket(isControl = true)
        confirm.avps.add(L2tpAvp.u16(L2TP_AVP_MESSAGE_TYPE, L2TP_MESSAGE_SCCCN.toInt()))
        // Best-effort: the peer re-requests with SCCRP retransmits if this is
        // lost, so a confirmation timeout must not tear down a healthy tunnel.
        sendControl(confirm)
        L2tpTrace.mark("scccn_tx")
        return true
    }

    internal suspend fun establishCall(): Boolean {
        if (!isTunnelUp) return false

        val request = L2tpPacket(isControl = true, tunnelId = assignedTunnelId)
        val wantedSessionId = localId()
        // RFC 2661: MESSAGE_TYPE must be the first AVP (A/B-tested on SoftEther:
        // accepted either way, keep the spec order).
        request.avps.add(L2tpAvp.u16(L2TP_AVP_MESSAGE_TYPE, L2TP_MESSAGE_ICRQ.toInt()))
        request.avps.add(L2tpAvp.u16(L2TP_AVP_ASSIGNED_SESSION_ID, wantedSessionId))
        request.avps.add(L2tpAvp.u32(L2TP_AVP_CALL_SERIAL_NUMBER, wantedSessionId))
        L2tpTrace.mark("icrq_tx")
        if (!sendControl(request)) return false

        val reply = awaitMessage(8_000, setOf(L2TP_MESSAGE_ICRP)) ?: return false
        val session = reply.avpU16(L2TP_AVP_ASSIGNED_SESSION_ID)
        if (session == null || session == 0) return false
        assignedSessionId = session
        // SoftEther interop (observed on the wire): its DATA packets echo the
        // CLIENT-requested session id, not the assigned one — accept both.
        localSessionId = wantedSessionId
        L2tpTrace.mark("icrp_rx")

        val connected = L2tpPacket(isControl = true, tunnelId = assignedTunnelId, sessionId = assignedSessionId)
        connected.avps.add(L2tpAvp.u16(L2TP_AVP_MESSAGE_TYPE, L2TP_MESSAGE_ICCN.toInt()))
        connected.avps.add(L2tpAvp.u32(L2TP_AVP_TX_CONNECT_SPEED, 100_000_000))
        connected.avps.add(L2tpAvp.u32(L2TP_AVP_FRAMING_TYPE, 3))
        // Best-effort like SCCCN: PPP data can flow while the ICCN ack is in
        // flight; failing the call here would abort a working tunnel.
        sendControl(connected)

        isCallUp = true
        L2tpTrace.mark("iccn_tx")
        return true
    }

    private fun localId(): Int = 100 + (0..30000).random()

    // --------------------------------------------------------- data medium

    override suspend fun send(buffer: ByteBuffer): SSLEngineResult {
        val snapshot = ByteArray(buffer.remaining())
        buffer.duplicate().get(snapshot)

        val payload: ByteArray = if (
            snapshot.size >= 4 &&
            snapshot[0] == (KITTOKU_PPP_FRAME_MARKER.toInt() shr 8).toByte() &&
            snapshot[1] == KITTOKU_PPP_FRAME_MARKER.toByte()
        ) {
            // strip the pseudo-SSTP wrapper produced by the vendored clients
            val declared = ((snapshot[2].toInt() and 0xFF) shl 8) or (snapshot[3].toInt() and 0xFF)
            val length = minOf(declared, snapshot.size) - 4
            snapshot.copyOfRange(4, 4 + length)
        } else {
            snapshot
        }

        if (!isCallUp) return okResult()

        val datagram = ByteBuffer.allocate(8 + payload.size)
        datagram.putShort((FLAG_LENGTH or VERSION_L2TP).toShort())
        datagram.putShort((8 + payload.size).toShort())
        datagram.putShort(assignedTunnelId.toShort())
        datagram.putShort(assignedSessionId.toShort())
        datagram.put(payload)

        // IPsec mode: PPP frames MUST go through the ESP channel — the floated
        // socket carries ESP-in-UDP only, raw L2TP there is dropped by the peer
        // (its SPI lookup fails and the server silently discards it).
        val esp = espChannel
        if (esp != null) {
            val out = datagram.array()
            runCatching { esp.sendUdp(L2TP_PORT, L2TP_PORT, out.copyOf(datagram.position())) }
            bridge.countTunnelBytes(tx = payload.size, rx = 0)
            return okResult()
        }

        val sock = socket ?: return okResult()
        val address = peerAddress ?: return okResult()
        val out = datagram.array()
        runCatching { sock.send(DatagramPacket(out, datagram.position(), address)) }
        bridge.countTunnelBytes(tx = payload.size, rx = 0)

        return okResult()
    }

    /** Suspends until the next L2TP data packet (already pseudo-wrapped). */
    internal suspend fun receiveData(): ByteArray = dataChannel.receive()

    override fun receive(buffer: ByteBuffer): SSLEngineResult {
        // Only used through the generic DataTerminal path; the L2TP dispatcher
        // consumes receiveData() directly.
        val datagram = kotlinx.coroutines.runBlocking { dataChannel.receive() }
        buffer.clear()
        buffer.put(datagram)
        buffer.flip()
        return okResult()
    }

    override fun getApplicationBufferSize(): Int = L2TP_APP_BUFFER_SIZE

    private fun teardownControlPackets() {
        if (!isTunnelUp) return
        L2tpTrace.mark("teardown_tx")
        if (isCallUp) {
            val cdn = L2tpPacket(isControl = true, tunnelId = assignedTunnelId, sessionId = assignedSessionId)
            cdn.avps.add(L2tpAvp.u16(L2TP_AVP_MESSAGE_TYPE, L2TP_MESSAGE_CDN.toInt()))
            cdn.avps.add(L2tpAvp.bytes(L2TP_AVP_RESULT_CODE, byteArrayOf(1, 0)))
            runCatching { sendRaw(cdn) }
        }
        val stop = L2tpPacket(isControl = true, tunnelId = assignedTunnelId)
        stop.avps.add(L2tpAvp.u16(L2TP_AVP_MESSAGE_TYPE, L2TP_MESSAGE_STOPCCN.toInt()))
        stop.avps.add(L2tpAvp.bytes(L2TP_AVP_RESULT_CODE, byteArrayOf(1, 0)))
        runCatching { sendRaw(stop) }
    }

    override fun close() {
        teardownControlPackets()
        isCallUp = false
        isTunnelUp = false
        helloJob?.cancel()
        readerJob?.cancel()
        try {
            socket?.close()
        } catch (_: Throwable) {
        }
        socket = null
    }
}

private const val FLAG_LENGTH = 0x4000
private const val VERSION_L2TP = 0x0002
