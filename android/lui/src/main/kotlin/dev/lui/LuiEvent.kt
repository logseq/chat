package dev.lui

// User/host events produced by rendered nodes, dispatched back into the
// shared core. Mirrors the event surface of the other LUI backends
// (platform/android, platform/apple).
sealed class LuiEvent {
    abstract val node: Long

    data class Appear(override val node: Long) : LuiEvent()
    data class Press(override val node: Long) : LuiEvent()
    data class LongPress(override val node: Long) : LuiEvent()
    data class DoublePress(override val node: Long) : LuiEvent()
    data class Change(override val node: Long) : LuiEvent()
    data class Submit(override val node: Long) : LuiEvent()
    data class Dismiss(override val node: Long) : LuiEvent()
    data class TextChanged(override val node: Long, val text: String) : LuiEvent()
    data class ToggleChanged(override val node: Long, val checked: Boolean) : LuiEvent()
    data class ValueChanged(override val node: Long, val value: Double) : LuiEvent()
    data class Picked(override val node: Long, val payload: String) : LuiEvent()
    data class VisibleRange(override val node: Long, val first: Long, val last: Long) : LuiEvent()
    data class ScrollCompleted(override val node: Long, val token: Long, val outcome: String) : LuiEvent()

    // Extension host event: `values` mirrors the identifier/name-keyed
    // value map the host collects; the app layer reduces it to the
    // (text, value) pair the FFI boundary expects.
    data class Extension(
        override val node: Long,
        val identifier: String,
        val name: String,
        val values: Map<String, Any?>,
    ) : LuiEvent()
}
