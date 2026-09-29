package ai.zagros.tunnel.l2tp.ipsec

import java.math.BigInteger
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * IKEv1 (RFC 2409) Main-Mode PSK initiator + Quick Mode + ESP (RFC 2406/3948)
 * userspace data path for the raw L2TP engine. Written from the RFCs for the
 * Zagros client (no external code vendored); runs on JVM and Android unchanged.
 *
 * Attribute class numbers:
 *  - Phase 1 (RFC 2409 Appendix A / Oakley): enc=1 hash=2 authmethod=3 group=4
 *    lifetype=11 lifedur=12 keylen=14(bits)
 *  - Phase 2 ESP (RFC 2407 IPSEC DOI): lifetype=1 lifedur=2 encap=4 authalg=5
 *    keylen=6(bits); Encapsulation Transport=2; HMAC-SHA=2
 */
internal object IkeVal {
    const val HDR = 28
    const val V1 = 0x10
    const val PT_SA = 1
    const val PT_KE = 4
    const val PT_ID = 5
    const val PT_HASH = 8
    const val PT_NONCE = 10
    const val PT_NOTIFY = 11
    const val PT_VID = 13
    const val PT_TRANSFORM = 3
    const val EX_MAIN = 2
    const val EX_QM = 32
    const val FL_ENC = 0x01
    const val DOI_IPSEC = 1

    const val A_ENC = 1
    const val A_HASH = 2
    const val A_AUTHMETH = 3
    const val A_GROUP = 4
    const val A_LIFETYPE = 11
    const val A_LIFEDUR = 12
    const val A_KEYLEN = 14

    const val P2_LIFETYPE = 1
    const val P2_LIFEDUR = 2
    const val P2_ENCAP = 4
    const val P2_AUTHALG = 5
    const val P2_KEYLEN = 6

    const val LIFETYPE_SECONDS = 1
    const val AUTH_PSK = 1
    const val HASH_SHA1 = 2
    const val ENC_AES128 = 7
    const val ENC_AES192 = 8
    const val ENC_AES256 = 9
    const val ENC_3DES = 5
    const val GROUP14 = 14

    const val ENCAP_TRANSPORT = 2
    const val AUTHALG_HMAC_SHA = 2

    const val PROTO_ISAKMP = 1
    const val PROTO_ESP = 3
    const val T_KEY_IKE = 1
    const val T_ESP_3DES = 3
    const val T_ESP_AES = 12

    const val NOTIFY_NATD = 24501
    const val NOTIFY_DELETE = 1
}

internal object IkeCrypto {
    fun sha1(vararg chunks: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-1")
        for (c in chunks) md.update(c)
        return md.digest()
    }

    fun md5(data: ByteArray): ByteArray = MessageDigest.getInstance("MD5").digest(data)

    fun hmacSha1(key: ByteArray, vararg chunks: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA1")
        mac.init(SecretKeySpec(key, "HmacSHA1"))
        for (c in chunks) mac.update(c)
        return mac.doFinal()
    }

    fun blockBytes(encId: Int): Int = if (encId == IkeVal.ENC_3DES) 8 else 16

    fun keyBytes(encId: Int): Int = when (encId) {
        IkeVal.ENC_AES128 -> 16
        IkeVal.ENC_AES192 -> 24
        IkeVal.ENC_AES256 -> 32
        IkeVal.ENC_3DES -> 24
        else -> 16
    }

    fun cbc(key: ByteArray, iv: ByteArray, data: ByteArray, encrypt: Boolean, encId: Int): ByteArray {
        val algo = if (encId == IkeVal.ENC_3DES) "DESede" else "AES"
        val c = Cipher.getInstance("$algo/CBC/NoPadding")
        c.init(
            if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE,
            SecretKeySpec(key, algo),
            IvParameterSpec(iv),
        )
        return c.doFinal(data)
    }

    /** Oakley Group 14 (RFC 3526, 2048-bit MODP) — verified via p=2^2048-2^1984-1+2^64*([2^1918 pi]+124476), prime-tested. */
    val G14_P = BigInteger(
        "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74" +
            "020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" +
            "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" +
            "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" +
            "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb" +
            "9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" +
            "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718" +
            "3995497cea956ae515d2261898fa051015728e5a8aacaa68ffffffffffffffff", 16
    )
    const val G = 2

    fun bigToFixed(v: BigInteger, len: Int): ByteArray {
        val raw = v.toByteArray()
        val out = ByteArray(len)
        if (raw.size >= len) {
            System.arraycopy(raw, raw.size - len, out, 0, len)
        } else {
            System.arraycopy(raw, 0, out, len - raw.size, raw.size)
        }
        return out
    }

    fun randBytes(n: Int): ByteArray = ByteArray(n).also { SecureRandom().nextBytes(it) }

    fun dhPublic(groupP: BigInteger, priv: BigInteger): ByteArray {
        val len = (groupP.bitLength() + 7) / 8
        return bigToFixed(BigInteger.valueOf(G.toLong()).modPow(priv, groupP), len)
    }

    fun dhShared(groupP: BigInteger, priv: BigInteger, peerPub: ByteArray): ByteArray {
        val len = (groupP.bitLength() + 7) / 8
        return bigToFixed(BigInteger(1, peerPub).modPow(priv, groupP), len)
    }

