package kittoku.osc.extension

// ZAGROS ADAPTATION: only the pure-Kotlin helpers from upstream
// extension/String.kt are vendored; the Uri helper belongs to excluded UI code.

internal fun sum(vararg words: String): String {
    var result = ""

    words.forEach {
        result += it
    }

    return result
}
