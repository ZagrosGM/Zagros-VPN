package ai.zagros.tunnel.l2tp

/**
 * Compact stage trace for the raw-L2TP engine.
 *
 * The Dart layer only lets through sanitized failure codes
 * (^[a-z][a-z0-9_]{0,63}$), so on failure the recent stage marks are folded
 * into the code (e.g. engine_died_sccrp_rx_icrp_rx_lcp_ok) to make the death
 * stage visible in the app's Logs screen without leaking any credential or
 * free-form text.
 */
internal object L2tpTrace {
    private const val MAX_MARKS = 24
    private const val MAX_SAME_MARKS = 5

    private val marks = ArrayDeque<String>()

    @Volatile
    private var errorToken: String? = null

    /**
     * Records a sanitized token for the last engine error message, e.g.
     * "L2TP: LCP: ERR_TIMEOUT" -> "lcp_err_timeout". Shown in the app Logs
     * screen via the failure code; never contains credentials.
     */
    fun markError(message: String) {
        val cleaned = message.lowercase()
            .split(Regex("[^a-z0-9_]+"))
            .filter { it.isNotEmpty() }
            .joinToString("_")
        errorToken = cleaned.take(40).ifEmpty { null }
    }

    fun errorTokenOrNull(): String? = errorToken

    fun reset() = synchronized(marks) { marks.clear() }

    fun mark(token: String) = synchronized(marks) {
        if (marks.size >= MAX_MARKS) marks.removeFirst()
        marks.addLast(token)
    }

    /** Marks high-frequency events (per-packet) with a bounded repeat count. */
    fun markData(token: String) = synchronized(marks) {
        if (marks.count { it == token } < MAX_SAME_MARKS) mark(token)
    }

    /** Last marks joined with '_', trimmed to at most [maxChars] characters. */
    fun tail(maxChars: Int): String = synchronized(marks) {
        val joined = marks.joinToString("_")
        if (joined.length <= maxChars) {
            joined
        } else {
            joined.substring(joined.length - maxChars).trimStart('_')
        }
    }
}