    /** RFC 2409 Appendix B: expand SKEYID_e to the cipher key length.
     * K1 = prf(Ke, 0x00); K(n) = prf(Ke, K(n-1)); concatenate and truncate. */
    fun expandKey(skeyidE: ByteArray, wanted: Int): ByteArray {
        if (skeyidE.size >= wanted) return skeyidE.copyOf(wanted)
        val blocks = ArrayList<ByteArray>()
        var prev = hmacSha1(skeyidE, byteArrayOf(0x00))
        blocks.add(prev)
        while (blocks.sumOf { it.size } < wanted) {
            prev = hmacSha1(skeyidE, prev)
            blocks.add(prev)
        }
        val out = ByteArray(wanted)
        var off = 0
        for (b in blocks) {
            val n = minOf(b.size, wanted - off)
            System.arraycopy(b, 0, out, off, n)
            off += n
            if (off >= wanted) break
        }
        return out
    }
}

internal class IkePayload(val type: Int, val body: ByteArray) {
    /** Full payload bytes INCLUDING the generic header (needed for SAi_b etc.). */
    lateinit var full: ByteArray
}

internal object Isakmp {
    fun u16(b: ByteArray, off: Int): Int = ((b[off].toInt() and 0xFF) shl 8) or (b[off + 1].toInt() and 0xFF)
    fun u32(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 24) or ((b[off + 1].toInt() and 0xFF) shl 16) or
            ((b[off + 2].toInt() and 0xFF) shl 8) or (b[off + 3].toInt() and 0xFF)

    fun put16(b: ByteArray, off: Int, v: Int) {
        b[off] = ((v shr 8) and 0xFF).toByte(); b[off + 1] = (v and 0xFF).toByte()
    }

    fun put32(b: ByteArray, off: Int, v: Int) {
        b[off] = ((v shr 24) and 0xFF).toByte(); b[off + 1] = ((v shr 16) and 0xFF).toByte()
        b[off + 2] = ((v shr 8) and 0xFF).toByte(); b[off + 3] = (v and 0xFF).toByte()
    }

    fun be32(v: Int): ByteArray = ByteArray(4).also { put32(it, 0, v) }

    /** Parses the payload chain that starts right after the ISAKMP header. */
    fun parsePayloads(msg: ByteArray, hdrLen: Int = IkeVal.HDR): List<IkePayload> {
        val out = ArrayList<IkePayload>()
        if (msg.size < hdrLen) return out
        var next = msg[16].toInt() and 0xFF
        var off = hdrLen
        while (next != 0 && off + 4 <= msg.size) {
            val len = u16(msg, off + 2)
            if (len < 4 || off + len > msg.size) break
            val p = IkePayload(next, msg.copyOfRange(off + 4, off + len))
            p.full = msg.copyOfRange(off, off + len)
            out.add(p)
            next = msg[off].toInt() and 0xFF
            off += len
        }
        return out
    }

    /** Builds a payload chain; each entry = type to body. */
    fun buildChain(payloads: List<Pair<Int, ByteArray>>): ByteArray {
        var total = 0
        for ((_, body) in payloads) total += 4 + body.size
        val out = ByteArray(total)
        var off = 0
        for ((i, p) in payloads.withIndex()) {
            val (type, body) = p
            out[off] = if (i + 1 < payloads.size) payloads[i + 1].first.toByte() else 0
            out[off + 1] = 0
            put16(out, off + 2, 4 + body.size)
            System.arraycopy(body, 0, out, off + 4, body.size)
            off += 4 + body.size
        }
        return out
    }

    fun header(
        ckyI: ByteArray, ckyR: ByteArray, nextPayload: Int, exchange: Int,
        flags: Int, messageId: Int, totalLen: Int,
    ): ByteArray {
        val h = ByteArray(IkeVal.HDR)
        System.arraycopy(ckyI, 0, h, 0, 8)
        System.arraycopy(ckyR, 0, h, 8, 8)
        h[16] = nextPayload.toByte()
        h[17] = IkeVal.V1.toByte()
        h[18] = exchange.toByte()
        h[19] = flags.toByte()
        put32(h, 20, messageId)
        put32(h, 24, totalLen)
        return h
    }

    fun tv(cls: Int, value: Int): ByteArray {
        val a = ByteArray(4)
        put16(a, 0, 0x8000 or cls)
        put16(a, 2, value)
        return a
    }

    /** Variable-length attribute: AF bit MUST be 0 (RFC 2408 §3.3). */
    fun tlv(cls: Int, value: ByteArray): ByteArray {
        val a = ByteArray(4 + value.size)
        put16(a, 0, cls and 0x3FFF)
        put16(a, 2, value.size)
        System.arraycopy(value, 0, a, 4, value.size)
        return a
    }

    /** Minimal synthetic header for parsing a DECRYPTED payload body: first
     * payload type lives in usable[0], so the header's nextPayload mirrors it. */
    fun decryptedHeader(firstPayloadType: Int): ByteArray {
        val h = ByteArray(IkeVal.HDR)
        h[16] = firstPayloadType.toByte()
        return h
    }

    /** Wraps a payload body with the generic 4-byte header (next, res, len). */
    fun generic(next: Int, body: ByteArray): ByteArray {
        val out = ByteArray(4 + body.size)
        out[0] = next.toByte()
        put16(out, 2, out.size)
        System.arraycopy(body, 0, out, 4, body.size)
        return out
    }

