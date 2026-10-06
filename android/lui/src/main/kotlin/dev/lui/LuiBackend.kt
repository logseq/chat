package dev.lui

import android.util.Log
import androidx.compose.runtime.Composable
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

// Retained node store + patch-batch applier for the LUI wire protocol
// ({"generation": N, "ops": [...]}), plus the Compose entry point that
// renders it.
//
// Op vocabulary (shared/src ... lui_wire.ml):
//   create-node {id,kind}        create-extension {id,identifier,fingerprint}
//   drop-node {id}               set-prop / remove-prop {id,property[,value]}
//   set-extension-prop / remove-extension-prop
//   insert-child {parent,child,index}
//   remove-child {parent,child}
//   move-child   {parent,child,index}
class LuiBackend(
    val onEvent: (LuiEvent) -> Unit = {},
    val extensions: LuiExtensionRegistry = LuiExtensionRegistry(),
    val icons: LuiIconResolver = LuiIconResolver.DEFAULT,
) {
    private val nodes = LinkedHashMap<Long, LuiNode>()

    var generation: Long = 0
        private set

    fun node(id: Long): LuiNode? = nodes[id]

    fun childrenOf(id: Long): List<LuiNode> =
        nodes[id]?.children?.mapNotNull(nodes::get) ?: emptyList()

    fun clear() {
        nodes.clear()
        generation = 0
    }

    // Applies a patch batch. Returns true when anything changed; a
    // malformed batch is dropped and reported (the core sends "" on
    // error — the caller filters that out before we get here).
    fun applyJson(raw: String?): Boolean {
        if (raw.isNullOrEmpty()) return false
        val batch = try {
            JSONObject(raw)
        } catch (error: JSONException) {
            Log.w(TAG, "ignoring undecodable patch batch", error)
            return false
        }
        val ops = batch.optJSONArray("ops") ?: return false
        batch.optLong("generation").takeIf { it > 0 }?.let { generation = it }
        var changed = false
        for (index in 0 until ops.length()) {
            val op = ops.optJSONObject(index) ?: continue
            changed = applyOp(op) || changed
        }
        return changed
    }

    private fun applyOp(op: JSONObject): Boolean = when (op.optString("op")) {
        "create-node" -> {
            val id = op.getLong("id")
            nodes[id] = LuiNode(id, op.getString("kind"))
            true
        }
        "create-extension" -> {
            val id = op.getLong("id")
            LuiNode(id, "extension").also {
                it.identifier = op.getString("identifier")
                it.fingerprint = op.optString("fingerprint")
                nodes[id] = it
            }
            true
        }
        "drop-node" -> dropSubtree(op.getLong("id")) != null
        "set-prop" -> nodes[op.getLong("id")]?.let {
            it.properties[op.getString("property")] = op.opt("value")
            true
        } ?: false
        "remove-prop" -> nodes[op.getLong("id")]?.let {
            it.properties.remove(op.getString("property"))
            true
        } ?: false
        "set-extension-prop" -> nodes[op.getLong("id")]?.let {
            it.properties[op.getString("property")] = op.opt("value")
            true
        } ?: false
        "remove-extension-prop" -> nodes[op.getLong("id")]?.let {
            it.properties.remove(op.getString("property"))
            true
        } ?: false
        "insert-child" -> nodes[op.getLong("parent")]?.let { parent ->
            val child = op.getLong("child")
            val index = op.getInt("index").coerceIn(0, parent.children.size)
            parent.children.remove(child)
            parent.children.add(index, child)
            true
        } ?: false
        "remove-child" -> nodes[op.getLong("parent")]?.let {
            it.children.remove(op.getLong("child"))
        } ?: false
        "move-child" -> nodes[op.getLong("parent")]?.let { parent ->
            val child = op.getLong("child")
            parent.children.remove(child)
            val index = op.getInt("index").coerceIn(0, parent.children.size)
            parent.children.add(index, child)
            true
        } ?: false
        else -> {
            Log.w(TAG, "unknown patch op: ${op.optString("op")}")
            false
        }
    }

    private fun dropSubtree(id: Long): LuiNode? {
        val node = nodes.remove(id) ?: return null
        for (child in node.children.toList()) dropSubtree(child)
        return node
    }

    @Composable
    fun Content(rootId: Long) {
        LuiRoot(backend = this, rootId = rootId)
    }

    internal fun dispatch(event: LuiEvent) = onEvent(event)

    companion object {
        private const val TAG = "LuiBackend"
    }
}

internal fun JSONArray.stringList(): List<String> =
    (0 until length()).mapNotNull { optString(it).takeIf(String::isNotEmpty) }
