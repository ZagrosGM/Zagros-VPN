package ai.zagros.tunnel.l2tp

import kittoku.osc.ControlMessage
import kittoku.osc.Result
import kittoku.osc.SharedBridge
import kittoku.osc.Where
import kittoku.osc.client.ppp.IpcpClient
import kittoku.osc.client.ppp.LCPClient
import kittoku.osc.client.ppp.PPP_NEGOTIATION_TIMEOUT
import kittoku.osc.client.ppp.PPPClient
import kittoku.osc.client.ppp.auth.ChapMSCHAPV2Client
import kittoku.osc.io.OutgoingManager
import kittoku.osc.preference.AUTH_PROTOCOL_MSCHAPv2
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Orchestration for the raw-L2TP engine. Adapted from the MIT-licensed
 * kittoku/Open-SSTP-Client Controller: the SSL/SSTP stages are replaced by
 * the L2TP tunnel+call establishment, the SSTP CallConnected/CMK step is not
 * applicable to L2TP, and the upstream auto-reconnection and NetworkObserver
 * are not vendored (reconnection is orchestrated by the Zagros runtime).
 */
internal class L2tpController(internal val bridge: SharedBridge, private val terminal: L2tpTerminal) {
    private var dispatcher: L2tpDispatcher? = null
    private var pppClient: PPPClient? = null
    private var lcpClient: LCPClient? = null
    private var chapClient: ChapMSCHAPV2Client? = null
    private var ipcpClient: IpcpClient? = null
    private var outgoingManager: OutgoingManager? = null

    private var jobMain: Job? = null
    private val mutex = Mutex()

    internal fun launchJobMain(server: String, port: Int, hostname: String) {
        bridge.handler = kotlinx.coroutines.CoroutineExceptionHandler { _, throwable ->
            L2tpTrace.markError(throwable.message ?: throwable.javaClass.simpleName)
            L2tpTrace.mark("ex_" + throwable.javaClass.simpleName.lowercase().replace(Regex("[^a-z0-9]+"), "").take(16))
            kill {
                val header = "L2TP: ERR_UNEXPECTED"
                bridge.logWriter?.report(header + "\n" + throwable.stackTraceToString())
                bridge.notifyError(header)
            }
        }

        jobMain = bridge.scope.launch(bridge.handler) {
            // Start the UDP reader/keepalive jobs BEFORE dialing; otherwise
            // the SCCRP reply is never consumed and SCCRQ retransmits until
            // the attempt budget is exhausted (observed on a real device).
            terminal.initialize()

            // Upstream kittoku attaches the IP terminal during startup; omitting
            // this left bridge.ipTerminal null and NPE-killed the engine right
            // after IPCP (proven on a JVM harness against the real server).
            bridge.attachIPTerminal()

            if (!terminal.establishTunnel(server, port, hostname)) {
                kill {
                    bridge.logWriter?.report("L2TP: ERR_TUNNEL_FAILED")
                    bridge.notifyError("L2TP: ERR_TUNNEL_FAILED")
                }
                return@launch
            }

            if (!terminal.establishCall()) {
                kill {
                    bridge.logWriter?.report("L2TP: ERR_CALL_FAILED")
                    bridge.notifyError("L2TP: ERR_CALL_FAILED")
                }
                return@launch
            }


            L2tpDispatcher(bridge, terminal).also {
                it.launchJobMain()
                dispatcher = it
            }


            PPPClient(bridge).also {
                pppClient = it
                dispatcher!!.registerMailbox(it)
                it.launchJobControl()
            }


            LCPClient(bridge).also {
                lcpClient = it
                dispatcher!!.registerMailbox(it)
                it.launchJobNegotiation()

                if (!expectProceeded(Where.LCP, PPP_NEGOTIATION_TIMEOUT)) {
                    return@launch
                }

                L2tpTrace.mark("lcp_ok")
                dispatcher!!.unregisterMailbox(it)
            }


            // Only MS-CHAPv2 is seeded by the engine; refuse anything else honestly.
            if (bridge.currentAuth != AUTH_PROTOCOL_MSCHAPv2) {
                kill {
                    val log = "L2TP: ERR_UNSUPPORTED_AUTH (${bridge.currentAuth})"
                    bridge.logWriter?.report(log)
                    bridge.notifyError(log)
                }
                return@launch
            }

            ChapMSCHAPV2Client(bridge).also {
                chapClient = it
                dispatcher!!.registerMailbox(it)
                it.launchJobAuth()

                if (!expectProceeded(Where.CHAP, 10_000L)) {
                    return@launch
                }

                L2tpTrace.mark("chap_ok")
            }


            IpcpClient(bridge).also {
                ipcpClient = it
                dispatcher!!.registerMailbox(it)
                it.launchJobNegotiation()

                if (!expectProceeded(Where.IPCP, PPP_NEGOTIATION_TIMEOUT)) {
                    return@launch
                }

                L2tpTrace.mark("ipcp_ok")
                dispatcher!!.unregisterMailbox(it)
            }


            L2tpTrace.mark("ip_stage")
            bridge.ipTerminal!!.initialize()
            if (!expectProceeded(Where.IP, null)) {
                return@launch
            }

            bridge.notifyEstablished() // TUN is up and routing is live


            OutgoingManager(bridge).also {
                it.launchJobMain()
                outgoingManager = it
            }


            expectProceeded(Where.PPP, null) // wait until disconnection/error
        }
    }

    private suspend fun expectProceeded(where: Where, timeout: Long?): Boolean {
        val received = if (timeout != null) {
            withTimeoutOrNull(timeout) {
                bridge.controlMailbox.receive()
            } ?: ControlMessage(where, Result.ERR_TIMEOUT)
        } else {
            bridge.controlMailbox.receive()
        }

        if (received.result == Result.PROCEEDED) {
            return true
        }

        L2tpTrace.mark(received.from.name.lowercase() + "_" + received.result.name.lowercase())
        kill {
            val header = "L2TP: ${received.from.name}: ${received.result.name}"
            var log = header
            if (received.supplement != null) {
                log += "\n${received.supplement}"
            }

            bridge.logWriter?.report(log)
            bridge.notifyError(header)
        }

        return false
    }

    internal fun disconnect() {
        kill {
            terminal.close() // sends CDN + StopCCN
        }
    }

    private fun kill(cleanup: suspend () -> Unit) {
        L2tpTrace.mark("kill")
        if (!mutex.tryLock()) return

        bridge.scope.launch {
            jobMain?.cancel()
            dispatcher?.cancel()

            cleanup()

            bridge.ipTerminal?.close()
            terminal.close()

            bridge.closeEngine()
        }
    }
}
