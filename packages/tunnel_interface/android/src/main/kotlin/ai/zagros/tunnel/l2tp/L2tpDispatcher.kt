package ai.zagros.tunnel.l2tp

import java.nio.ByteBuffer
import kittoku.osc.ControlMessage
import kittoku.osc.MAX_MRU
import kittoku.osc.Result
import kittoku.osc.SharedBridge
import kittoku.osc.Where
import kittoku.osc.client.ppp.IpcpClient
import kittoku.osc.client.ppp.Ipv6cpClient
import kittoku.osc.client.ppp.LCPClient
import kittoku.osc.client.ppp.PPPClient
import kittoku.osc.client.ppp.auth.ChapClient
import kittoku.osc.client.ppp.auth.EAPClient
import kittoku.osc.client.ppp.auth.PAPClient
import kittoku.osc.extension.probeByte
import kittoku.osc.extension.probeShort
import kittoku.osc.unit.ppp.Frame
import kittoku.osc.unit.ppp.IpcpConfigureAck
import kittoku.osc.unit.ppp.IpcpConfigureFrame
import kittoku.osc.unit.ppp.IpcpConfigureNak
import kittoku.osc.unit.ppp.IpcpConfigureReject
import kittoku.osc.unit.ppp.IpcpConfigureRequest
import kittoku.osc.unit.ppp.Ipv6cpConfigureAck
import kittoku.osc.unit.ppp.Ipv6cpConfigureFrame
import kittoku.osc.unit.ppp.Ipv6cpConfigureNak
import kittoku.osc.unit.ppp.Ipv6cpConfigureReject
import kittoku.osc.unit.ppp.Ipv6cpConfigureRequest
import kittoku.osc.unit.ppp.LCPCodeReject
import kittoku.osc.unit.ppp.LCPConfigureAck
import kittoku.osc.unit.ppp.LCPConfigureFrame
import kittoku.osc.unit.ppp.LCPConfigureNak
import kittoku.osc.unit.ppp.LCPConfigureReject
import kittoku.osc.unit.ppp.LCPConfigureRequest
import kittoku.osc.unit.ppp.LCPEchoReply
import kittoku.osc.unit.ppp.LCPEchoRequest
import kittoku.osc.unit.ppp.LCPProtocolReject
import kittoku.osc.unit.ppp.LCPTerminalAck
import kittoku.osc.unit.ppp.LCPTerminalRequest
import kittoku.osc.unit.ppp.LcpDiscardRequest
import kittoku.osc.unit.ppp.PPP_PROTOCOL_CHAP
import kittoku.osc.unit.ppp.PPP_PROTOCOL_EAP
import kittoku.osc.unit.ppp.PPP_PROTOCOL_IP
import kittoku.osc.unit.ppp.PPP_PROTOCOL_IPCP
import kittoku.osc.unit.ppp.PPP_PROTOCOL_IPv6
import kittoku.osc.unit.ppp.PPP_PROTOCOL_IPv6CP
import kittoku.osc.unit.ppp.PPP_PROTOCOL_LCP
import kittoku.osc.unit.ppp.PPP_PROTOCOL_PAP
import kittoku.osc.unit.ppp.auth.ChapChallenge
import kittoku.osc.unit.ppp.auth.ChapFailure
import kittoku.osc.unit.ppp.auth.ChapFrame
import kittoku.osc.unit.ppp.auth.ChapResponse
import kittoku.osc.unit.ppp.auth.ChapSuccess
import kittoku.osc.unit.ppp.auth.EAPFailure
import kittoku.osc.unit.ppp.auth.EAPFrame
import kittoku.osc.unit.ppp.auth.EAPRequest
import kittoku.osc.unit.ppp.auth.EAPResponse
import kittoku.osc.unit.ppp.auth.EAPSuccess
import kittoku.osc.unit.ppp.auth.PAPAuthenticateAck
import kittoku.osc.unit.ppp.auth.PAPAuthenticateNak
import kittoku.osc.unit.ppp.auth.PAPAuthenticateRequest
import kittoku.osc.unit.ppp.auth.PAPFrame
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private const val PPP_ECHO_INTERVAL = 20_000L

