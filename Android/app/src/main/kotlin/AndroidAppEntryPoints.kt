package logseq.chat

import java.net.URI

object AndroidAppEntryPoints {
    const val JOURNAL = "logseqchat://journal"
    const val CAPTURE = "logseqchat://capture"

    fun canonicalDeepLink(value: String?): String? {
        val uri = value?.let { runCatching { URI(it) }.getOrNull() } ?: return null
        if (!uri.query.isNullOrEmpty() || !uri.fragment.isNullOrEmpty()) return null
        if (!uri.path.isNullOrEmpty()) return null
        if (!uri.scheme.equals("logseqchat", ignoreCase = true)) return null
        return when (uri.host?.lowercase()) {
            "journal" -> JOURNAL
            "capture" -> CAPTURE
            else -> null
        }
    }
}
