package dev.lui

import androidx.compose.runtime.Composable

// Extension host contract: the core creates `create-extension` nodes
// carrying an `identifier` (e.g. "outliner-editor") and a `fingerprint`
// for drift detection; the app registers composable builders per
// identifier. Properties arrive via set-extension-prop; host code emits
// named events with a values map the app reduces to the FFI (text,
// value) pair.
class LuiExtensionContext internal constructor(
    val node: LuiNode,
    private val backend: LuiBackend,
) {
    val id: Long get() = node.id
    val identifier: String get() = node.identifier.orEmpty()

    fun <T> property(name: String): T? {
        @Suppress("UNCHECKED_CAST")
        return node.properties[name] as? T
    }

    fun string(name: String): String? = node.string(name)
    fun int(name: String): Int? = node.int(name)
    fun double(name: String): Double? = node.double(name)
    fun flag(name: String): Boolean = node.flag(name)

    fun emit(name: String, values: Map<String, Any?>) {
        backend.dispatch(LuiEvent.Extension(node.id, identifier, name, values))
    }

    fun emit(name: String, vararg values: Pair<String, Any?>) =
        emit(name, mapOf(*values))

    // Renders the extension's standard children (extensions that accept
    // them — e.g. native-navigation-stack's pushed content).
    @Composable
    fun Children() {
        for (childId in node.children.toList()) {
            androidx.compose.runtime.key(childId) {
                LuiNodeView(backend, childId)
            }
        }
    }
}

fun interface LuiExtensionBuilder {
    @Composable
    fun Render(context: LuiExtensionContext)
}

class LuiExtensionRegistry {
    private data class Registration(
        val fingerprint: String?,
        val builder: LuiExtensionBuilder,
    )

    private val registrations = mutableMapOf<String, Registration>()

    fun register(
        identifier: String,
        fingerprint: String? = null,
        builder: LuiExtensionBuilder,
    ) {
        registrations[identifier] = Registration(fingerprint, builder)
    }

    fun unregister(identifier: String) {
        registrations.remove(identifier)
    }

    // Null → render the unknown-extension placeholder.
    // Mismatched fingerprints render an error surface instead of the
    // component (same contract as the other backends).
    fun resolve(node: LuiNode): Result<LuiExtensionBuilder> {
        val identifier = node.identifier ?: return Result.failure(
            IllegalStateException("node ${node.id} is not an extension")
        )
        val registration = registrations[identifier]
            ?: return Result.failure(NoSuchElementException(identifier))
        val expected = registration.fingerprint
        if (expected != null && expected != node.fingerprint) {
            return Result.failure(
                IllegalStateException(
                    "extension \"$identifier\" fingerprint mismatch: " +
                        "core sent \"${node.fingerprint}\", app registered \"$expected\""
                )
            )
        }
        return Result.success(registration.builder)
    }
}
