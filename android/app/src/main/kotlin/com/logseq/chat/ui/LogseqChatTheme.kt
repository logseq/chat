package com.logseq.chat.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Port of the former Dart theme — M3 fidelity scheme seeded
// on the chat accent; the light/dark surfaces match the previous theme so
// backend-side token lookups (surface-container-* names in LuiTheme)
// resolve to the same colors the previous app showed.
internal object LogseqChatTheme {
    val accent = Color(0xff2d6cdf)
    val lightSurface = Color(0xfff8f9ff)
    val darkSurface = Color(0xff101318)

    val lightScheme = lightColorScheme(
        primary = accent,
        surface = lightSurface,
        surfaceContainerLowest = Color(0xffffffff),
        surfaceContainerLow = Color(0xfff2f3f8),
        surfaceContainer = Color(0xffeceef4),
        surfaceContainerHigh = Color(0xffe6e8ef),
        surfaceContainerHighest = Color(0xffe0e2ea),
    )

    val darkScheme = darkColorScheme(
        primary = Color(0xff8fb5ff),
        surface = darkSurface,
        surfaceContainerLowest = Color(0xff0b0e12),
        surfaceContainerLow = Color(0xff14171d),
        surfaceContainer = Color(0xff181c22),
        surfaceContainerHigh = Color(0xff1d2229),
        surfaceContainerHighest = Color(0xff22272f),
    )
}

internal fun logseqChatThemeMode(appearance: String): String = when (appearance) {
    "light" -> "light"
    "dark" -> "dark"
    else -> "system"
}
