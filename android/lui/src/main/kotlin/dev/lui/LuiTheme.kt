package dev.lui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.graphics.Color
import org.json.JSONObject

// Theme token scoping: nodes carry a `theme` prop — a JSON object mapping
// token names to either "#rrggbb[aa]" colors or {"light","dark"} adaptive
// pairs — and a `theme-mode` prop ("system"|"light"|"dark") that picks
// the effective brightness under this subtree.
data class LuiThemeTokens(val values: Map<String, Any?> = emptyMap()) {
    fun merge(raw: String?): LuiThemeTokens {
        if (raw.isNullOrEmpty()) return this
        val decoded = try {
            JSONObject(raw)
        } catch (_: Exception) {
            return this
        }
        val merged = values.toMutableMap()
        for (key in decoded.keys()) merged[key.lowercase()] = decoded.opt(key)
        return LuiThemeTokens(merged)
    }

    // Token value → color string for the active brightness.
    fun resolve(name: String?, dark: Boolean): String? {
        val value = values[name?.lowercase()] ?: return null
        return when (value) {
            is String -> value
            is JSONObject -> (if (dark) value.optString("dark") else value.optString("light"))
                .takeIf(String::isNotEmpty)
            else -> null
        }
    }
}

val LocalLuiThemeTokens = compositionLocalOf { LuiThemeTokens() }
val LocalLuiThemeDark = compositionLocalOf { false }

object LuiTheme {
    // Named colors fall back through the same palette the other LUI
    // backends use (Material shadcn-style tokens, then base colors).
    @Composable
    @ReadOnlyComposable
    fun color(name: String?, foreground: Boolean = false): Color? {
        if (name == null) return null
        val dark = LocalLuiThemeDark.current
        val token = LocalLuiThemeTokens.current.resolve(name, dark)
        token?.let { parseColor(it) }?.let { return it }
        return schemeColor(name.lowercase(), MaterialTheme.colorScheme, foreground)
    }

    fun parseColor(value: String?): Color? {
        if (value == null) return null
        var raw = value.removePrefix("#")
        if (raw.length == 3 || raw.length == 4) {
            raw = raw.toCharArray().joinToString("") { "$it$it" }
        }
        if (raw.length == 6) raw = "ff$raw"
        else if (raw.length == 8) raw = raw.substring(6) + raw.substring(0, 6)
        if (raw.length != 8) return null
        val parsed = raw.toLongOrNull(16) ?: return null
        return Color(parsed)
    }

    private fun schemeColor(name: String, colors: ColorScheme, foreground: Boolean): Color? =
        when (name) {
            "transparent" -> Color.Transparent
            "background" -> colors.surface
            "foreground" -> colors.onSurface
            "surface" -> colors.surface
            "surface-container-lowest" -> colors.surfaceContainerLowest
            "surface-container-low" -> colors.surfaceContainerLow
            "surface-container" -> colors.surfaceContainer
            "surface-container-high" -> colors.surfaceContainerHigh
            "surface-container-highest" -> colors.surfaceContainerHighest
            "surface-variant" -> colors.surfaceContainerHighest
            "autocomplete-row-background" -> colors.surfaceContainerHigh
            "glass" -> colors.surface.copy(alpha = 0.75f)
            "glass-fallback" -> colors.surface.copy(alpha = 0.9f)
            "bar" -> colors.surface.copy(alpha = 0.85f)
            "primary" -> colors.primary
            "primary-foreground" -> colors.onPrimary
            "accent" -> if (foreground) colors.primary else colors.secondaryContainer
            "accent-foreground" ->
                if (foreground) colors.onPrimary else colors.onSecondaryContainer
            "secondary" ->
                if (foreground) colors.onSurfaceVariant else colors.secondaryContainer
            "secondary-foreground" -> colors.onSecondaryContainer
            "muted" -> colors.surfaceContainerHigh
            "muted-foreground" -> colors.onSurfaceVariant
            "destructive" -> colors.error
            "destructive-foreground" -> colors.onError
            "success" -> colors.tertiaryContainer
            "success-foreground" -> colors.onTertiaryContainer
            "warning" -> colors.secondaryContainer
            "warning-foreground" -> colors.onSecondaryContainer
            "error" -> colors.errorContainer
            "error-foreground" -> colors.onErrorContainer
            "border" -> colors.outlineVariant
            "black" -> Color.Black
            "white" -> Color.White
            "red" -> Color.Red
            "blue" -> Color.Blue
            "green" -> Color.Green
            "card" -> colors.surfaceContainerLowest
            else -> Color.Transparent
        }

    // Effective dark flag for a `theme-mode` prop value.
    @Composable
    fun darkForMode(mode: String?): Boolean = when (mode) {
        "light" -> false
        "dark" -> true
        else -> isSystemInDarkTheme()
    }

    @Composable
    fun Provider(mode: String?, content: @Composable () -> Unit) {
        val dark = darkForMode(mode)
        MaterialTheme(
            colorScheme = if (dark) darkColorScheme() else lightColorScheme(),
            content = content,
        )
    }

    @Composable
    fun NodeScope(node: LuiNode, content: @Composable () -> Unit) {
        val inherited = LocalLuiThemeTokens.current
        val themeProp = node.string("theme")
        val scoped = if (themeProp != null) inherited.merge(themeProp) else inherited
        val mode = node.string("theme-mode")
        val dark = if (mode != null) darkForMode(mode) else LocalLuiThemeDark.current
        if (scoped !== inherited || mode != null) {
            CompositionLocalProvider(
                LocalLuiThemeTokens provides scoped,
                LocalLuiThemeDark provides dark,
            ) { content() }
        } else {
            content()
        }
    }
}
