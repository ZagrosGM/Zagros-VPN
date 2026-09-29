package kittoku.osc.terminal

import kittoku.osc.ControlMessage
import kittoku.osc.Result
import kittoku.osc.SharedBridge
import kittoku.osc.Where
import kittoku.osc.extension.capacityAfterLimit
import kittoku.osc.preference.OscPrefKey
import kittoku.osc.preference.accessor.getIntPrefValue
import kittoku.osc.preference.accessor.getStringPrefValue
import kittoku.osc.extension.slide
import kittoku.osc.extension.toIntAsUByte
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.yield
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertPathValidatorException
import java.security.cert.Certificate
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLEngineResult
import javax.net.ssl.SSLSession
import javax.net.ssl.TrustManager
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager


private const val HTTP_DELIMITER = "\r\n"
private const val HTTP_SUFFIX = "\r\n\r\n"

internal const val SSL_REQUEST_INTERVAL = 10_000L

// ZAGROS ADAPTATION of upstream SSLTerminal:
// - SAF-trust-store, proxy CONNECT, cipher-suite selection and the
//   save-certificate notification flow are not vendored;
// - a server-certificate SHA-256 pin (bridge.certSha256Pin) is supported:
//   the connection is accepted when the default trust path validates, OR the
//   leaf certificate SHA-256 digest equals the pin. Hostname verification is
//   enforced on the CA path and skipped only for a matching pin.
internal class SSLTerminal(private val bridge: SharedBridge) : DataTerminal {
    private val mutex = Mutex()

    private var socket: Socket? = null
    private lateinit var socketInputStream: InputStream
    private lateinit var socketOutputStream: OutputStream
    private lateinit var inboundBuffer: ByteBuffer
    private lateinit var outboundBuffer: ByteBuffer

    private lateinit var engine: SSLEngine

    private var jobInitialize: Job? = null

    private var pinMatched = false

    private val sslHostname = getStringPrefValue(OscPrefKey.HOME_HOSTNAME, bridge.prefs)
    private val sslPort = getIntPrefValue(OscPrefKey.SSL_PORT, bridge.prefs)

    override fun initialize() {
        jobInitialize = bridge.scope.launch(bridge.handler) {
            if (!establishSSL()) return@launch

            if (!establishHttp()) return@launch

            bridge.controlMailbox.send(ControlMessage(Where.SSL, Result.PROCEEDED))
        }
    }

