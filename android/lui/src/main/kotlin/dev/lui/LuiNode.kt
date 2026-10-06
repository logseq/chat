package dev.lui

import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf

// Retained UI node mirror, one per `create-node`/`create-extension` op on
// the LUI wire. Properties and children are Compose state so applying a
// patch batch recomposes only the touched subtrees.
class LuiNode internal constructor(
    val id: Long,
    var kind: String,
) {
    // Extension nodes carry `identifier`/`fingerprint` instead of a kind.
    var identifier: String? = null
    var fingerprint: String = ""

    val properties = mutableStateMapOf<String, Any?>()
    val children = mutableStateListOf<Long>()

    val isExtension: Boolean get() = identifier != null

    fun string(name: String): String? = properties[name] as? String
    fun int(name: String): Int? = (properties[name] as? Number)?.toInt()
    fun long(name: String): Long? = (properties[name] as? Number)?.toLong()
    fun double(name: String): Double? = (properties[name] as? Number)?.toDouble()
    fun bool(name: String): Boolean = (properties[name] as? Boolean) == true

    fun flag(name: String): Boolean = int(name) != 0 && properties.containsKey(name)

    fun enabled(name: String, default: Boolean = false): Boolean =
        if (properties.containsKey(name)) int(name) != 0 else default
}
