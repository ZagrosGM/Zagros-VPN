package kittoku.osc

import android.content.SharedPreferences
import kittoku.osc.preference.OscPrefKey
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * Minimal in-memory SharedPreferences implementation seeded per connection by
 * the Zagros engine glue. Upstream accessors always pass explicit defaults, so
 * absent keys simply fall through. Values are never persisted to disk.
 */
internal class MapSharedPreferences(
    seed: Map<OscPrefKey, Any> = emptyMap(),
) : SharedPreferences {
    private val lock = ReentrantReadWriteLock()
    private val values = HashMap<String, Any>(seed.count() + 8).also { map ->
        seed.forEach { (key, value) -> map[key.name] = value }
    }

    fun set(key: OscPrefKey, value: Any) {
        lock.write { values[key.name] = value }
    }

    private fun raw(key: String): Any? = lock.read { values[key] }

    override fun getAll(): Map<String, *> = lock.read { java.util.Map.copyOf(values) }

    override fun getString(key: String, defValues: String?): String? =
        raw(key) as? String ?: defValues

    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? {
        val value = raw(key) as? Set<*> ?: return defValues
        return value.map { it.toString() }.toMutableSet()
    }

    override fun getInt(key: String, defValue: Int): Int =
        raw(key) as? Int ?: defValue

    override fun getLong(key: String, defValue: Long): Long =
        raw(key) as? Long ?: defValue

    override fun getFloat(key: String, defValue: Float): Float =
        raw(key) as? Float ?: defValue

    override fun getBoolean(key: String, defValue: Boolean): Boolean =
        raw(key) as? Boolean ?: defValue

    override fun contains(key: String): Boolean = raw(key) != null

    override fun edit(): SharedPreferences.Editor = throw UnsupportedOperationException("read-only engine prefs")

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}

    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
}