    private fun createPinTrustManager(pin: String): Array<TrustManager> {
        val normalized = pin.lowercase().replace(":", "").replace(" ", "")
        require(normalized.length == 64) { "invalid certificate pin" }
        val expected = normalized.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

        return arrayOf(object : X509TrustManager {
            private val default: X509TrustManager by lazy {
                val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
                factory.init(null as KeyStore?)
                factory.trustManagers.filterIsInstance<X509TrustManager>().first()
            }

            private fun leafMatches(chain: Array<X509Certificate>): Boolean {
                val digest = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded)
                return digest.contentEquals(expected)
            }

            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
                default.checkClientTrusted(chain, authType)
            }

            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                try {
                    default.checkServerTrusted(chain, authType)
                    pinMatched = false
                } catch (first: CertificateException) {
                    if (chain.isNotEmpty() && leafMatches(chain)) {
                        pinMatched = true
                    } else {
                        throw first
                    }
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = default.acceptedIssuers
        })
    }

    private suspend fun establishSSL(): Boolean {
        val pin = bridge.certSha256Pin
        val sslContext = if (pin != null) {
            try {
                SSLContext.getInstance("TLS").also {
                    it.init(null, createPinTrustManager(pin), null)
                }
            } catch (e: IllegalArgumentException) {
                bridge.controlMailbox.send(ControlMessage(Where.CERT, Result.ERR_PARSING_FAILED, "invalid pin"))
                return false
            }
        } else {
            SSLContext.getDefault()
        }

        engine = sslContext.createSSLEngine(sslHostname, sslPort)
        engine.useClientMode = true

        socket = Socket(sslHostname, sslPort).also {
            socketInputStream = it.getInputStream()
            socketOutputStream = it.getOutputStream()
        }

        inboundBuffer = ByteBuffer.allocate(engine.session.packetBufferSize).also { it.limit(0) }
        outboundBuffer = ByteBuffer.allocate(engine.session.packetBufferSize)

        try {
            startSSLHandshake()
        } catch (e: CertificateException) {
            val cause = e.cause
            if (cause is CertPathValidatorException) {
                bridge.controlMailbox.send(
                    ControlMessage(Where.CERT_PATH, Result.ERR_VERIFICATION_FAILED, generateCertPathLog(cause))
                )

                return false
            } else {
                throw e
            }
        }

        if (pin == null || !pinMatched) {
            HttpsURLConnection.getDefaultHostnameVerifier().also {
                if (!it.verify(sslHostname, engine.session)) {
                    bridge.controlMailbox.send(ControlMessage(Where.SSL, Result.ERR_VERIFICATION_FAILED))
                    return false
                }
            }
        }

        return true
    }

    private suspend fun startSSLHandshake() {
        val tempBuffer = ByteBuffer.allocate(0)

        engine.beginHandshake()

        while (true) {
            yield()

            when (engine.handshakeStatus) {
                SSLEngineResult.HandshakeStatus.NEED_WRAP -> {
                    val result = send(tempBuffer)
                    if (result.handshakeStatus == SSLEngineResult.HandshakeStatus.FINISHED) {
                        break
                    }
                }

                SSLEngineResult.HandshakeStatus.NEED_UNWRAP -> {
                    val result = receive(tempBuffer)
                    if (result.handshakeStatus == SSLEngineResult.HandshakeStatus.FINISHED) {
                        break
                    }
                }

                else -> {
                    throw NotImplementedError(engine.handshakeStatus.name)
                }
            }
        }
    }

    private suspend fun establishHttp(): Boolean {
        val buffer = ByteBuffer.allocate(getApplicationBufferSize())

        val request = arrayOf(
            "SSTP_DUPLEX_POST /sra_{BA195980-CD49-458b-9E23-C84EE0ADCD75}/ HTTP/1.1",
            "Content-Length: 18446744073709551615",
            "Host: $sslHostname",
            "SSTPCORRELATIONID: {${bridge.guid}}"
        ).joinToString(separator = HTTP_DELIMITER, postfix = HTTP_SUFFIX).toByteArray(Charsets.US_ASCII)

        buffer.put(request)
        buffer.flip()

        send(buffer)

        buffer.position(0)
        buffer.limit(0)

        var response = ""
        outer@ while (true) {
            receive(buffer)

            for (i in 0 until buffer.remaining()) {
                response += buffer.get().toIntAsUByte().toChar()

                if (response.endsWith(HTTP_SUFFIX)) {
                    break@outer
                }
            }
        }

        if (!response.split(HTTP_DELIMITER)[0].contains("200")) {
            bridge.controlMailbox.send(ControlMessage(Where.SSL, Result.ERR_UNEXPECTED_MESSAGE))
            return false
        }


        val protectedSocket = socket
        if (protectedSocket == null) {
            bridge.controlMailbox.send(ControlMessage(Where.SSL, Result.ERR_UNEXPECTED_MESSAGE))
            return false
        }

        protectedSocket.soTimeout = 1_000
        if (!bridge.protectSocket(protectedSocket)) {
            // Without protection the SSTP socket would loop back into the TUN
            // once it is up; refuse the connection instead of creating a loop.
            bridge.controlMailbox.send(
                ControlMessage(Where.SSL, Result.ERR_VERIFICATION_FAILED, "socket protect failed")
            )
            return false
        }
        return true
    }

    private fun generateCertPathLog(exception: CertPathValidatorException): String {
        var log = "[MESSAGE]\n${exception.message}\n\n"

        log += "[CERT PATH]\n"
        exception.certPath.certificates.forEachIndexed { i, cert ->
            log += "-----CERT at $i-----\n"
            log += "$cert\n"
            log += "-----END CERT-----\n"
        }
        log += "[FAILED CERT INDEX]\n"
        log += if (exception.index == -1) "NOT DEFINED" else exception.index.toString()
        log += "\n"

        return log
    }

    internal fun getSession(): SSLSession {
        return engine.session
    }

    internal fun getServerCertificate(): ByteArray {
        return engine.session.peerCertificates[0].encoded
    }

    override fun getApplicationBufferSize(): Int {
        return engine.session.applicationBufferSize
    }

    override fun receive(buffer: ByteBuffer): SSLEngineResult {
        var startPayload: Int
        var result: SSLEngineResult

        while (true) {
            startPayload = buffer.position()
            buffer.position(buffer.limit())
            buffer.limit(buffer.capacity())

            result = engine.unwrap(inboundBuffer, buffer)

            when (result.status) {
                SSLEngineResult.Status.OK -> {
                    break
                }

                SSLEngineResult.Status.BUFFER_OVERFLOW -> {
                    buffer.limit(buffer.position())
                    buffer.position(startPayload)

                    buffer.slide()
                }

                SSLEngineResult.Status.BUFFER_UNDERFLOW -> {
                    buffer.limit(buffer.position())
                    buffer.position(startPayload)

                    inboundBuffer.slide()

                    try {
                        val readSize = socketInputStream.read(
                            inboundBuffer.array(),
                            inboundBuffer.limit(),
                            inboundBuffer.capacityAfterLimit
                        )

                        inboundBuffer.limit(inboundBuffer.limit() + readSize)
                    } catch (_: SocketTimeoutException) { }
                }

                else -> {
                    throw NotImplementedError(result.status.name)
                }
            }
        }

        buffer.limit(buffer.position())
        buffer.position(startPayload)

        return result
    }

    override suspend fun send(buffer: ByteBuffer): SSLEngineResult {
        mutex.withLock {
            var result: SSLEngineResult

            while (true) {
                outboundBuffer.clear()

                result = engine.wrap(buffer, outboundBuffer)
                if (result.status != SSLEngineResult.Status.OK) {
                    throw NotImplementedError(result.status.name)
                }

                socketOutputStream.write(
                    outboundBuffer.array(),
                    0,
                    outboundBuffer.position()
                )

                if (!buffer.hasRemaining()) {
                    socketOutputStream.flush()

                    break
                }
            }

            return result
        }
    }

    override fun close() {
        jobInitialize?.cancel()
        socket?.close()
    }
}
