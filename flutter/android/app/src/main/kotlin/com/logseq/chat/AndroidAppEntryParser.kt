package com.logseq.chat

import java.net.URI

internal object AndroidAppEntryParser {
    fun deepLinkKind(value: String?): String? {
        val uri = value?.let { runCatching { URI(it) }.getOrNull() } ?: return null
        if (!uri.query.isNullOrEmpty() || !uri.fragment.isNullOrEmpty()) return null
        if (!uri.path.isNullOrEmpty()) return null
        if (!uri.scheme.equals("logseqchat", ignoreCase = true)) return null
        return when (uri.host?.lowercase()) {
            "journal" -> "open-journal"
            "capture" -> "open-capture"
            else -> null
        }
    }

    fun sharedBlockText(text: String?, title: String?): String? {
        val normalizedText = text?.trim()?.takeIf(String::isNotEmpty)
        var normalizedTitle = title?.trim()?.takeIf(String::isNotEmpty)
        if (normalizedText != null && normalizedTitle != null &&
            normalizedText.contains(normalizedTitle)
        ) {
            normalizedTitle = null
        }
        if (normalizedText == null && normalizedTitle == null) return null
        if (normalizedText != null && isWebUrl(normalizedText)) {
            return if (normalizedTitle == null || normalizedTitle == normalizedText) {
                normalizedText
            } else {
                "[$normalizedTitle]($normalizedText)"
            }
        }
        return listOfNotNull(normalizedText, normalizedTitle).joinToString("\n")
    }

    private fun isWebUrl(value: String): Boolean =
        value.startsWith("https://", ignoreCase = true) ||
            value.startsWith("http://", ignoreCase = true)
}