    /** Phase-1 SA payload BODY (RFC 2408: DOI/SIT + proposal payload + transform payloads).
     * Attribute layout mirrors what live SoftEther accepts (TV lifetime, group per transform). */
    fun phase1SaBody(): ByteArray {
        val life = tv(IkeVal.A_LIFETYPE, IkeVal.LIFETYPE_SECONDS) + tv(IkeVal.A_LIFEDUR, 3600)
        // Phase-1 Oakley attributes: AES is a single value (7) here; key length
        // is a separate attribute (MUST be omitted for fixed-length ciphers).
        fun tAttrs(enc: Int, keyLen: Int?, group: Int) =
            tv(IkeVal.A_ENC, enc) +
                (if (keyLen != null) tv(IkeVal.A_KEYLEN, keyLen) else ByteArray(0)) +
                tv(IkeVal.A_HASH, IkeVal.HASH_SHA1) +
                tv(IkeVal.A_GROUP, group) +
                tv(IkeVal.A_AUTHMETH, IkeVal.AUTH_PSK) + life
        fun transform(num: Int, next: Int, attrs: ByteArray): ByteArray {
            // RFC 2408 §3.6: generic(4) + transform#(1) + transform-id(1) + RESERVED2(2) + attributes
            val inner = byteArrayOf(num.toByte(), IkeVal.T_KEY_IKE.toByte(), 0, 0) + attrs
            return generic(next, inner)
        }
        val t1 = transform(1, IkeVal.PT_TRANSFORM, tAttrs(7, 256, IkeVal.GROUP14))
        val t2 = transform(2, IkeVal.PT_TRANSFORM, tAttrs(7, 128, 2))
        val t3 = transform(3, 0, tAttrs(IkeVal.ENC_3DES, null, 2))
        val propInner = byteArrayOf(1, IkeVal.PROTO_ISAKMP.toByte(), 0, 3) + t1 + t2 + t3
        val doi = be32(IkeVal.DOI_IPSEC) + be32(1)
        return doi + generic(0, propInner)
    }

    class ChosenTransform(val encId: Int, val hashId: Int, val authId: Int, val groupId: Int, val keyLen: Int)

    /** Reads the responder's selected transform out of a phase-1 SA payload body.
     * Layout (RFC 2408): DOI(4) SIT(4) | prop generic(4) | # proto spisz ntrans | SPI | transforms... */
    fun parseChosenTransform(saBody: ByteArray): ChosenTransform? {
        if (saBody.size < 20) return null
        val spisz = saBody[14].toInt() and 0xFF
        var off = 16 + spisz
        var enc = 0; var hash = 0; var auth = 0; var group = 0; var keyLen = 0
        var guard = 0
        while (off + 8 <= saBody.size && guard < 64) {
            guard++
            val tlen = u16(saBody, off + 2)
            if (tlen < 8 || off + tlen > saBody.size) return null
            var aoff = off + 8 // generic(4) + transform#/id(2) + RESERVED2(2)
            val aend = off + tlen
            while (aoff + 4 <= aend) {
                val attr = u16(saBody, aoff)
                val cls = attr and 0x3FFF
                if ((attr and 0x8000) != 0) {
                    val value = u16(saBody, aoff + 2)
                    when (cls) {
                        IkeVal.A_ENC -> enc = value
                        IkeVal.A_HASH -> hash = value
                        IkeVal.A_AUTHMETH -> auth = value
                        IkeVal.A_GROUP -> group = value
                        IkeVal.A_KEYLEN -> keyLen = value
                    }
                    aoff += 4
                } else {
                    aoff += 4 + u16(saBody, aoff + 2)
                }
            }
            if (enc != 0) break
            off += tlen
        }
        if (enc == 0) return null
        return ChosenTransform(enc, hash, auth, group, keyLen)
    }


    /** NAT-D hash (RFC 3947 §3.2): unkeyed hash(CKY-I | CKY-R | IP | Port). */
    fun natd(ckyI: ByteArray, ckyR: ByteArray, ip: ByteArray, port: Int): ByteArray =
        IkeCrypto.sha1(ckyI, ckyR, ip, byteArrayOf(((port shr 8) and 0xFF).toByte(), (port and 0xFF).toByte()))
}

internal class EspSa(
    val spiIn: Int,
    val spiOut: Int,
    val encId: Int,
    // outbound (us -> server) keys derive from spiOut, inbound from spiIn
    val encKey: ByteArray,
    val authKey: ByteArray,
    val encKeyIn: ByteArray,
    val authKeyIn: ByteArray,
)