// ZAGROS: incoming dispatcher for the L2TP medium. Adapted from the
// MIT-licensed kittoku/Open-SSTP-Client IncomingManager/process.kt (the SSTP
// packet layer is replaced by L2TP data packets already wrapped in the
// pseudo-SSTP framing by L2tpTerminal; the PPP mailbox dispatch is identical).
internal class L2tpDispatcher(internal val bridge: SharedBridge, private val terminal: L2tpTerminal) {
    internal var lcpMailbox: Channel<LCPConfigureFrame>? = null
    internal var papMailbox: Channel<PAPFrame>? = null
    internal var chapMailbox: Channel<ChapFrame>? = null
    internal var eapMailbox: Channel<EAPFrame>? = null
    internal var ipcpMailbox: Channel<IpcpConfigureFrame>? = null
    internal var ipv6cpMailbox: Channel<Ipv6cpConfigureFrame>? = null
    internal var pppMailbox: Channel<Frame>? = null

    private var jobMain: Job? = null
    private var lastTicked = 0L
    private var echoWaited = false
    private var echoDeadline = 0L

    internal fun registerMailbox(client: Any) {
        when (client) {
            is LCPClient -> lcpMailbox = client.mailbox
            is PAPClient -> papMailbox = client.mailbox
            is ChapClient -> chapMailbox = client.mailbox
            is EAPClient -> eapMailbox = client.mailbox
            is IpcpClient -> ipcpMailbox = client.mailbox
            is Ipv6cpClient -> ipv6cpMailbox = client.mailbox
            is PPPClient -> pppMailbox = client.mailbox
            else -> throw NotImplementedError(client?.toString() ?: "")
        }
    }

    internal fun unregisterMailbox(client: Any) {
        when (client) {
            is LCPClient -> lcpMailbox = null
            is PAPClient -> papMailbox = null
            is ChapClient -> chapMailbox = null
            is EAPClient -> eapMailbox = null
            is IpcpClient -> ipcpMailbox = null
            is Ipv6cpClient -> ipv6cpMailbox = null
            is PPPClient -> pppMailbox = null
            else -> throw NotImplementedError(client?.toString() ?: "")
        }
    }

    internal fun launchJobMain() {
        jobMain = bridge.scope.launch(bridge.handler) {
            lastTicked = System.currentTimeMillis()
            val bufferSize = terminal.getApplicationBufferSize() + MAX_MRU + 8

            while (isActive) {
                // LCP echo keepalive (mirrors the upstream pppTimer/EchoTimer)
                val now = System.currentTimeMillis()
                if (now - lastTicked > PPP_ECHO_INTERVAL) {
                    if (echoWaited) {
                        if (now > echoDeadline) {
                            bridge.controlMailbox.send(ControlMessage(Where.PPP, Result.ERR_TIMEOUT))
                            return@launch
                        }
                    } else {
                        LCPEchoRequest().also {
                            it.id = bridge.allocateNewFrameID()
                            it.holder = "Abura Mashi Mashi".toByteArray(Charsets.US_ASCII)
                            terminal.send(it.toByteBuffer())
                        }
                        echoWaited = true
                        echoDeadline = now + PPP_ECHO_INTERVAL
                    }
                } else {
                    echoWaited = false
                }

                val buffer = ByteBuffer.allocate(bufferSize)
                val datagram = terminal.receiveData()
                buffer.put(datagram)
                buffer.flip()

                lastTicked = now

                if (buffer.remaining() < 8) continue // short pseudo wrapper

                val protocol = buffer.probeShort(6)

                if (protocol == PPP_PROTOCOL_IP || protocol == PPP_PROTOCOL_IPv6) {
                    processIPPacket(bridge.PPP_IPv4_ENABLED, buffer.limit(), buffer)
                    continue
                }

                val code = buffer.probeByte(8)
                val isGo = when (protocol) {
                    PPP_PROTOCOL_LCP -> processLcpFrame(code, buffer)
                    PPP_PROTOCOL_PAP -> processPapFrame(code, buffer)
                    PPP_PROTOCOL_CHAP -> processChapFrame(code, buffer)
                    PPP_PROTOCOL_EAP -> processEapFrame(code, buffer)
                    PPP_PROTOCOL_IPCP -> processIpcpFrame(code, buffer)
                    PPP_PROTOCOL_IPv6CP -> processIpv6cpFrame(code, buffer)
                    else -> processUnknownProtocol(protocol, buffer.limit(), buffer)
                }

                if (!isGo) return@launch
            }
        }
    }

    private suspend fun processIPPacket(isEnabledProtocol: Boolean, packetSize: Int, buffer: ByteBuffer) {
        if (isEnabledProtocol) {
            val start = buffer.position() + 8
            val ipPacketSize = packetSize - 8
            if (ipPacketSize > 0) {
                bridge.ipTerminal!!.writePacket(start, ipPacketSize, buffer)
            }
        }
    }

