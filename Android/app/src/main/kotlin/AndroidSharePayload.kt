package logseq.chat

data class AndroidSharePayload(
    val text: String?,
    val title: String?
) {
    val blockText: String
        get() {
            if (text != null && isWebUrl(text)) {
                return if (title == null || title == text) text else "[$title]($text)"
            }
            return listOfNotNull(text, title).joinToString("\n")
        }

    companion object {
        fun normalized(text: String?, title: String?): AndroidSharePayload? {
            val normalizedText = text?.trim()?.takeIf(String::isNotEmpty)
            var normalizedTitle = title?.trim()?.takeIf(String::isNotEmpty)
            if (normalizedText != null && normalizedTitle != null && normalizedText.contains(normalizedTitle)) {
                normalizedTitle = null
            }
            if (normalizedText == null && normalizedTitle == null) return null
            return AndroidSharePayload(normalizedText, normalizedTitle)
        }

        private fun isWebUrl(value: String): Boolean {
            return value.startsWith("https://", ignoreCase = true) ||
                value.startsWith("http://", ignoreCase = true)
        }
    }
}
