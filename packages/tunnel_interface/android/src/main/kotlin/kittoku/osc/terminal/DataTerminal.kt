package kittoku.osc.terminal

import java.nio.ByteBuffer
import javax.net.ssl.SSLEngineResult

// ZAGROS GLUE (MIT-licensed integration code, not an upstream file):
// abstraction over the PPP data medium so the upstream PPP clients
// (LCP/CHAP/IPCP, mailboxes, OutgoingManager, IPTerminal) run unchanged over
// either MS-SSTP/TLS (SSLTerminal) or L2TP/UDP (ai.zagros.tunnel.l2tp.L2tpTerminal).
internal interface DataTerminal {
    fun initialize()

    suspend fun send(buffer: ByteBuffer): SSLEngineResult

    fun receive(buffer: ByteBuffer): SSLEngineResult

    fun getApplicationBufferSize(): Int

    fun close()
}