    private suspend fun tryReadDataUnit(unit: Frame, buffer: ByteBuffer): Exception? {
        return try {
            unit.read(buffer)
            null
        } catch (e: Exception) {
            bridge.controlMailbox.send(ControlMessage(Where.INCOMING, Result.ERR_PARSING_FAILED))
            e
        }
    }

    private suspend fun processLcpFrame(code: Byte, buffer: ByteBuffer): Boolean {
        val frame: Frame = when (code) {
            in 1..4 -> when (code.toInt()) {
                1 -> LCPConfigureRequest()
                2 -> LCPConfigureAck()
                3 -> LCPConfigureNak()
                else -> LCPConfigureReject()
            }
            in 5..11 -> when (code.toInt()) {
                5 -> LCPTerminalRequest()
                6 -> LCPTerminalAck()
                7 -> LCPCodeReject()
                8 -> LCPProtocolReject()
                9 -> LCPEchoRequest()
                10 -> LCPEchoReply()
                else -> LcpDiscardRequest()
            }
            else -> {
                bridge.controlMailbox.send(ControlMessage(Where.LCP, Result.ERR_UNKNOWN_TYPE))
                return false
            }
        }

        tryReadDataUnit(frame, buffer)?.also { return false }

        if (code in 1..4) {
            lcpMailbox?.send(frame as LCPConfigureFrame)
        } else {
            pppMailbox?.send(frame)
        }
        return true
    }

    private suspend fun processPapFrame(code: Byte, buffer: ByteBuffer): Boolean {
        val frame: PAPFrame = when (code.toInt()) {
            1 -> PAPAuthenticateRequest()
            2 -> PAPAuthenticateAck()
            3 -> PAPAuthenticateNak()
            else -> {
                bridge.controlMailbox.send(ControlMessage(Where.PAP, Result.ERR_UNKNOWN_TYPE))
                return false
            }
        }
        tryReadDataUnit(frame, buffer)?.also { return false }
        papMailbox?.send(frame)
        return true
    }

    private suspend fun processChapFrame(code: Byte, buffer: ByteBuffer): Boolean {
        val frame: ChapFrame = when (code.toInt()) {
            1 -> ChapChallenge()
            2 -> ChapResponse()
            3 -> ChapSuccess()
            4 -> ChapFailure()
            else -> {
                bridge.controlMailbox.send(ControlMessage(Where.CHAP, Result.ERR_UNKNOWN_TYPE))
                return false
            }
        }
        tryReadDataUnit(frame, buffer)?.also { return false }
        chapMailbox?.send(frame)
        return true
    }

    private suspend fun processEapFrame(code: Byte, buffer: ByteBuffer): Boolean {
        val frame: EAPFrame = when (code.toInt()) {
            1 -> EAPRequest()
            2 -> EAPResponse()
            3 -> EAPSuccess()
            4 -> EAPFailure()
            else -> {
                bridge.controlMailbox.send(ControlMessage(Where.EAP, Result.ERR_UNKNOWN_TYPE))
                return false
            }
        }
        tryReadDataUnit(frame, buffer)?.also { return false }
        eapMailbox?.send(frame)
        return true
    }

    private suspend fun processIpcpFrame(code: Byte, buffer: ByteBuffer): Boolean {
        val frame: IpcpConfigureFrame = when (code.toInt()) {
            1 -> IpcpConfigureRequest()
            2 -> IpcpConfigureAck()
            3 -> IpcpConfigureNak()
            else -> IpcpConfigureReject()
        }
        tryReadDataUnit(frame, buffer)?.also { return false }
        ipcpMailbox?.send(frame)
        return true
    }

    private suspend fun processIpv6cpFrame(code: Byte, buffer: ByteBuffer): Boolean {
        val frame: Ipv6cpConfigureFrame = when (code.toInt()) {
            1 -> Ipv6cpConfigureRequest()
            2 -> Ipv6cpConfigureAck()
            3 -> Ipv6cpConfigureNak()
            else -> Ipv6cpConfigureReject()
        }
        tryReadDataUnit(frame, buffer)?.also { return false }
        ipv6cpMailbox?.send(frame)
        return true
    }

    private suspend fun processUnknownProtocol(protocol: Short, packetSize: Int, buffer: ByteBuffer): Boolean {
        LCPProtocolReject().also {
            it.rejectedProtocol = protocol
            it.id = bridge.allocateNewFrameID()
            val infoStart = buffer.position() + 8
            val infoStop = buffer.position() + packetSize
            it.holder = buffer.array().sliceArray(infoStart until infoStop)
            terminal.send(it.toByteBuffer())
        }
        return true
    }

    internal fun cancel() {
        jobMain?.cancel()
    }
}