internal class IkeInitiator(
    private var sock: DatagramSocket,
    private val server: InetAddress,
    private val psk: ByteArray,
    private val log: (String) -> Unit = {},
    /** Called right after the NAT-T float rebinds the socket to :4500 — the
     *  Android VPN protect must be re-applied or the new socket's traffic
     *  would be routed into the TUN and blackholed. */
    private val onSocketRebound: (DatagramSocket) -> Unit = {},
) {
    val ckyI = IkeCrypto.randBytes(8)
    var ckyR = ByteArray(8); private set
    private var saIB = ByteArray(0)
    private var gxi = ByteArray(0)
    private var gxr = ByteArray(0)
    private var niB = ByteArray(0)
    private var nrB = ByteArray(0)
    private var priv = BigInteger.ZERO
    private var chosen: Isakmp.ChosenTransform? = null
    private var skeyid = ByteArray(0)
    private var skeyidA = ByteArray(0)
    private var skeyidD = ByteArray(0)
    private var skeyidE = ByteArray(0)
    private var phase1EncKey = ByteArray(0)
    private var ivCurrent = ByteArray(0)
    private val block get() = IkeCrypto.blockBytes(chosen?.encId ?: IkeVal.ENC_AES256)

    var floated = false; private set

    /** The socket currently in use (rebound to :4500 after NAT-T float). */
    fun channelSocket(): DatagramSocket = sock
    var phase1Up = false; private set
    var esp: EspSa? = null; private set

    private var peerPort = 500
    private val vid3947 = IkeCrypto.md5("RFC 3947".toByteArray(Charsets.US_ASCII))
    private val vidNatTDraft02 = hexBytes("09002689dfd6b712")
    private val vidNatTDraft01 = hexBytes("afcad71368a1f1c96b8696fc77570100")
    private val vidMsNt5 = hexBytes("4a131c81070358455c5728f20e95452f")
    private val vidFrag = hexBytes("4048b7d56ebce88525e7de7f00d6c2d3c0000000")

    private fun hexBytes(s: String): ByteArray {
        val out = ByteArray(s.length / 2)
        for (i in out.indices) out[i] = s.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        return out
    }

    private fun sendIke(bytes: ByteArray, toPort: Int = peerPort) {
        val payload = if (toPort == 4500) byteArrayOf(0, 0, 0, 0) + bytes else bytes
        sock.send(DatagramPacket(payload, payload.size, server, toPort))
    }

    private fun recvIke(timeoutMs: Int): ByteArray? {
        sock.soTimeout = timeoutMs
        val buf = ByteArray(65536)
        return try {
            val dp = DatagramPacket(buf, buf.size)
            sock.receive(dp)
            log("rx ${dp.length}B from ${dp.address.hostAddress}:${dp.port} hex=" +
                dp.data.take(28).joinToString("") { "%02x".format(it) })
            if (!dp.address.equals(server)) null else {
                var data = buf.copyOf(dp.length)
                // RFC 3948 §2.1: IKE-on-4500 carries a 4-byte NON-ESP marker
                if (dp.port == 4500 && data.size >= 4 &&
                    data[0].toInt() == 0 && data[1].toInt() == 0 && data[2].toInt() == 0 && data[3].toInt() == 0
                ) {
                    data = data.copyOfRange(4, data.size)
                }
                data
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun recvExpected(wantEnc: Boolean, retries: Int = 4, exchange: Int = -1, nextPayload: Int = -1): ByteArray? {
        for (attempt in 0 until retries) {
            val msg = recvIke(3500) ?: continue
            if (msg.size < IkeVal.HDR) { log("drop: short ${msg.size}B"); continue }
            val enc = (msg[19].toInt() and IkeVal.FL_ENC) != 0
            if (enc != wantEnc) { log("drop: enc=$enc want=$wantEnc"); continue }
            if (!msg.copyOfRange(0, 8).contentEquals(ckyI)) {
                log("drop: ckyI mismatch ours=${ckyI.h()} theirs=${msg.copyOfRange(0, 8).h()}")
                continue
            }
            if (exchange >= 0 && (msg[18].toInt() and 0xFF) != exchange) {
                log("drop: exchange=${msg[18].toInt() and 0xFF} want=$exchange (retransmit?)")
                // Informational (5): decrypt with phase-1 key, IV = hash(phase1 IV | its msgid)
                if ((msg[18].toInt() and 0xFF) == 5 && (msg[19].toInt() and 0x01) != 0 && phase1Up) {
                    try {
                        val imid = msg.copyOfRange(20, 24)
                        val iiv = IkeCrypto.sha1(ivCurrent, imid).copyOfRange(0, block)
                        val body = msg.copyOfRange(IkeVal.HDR, msg.size)
                        val plain = IkeCrypto.cbc(phase1EncKey, iiv, body, false, chosen!!.encId)
                        val ps = Isakmp.parsePayloads(
                            Isakmp.decryptedHeader(msg[16].toInt() and 0xFF) + plain, IkeVal.HDR
                        )
                        for (p in ps) {
                            if (p.type == IkeVal.PT_NOTIFY && p.body.size >= 6) {
                                val ntype = ((p.body[4].toInt() and 0xFF) shl 8) or (p.body[5].toInt() and 0xFF)
                                log("NOTIFY type=$ntype spi=${p.body.size - 12}B body0=${p.body.copyOfRange(12, minOf(p.body.size, 20)).h()}")
                            } else {
                                log("info payload type=${p.type} len=${p.full.size}")
                            }
                        }
                    } catch (e: Exception) {
                        log("info decrypt failed: ${e.message}")
                    }
                }
                continue
            }
            if (nextPayload >= 0 && (msg[16].toInt() and 0xFF) != nextPayload) {
                log("drop: next=${msg[16].toInt() and 0xFF} want=$nextPayload (retransmit?)"); continue
            }
            return msg
        }
        return null
    }

    private fun ByteArray.h(): String = joinToString("") { "%02x".format(it) }

    fun establishPhase1(localIp: ByteArray) {
        // --- msg 1: HDR, SA, VID(NAT-T x2), VID(MS NT5), VID(frag)
        // saIB keeps ONLY the SA payload body (RFC 2409: SAi_b for HASH_I)
        saIB = Isakmp.phase1SaBody()
        val chain1 = Isakmp.buildChain(
            listOf(
                IkeVal.PT_SA to saIB,
                IkeVal.PT_VID to vidNatTDraft02,
                IkeVal.PT_VID to vidNatTDraft01,
                IkeVal.PT_VID to vid3947,
                IkeVal.PT_VID to vidMsNt5,
                IkeVal.PT_VID to vidFrag,
            )
        )
        val msg1 = Isakmp.header(ckyI, ByteArray(8), IkeVal.PT_SA, IkeVal.EX_MAIN, 0, 0, IkeVal.HDR + chain1.size) + chain1
        sendIke(msg1, 500)
        log("IKE msg1 sent (offer AES256/AES128/3DES + SHA1 + PSK + G14)")

        // --- msg 2: HDR, SA, VID...
        val msg2 = recvExpected(false) ?: throw IllegalStateException("no IKE msg2")
        System.arraycopy(msg2, 8, ckyR, 0, 8)
        val payloads2 = Isakmp.parsePayloads(msg2)
        val saP2 = payloads2.firstOrNull { it.type == IkeVal.PT_SA } ?: throw IllegalStateException("msg2 lacks SA")
        chosen = Isakmp.parseChosenTransform(saP2.body) ?: throw IllegalStateException("msg2 transform unparsable")
        var sawNatT = false
        for (v in payloads2.filter { it.type == IkeVal.PT_VID }) {
            if (v.body.size >= 16 && v.body.copyOfRange(0, 16).contentEquals(vid3947)) sawNatT = true
        }
        log("IKE msg2: enc=${chosen!!.encId} keyLen=${chosen!!.keyLen} hash=${chosen!!.hashId} auth=${chosen!!.authId} group=${chosen!!.groupId} natT_vid=$sawNatT")
        if (chosen!!.groupId != IkeVal.GROUP14) throw IllegalStateException("server chose unsupported group ${chosen!!.groupId}")
        if (chosen!!.hashId != IkeVal.HASH_SHA1) throw IllegalStateException("server chose unsupported hash ${chosen!!.hashId}")

        // --- msg 3: HDR, KE, Ni
        priv = BigInteger(2047, SecureRandom())
        gxi = IkeCrypto.dhPublic(IkeCrypto.G14_P, priv)
        niB = IkeCrypto.randBytes(16)
        val chain3 = Isakmp.buildChain(listOf(IkeVal.PT_KE to gxi, IkeVal.PT_NONCE to niB))
        val msg3 = Isakmp.header(ckyI, ckyR, IkeVal.PT_KE, IkeVal.EX_MAIN, 0, 0, IkeVal.HDR + chain3.size) + chain3
        sendIke(msg3, 500)
        log("IKE msg3 sent (KE ${gxi.size}B, Ni 16B)")

        // --- msg 4: HDR, KE, Nr, VID..., NAT-D...
        val msg4 = recvExpected(false) ?: throw IllegalStateException("no IKE msg4")
        val payloads4 = Isakmp.parsePayloads(msg4)
        gxr = payloads4.firstOrNull { it.type == IkeVal.PT_KE }?.body ?: throw IllegalStateException("msg4 lacks KE")
        nrB = payloads4.firstOrNull { it.type == IkeVal.PT_NONCE }?.body ?: throw IllegalStateException("msg4 lacks Nonce")
        var natdCount = 0
        for (n in payloads4.filter { it.type == IkeVal.PT_NOTIFY }) {
            if (n.body.size >= 6) {
                val ntype = ((n.body[4].toInt() and 0xFF) shl 8) or (n.body[5].toInt() and 0xFF)
                if (ntype == IkeVal.NOTIFY_NATD) natdCount++
            }
        }
        log("IKE msg4: KE ${gxr.size}B Nr ${nrB.size}B natd=$natdCount")

        val shared = IkeCrypto.dhShared(IkeCrypto.G14_P, priv, gxr)
        skeyid = IkeCrypto.hmacSha1(psk, niB, nrB)
        skeyidD = IkeCrypto.hmacSha1(skeyid, shared, ckyI, ckyR, byteArrayOf(0))
        skeyidA = IkeCrypto.hmacSha1(skeyid, skeyidD, shared, ckyI, ckyR, byteArrayOf(1))
        skeyidE = IkeCrypto.hmacSha1(skeyid, skeyidA, shared, ckyI, ckyR, byteArrayOf(2))
        val keyLen = chosen!!.keyLen
        val keyBytes = if (keyLen > 0) keyLen / 8 else IkeCrypto.keyBytes(chosen!!.encId)
        phase1EncKey = IkeCrypto.expandKey(skeyidE, keyBytes)
        ivCurrent = IkeCrypto.sha1(gxi, gxr).copyOfRange(0, block)
        log("IKE keys derived (shared ${shared.size}B, block=$block)")

        if (sawNatT || natdCount > 0) {
            floated = true
            peerPort = 4500
            // the initiator floats its SOURCE port to 4500 as well
            sock.close()
            sock = DatagramSocket(4500)
            runCatching { onSocketRebound(sock) }
            log("IKE floating to UDP/4500 (NAT-T)")
        }

        // --- msg 5: HDR*, IDii, HASH_I
        val idBody = byteArrayOf(1, 17, 0, 0) + localIp
        val hashI = IkeCrypto.hmacSha1(skeyid, gxi, gxr, ckyI, ckyR, saIB, idBody)
        val chain5 = Isakmp.buildChain(listOf(IkeVal.PT_ID to idBody, IkeVal.PT_HASH to hashI))
        val enc5 = encrypt(chain5, ivCurrent)
        // RFC 2409: IV of the NEXT message = last ciphertext block of this one
        ivCurrent = enc5.data.copyOfRange(enc5.data.size - block, enc5.data.size)
        // the CBC IV for msgs 5/6 is implicit — NOT sent on the wire
        val m5 = Isakmp.header(ckyI, ckyR, IkeVal.PT_ID, IkeVal.EX_MAIN, IkeVal.FL_ENC, 0, IkeVal.HDR + enc5.data.size) +
            enc5.data
        sendIke(m5)
        log("IKE msg5 sent (ct ${enc5.data.size}B) floated=$floated")

        // --- msg 6: HDR*, IDir, HASH_R  (IV = last ciphertext block of msg5)
        val msg6 = recvExpected(true, exchange = IkeVal.EX_MAIN, nextPayload = IkeVal.PT_ID)
            ?: throw IllegalStateException("no IKE msg6 (auth)")
        val body6 = msg6.copyOfRange(IkeVal.HDR, msg6.size)
        val plain6 = IkeCrypto.cbc(phase1EncKey, ivCurrent, body6, false, chosen!!.encId)
        // no pad stripping: the payload chain terminates with next=0 and the parser
        // never reaches trailing pad bytes (pad count heuristics misfire on random data)
        val usable6 = plain6
        ivCurrent = body6.copyOfRange(body6.size - block, body6.size)
        log("msg6 plain[0..16]=${plain6.take(16).toByteArray().h()} usable=${usable6.size}B first=0x%02x".format(usable6[0].toInt() and 0xFF))
        val payloads6 = Isakmp.parsePayloads(Isakmp.decryptedHeader(msg6[16].toInt() and 0xFF) + usable6, IkeVal.HDR)
        log("msg6 payloads: " + payloads6.joinToString { "t${it.type}/${it.full.size}B" })
        val idir = payloads6.firstOrNull { it.type == IkeVal.PT_ID }?.body ?: throw IllegalStateException("msg6 lacks ID")
        val hashR = payloads6.firstOrNull { it.type == IkeVal.PT_HASH }?.body ?: throw IllegalStateException("msg6 lacks HASH")
        val expectedHashR = IkeCrypto.hmacSha1(skeyid, gxr, gxi, ckyR, ckyI, saIB, idir)
        if (!hashR.contentEquals(expectedHashR)) throw IllegalStateException("HASH_R mismatch (wrong PSK?)")
        phase1Up = true
        log("IKE PHASE1_UP (peer ID ${idir.size}B accepted as-is)")
    }

    private class EncResult(val iv: ByteArray, val data: ByteArray)

    private fun encrypt(plainPayloads: ByteArray, iv: ByteArray): EncResult {
        var pad = block - (plainPayloads.size % block)
        if (pad == 0) pad = block
        val plain = ByteArray(plainPayloads.size + pad)
        System.arraycopy(plainPayloads, 0, plain, 0, plainPayloads.size)
        plain[plain.size - 1] = pad.toByte()
        val ct = IkeCrypto.cbc(phase1EncKey, iv, plain, true, chosen!!.encId)
        return EncResult(iv.copyOf(iv.size), ct)
    }

    // ------------------------------------------------------------- phase 2

    fun negotiateChild() {
        require(phase1Up) { "phase 1 not established" }
        val midBytes = IkeCrypto.randBytes(4)
        val mid = Isakmp.u32(midBytes, 0)
        val encId = chosen!!.encId
        val espTransform = if (encId == IkeVal.ENC_3DES) IkeVal.T_ESP_3DES else IkeVal.T_ESP_AES
        // mirror the phase-1 choice for the ESP key length (SoftEther pairs aes256/sha1)
        val keyBits = if (encId == IkeVal.ENC_3DES) 168 else (chosen!!.keyLen.takeIf { it > 0 } ?: 128)
        val spiInBytes = IkeCrypto.randBytes(4)
        val spiIn = Isakmp.u32(spiInBytes, 0)
        val ni2 = IkeCrypto.randBytes(16)

        // QM SA body (RFC 2407 IPSEC DOI attributes)
        val tf =
            Isakmp.tv(IkeVal.P2_LIFETYPE, IkeVal.LIFETYPE_SECONDS) +
            Isakmp.tv(IkeVal.P2_LIFEDUR, 3600) +
            // NAT-transport capsule (IANA UDP Transport Encapsulation = 4):
            // SoftEther rejects plain transport(2) unless it has a raw-ESP listener.
            Isakmp.tv(IkeVal.P2_ENCAP, 4) +
            Isakmp.tv(IkeVal.P2_AUTHALG, IkeVal.AUTHALG_HMAC_SHA) +
            Isakmp.tv(IkeVal.P2_KEYLEN, keyBits)
        val doi = ByteArray(8)
        Isakmp.put32(doi, 0, IkeVal.DOI_IPSEC)
        Isakmp.put32(doi, 4, 1)
        val tInner = byteArrayOf(1, espTransform.toByte(), 0, 0) + tf
        val transform = Isakmp.generic(0, tInner)
        val propInner = byteArrayOf(1, IkeVal.PROTO_ESP.toByte(), 4, 1) + spiInBytes + transform
        val saBody = doi + Isakmp.generic(0, propInner)
        val saI2Full = Isakmp.buildChain(listOf(IkeVal.PT_SA to saBody))

        // QM IV = hash(phase1 last IV | M-ID)
        val qmIv = IkeCrypto.sha1(ivCurrent, midBytes).copyOfRange(0, block)

        // RFC 2409 §5.5: HASH(1) = prf(SKEYID_a, M-ID | SA | Ni) — "the entire
        // message that follows the hash including all payload headers"
        // RFC 2409 §5.5 / SoftEther Proto_IKE.c: HASH(1) = prf(SKEYID_a, M-ID | bytes-after-hash
        // (SA and Nonce payloads INCLUDING their generic headers — byte-identical to the wire)
        val afterHash = Isakmp.buildChain(listOf(IkeVal.PT_SA to saBody, IkeVal.PT_NONCE to ni2))
        val hash1 = IkeCrypto.hmacSha1(skeyidA, midBytes, afterHash)
        // ONE chain so the HASH payload's next-payload points at SA (a lone buildChain
        // sets next=0 and the responder's parser would stop right after the HASH).
        val chain = Isakmp.buildChain(listOf(IkeVal.PT_HASH to hash1, IkeVal.PT_SA to saBody, IkeVal.PT_NONCE to ni2))
        val enc1 = encrypt(chain, qmIv)
        val m1 = Isakmp.header(ckyI, ckyR, IkeVal.PT_HASH, IkeVal.EX_QM, IkeVal.FL_ENC, mid, IkeVal.HDR + enc1.data.size) +
            enc1.data
        sendIke(m1)
        log("QM msg1 sent (mid=$mid spi_in=${spiIn.toString(16)} enc=$encId keyBits=$keyBits)")

        // QM msg2: HDR*, HASH(2), SA, Nr  (IV = last ct block of QM msg1)
        val msg2 = recvExpected(true, exchange = IkeVal.EX_QM, nextPayload = IkeVal.PT_HASH)
            ?: throw IllegalStateException("no QM msg2")
        val body2 = msg2.copyOfRange(IkeVal.HDR, msg2.size)
        val plain2 = IkeCrypto.cbc(phase1EncKey, enc1.data.copyOfRange(enc1.data.size - block, enc1.data.size), body2, false, encId)
        val usable2 = plain2
        ivCurrent = body2.copyOfRange(body2.size - block, body2.size)
        val payloads2 = Isakmp.parsePayloads(Isakmp.decryptedHeader(msg2[16].toInt() and 0xFF) + usable2, IkeVal.HDR)
        val saR = payloads2.firstOrNull { it.type == IkeVal.PT_SA } ?: throw IllegalStateException("QM msg2 lacks SA")
        val nrP = payloads2.firstOrNull { it.type == IkeVal.PT_NONCE }?.body ?: throw IllegalStateException("QM msg2 lacks Nonce")
        val hash2 = payloads2.firstOrNull { it.type == IkeVal.PT_HASH }?.body ?: throw IllegalStateException("QM msg2 lacks HASH")
        val nrFull = payloads2.firstOrNull { it.type == IkeVal.PT_NONCE }?.full
            ?: throw IllegalStateException("QM msg2 lacks Nonce")
        val expected2 = IkeCrypto.hmacSha1(skeyidA, midBytes, ni2, saR.full, nrFull)
        if (!hash2.contentEquals(expected2)) throw IllegalStateException("QM HASH(2) mismatch")
        val spiOut = parseEspSpi(saR.body) ?: throw IllegalStateException("QM SA lacks ESP SPI")
        log("QM msg2 ok (spi_out=${spiOut.toString(16)})")

        // QM msg3: HDR*, HASH(3)  (IV = last ct block of QM msg2 = ivCurrent)
        val hash3 = IkeCrypto.hmacSha1(skeyidA, byteArrayOf(0), midBytes, ni2, nrP)
        val chain3 = Isakmp.buildChain(listOf(IkeVal.PT_HASH to hash3))
        val enc3 = encrypt(chain3, ivCurrent)
        val m3 = Isakmp.header(ckyI, ckyR, IkeVal.PT_HASH, IkeVal.EX_QM, IkeVal.FL_ENC, mid, IkeVal.HDR + enc3.data.size) +
            enc3.data
        sendIke(m3)
        log("QM msg3 sent — CHILD_SA negotiated")

        // Each direction keys off ITS OWN SPI (the SA destination's SPI)
        // key size = the KEYLEN we proposed (the server picks our single transform);
        // 3DES uses a fixed 24-byte key. NEVER derive from keyBytes() alone:
        // IkeVal enc ids 5/7 are AES-256/192-class values, not 128.
        val keyLen = if (encId == IkeVal.ENC_3DES) 24 else keyBits / 8
        val matOut = keymat(spiOut, ni2, nrP, keyLen + 20)
        val matIn = keymat(spiIn, ni2, nrP, keyLen + 20)
        esp = EspSa(
            spiIn = spiIn,
            spiOut = spiOut,
            encId = encId,
            encKey = matOut.copyOfRange(0, keyLen),
            authKey = matOut.copyOfRange(keyLen, keyLen + 20),
            encKeyIn = matIn.copyOfRange(0, keyLen),
            authKeyIn = matIn.copyOfRange(keyLen, keyLen + 20),
        )
    }

    private fun parseEspSpi(saBody: ByteArray): Int? {
        if (saBody.size < 20) return null
        val spisz = saBody[14].toInt() and 0xFF
        if (spisz != 4) return null
        return Isakmp.u32(saBody, 16)
    }

    private fun keymat(spiIn: Int, ni: ByteArray, nr: ByteArray, wanted: Int): ByteArray {
        val seed = byteArrayOf(IkeVal.PROTO_ESP.toByte()) + Isakmp.be32(spiIn) + ni + nr
        val k1 = IkeCrypto.hmacSha1(skeyidD, seed)
        if (k1.size >= wanted) return k1.copyOf(wanted)
        // K(n) = prf(SKEYID_d, K(n-1) | protocol | SPI | Ni_b | Nr_b)
        val blocks = ArrayList<ByteArray>()
        blocks.add(k1)
        var prev = k1
        while (blocks.sumOf { it.size } < wanted) {
            prev = IkeCrypto.hmacSha1(skeyidD, prev, seed)
            blocks.add(prev)
        }
        val out = ByteArray(wanted)
        var off = 0
        for (b in blocks) {
            val n = minOf(b.size, wanted - off)
            System.arraycopy(b, 0, out, off, n)
            off += n
            if (off >= wanted) break
        }
        return out
    }
}

/** ESP (RFC 2406) AES-CBC/3DES-CBC + HMAC-SHA1-96 protect/unwrap (transport). */
internal class EspChannel(
    private var sock: DatagramSocket,
    private val server: InetAddress,
    val sa: EspSa,
) {
    private val seq = AtomicLong(0)
    private val block = IkeCrypto.blockBytes(sa.encId)
    private val ivLen = block

    fun protect(innerUdpPacket: ByteArray): ByteArray {
        val s = (seq.incrementAndGet() and 0xFFFFFFFFL).toInt()
        val iv = IkeCrypto.randBytes(ivLen)
        // RFC 2406: [data][pad(1..n)][pad-length][next-header]
        var pad = block - ((innerUdpPacket.size + 2) % block)
        if (pad == block) pad = 0
        val plain = ByteArray(innerUdpPacket.size + pad + 2)
        System.arraycopy(innerUdpPacket, 0, plain, 0, innerUdpPacket.size)
        for (i in 0 until pad) plain[innerUdpPacket.size + i] = (i + 1).toByte()
        plain[plain.size - 2] = pad.toByte()
        plain[plain.size - 1] = 17 // IP_PROTO_UDP (transport mode)
        val ct = IkeCrypto.cbc(sa.encKey, iv, plain, true, sa.encId)
        val out = ByteArray(8 + ivLen + ct.size + 12)
        Isakmp.put32(out, 0, sa.spiOut)
        Isakmp.put32(out, 4, s)
        System.arraycopy(iv, 0, out, 8, ivLen)
        System.arraycopy(ct, 0, out, 8 + ivLen, ct.size)
        val icv = IkeCrypto.hmacSha1(sa.authKey, out.copyOfRange(0, 8 + ivLen + ct.size))
        System.arraycopy(icv, 0, out, 8 + ivLen + ct.size, 12)
        return out
    }

    fun sendUdp(sport: Int, dport: Int, payload: ByteArray) {
        val udp = ByteArray(8 + payload.size)
        Isakmp.put16(udp, 0, sport)
        Isakmp.put16(udp, 2, dport)
        Isakmp.put16(udp, 4, 8 + payload.size)
        Isakmp.put16(udp, 6, 0)
        System.arraycopy(payload, 0, udp, 8, payload.size)
        val espPkt = protect(udp)
        sock.send(DatagramPacket(espPkt, espPkt.size, server, 4500))
    }

    /** Returns the inner UDP payload (e.g. L2TP bytes) or null for non-ESP traffic. */
    fun unwrap(datagram: ByteArray): ByteArray? {
        if (datagram.size < 8 + ivLen + 12 + block) return null
        val spi = Isakmp.u32(datagram, 0)
        if (spi == 0) return null // IKE with NON-ESP marker
        if (spi != sa.spiIn) return null
        val ctLen = datagram.size - 8 - ivLen - 12
        val iv = datagram.copyOfRange(8, 8 + ivLen)
        val ct = datagram.copyOfRange(8 + ivLen, 8 + ivLen + ctLen)
        val macData = datagram.copyOfRange(0, 8 + ivLen + ctLen)
        val expect = IkeCrypto.hmacSha1(sa.authKeyIn, macData)
        val icv = datagram.copyOfRange(datagram.size - 12, datagram.size)
        if (!expect.copyOfRange(0, 12).contentEquals(icv)) return null
        val plain = IkeCrypto.cbc(sa.encKeyIn, iv, ct, false, sa.encId)
        val pad = (plain[plain.size - 2].toInt() and 0xFF)
        if (pad < 0 || plain.size - pad - 2 < 8) return null
        val inner = plain.copyOfRange(0, plain.size - pad - 2)
        if (inner.size < 8) return null
        return inner.copyOfRange(8, inner.size)
    }
}
