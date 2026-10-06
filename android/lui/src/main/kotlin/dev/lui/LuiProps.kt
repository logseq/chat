package dev.lui

import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.aspectRatio

// Wire property → Compose mapping shared by every renderer. Property
// names are the kebab-case identifiers of schema/components.json.

internal fun LuiNode.visible(): Boolean = !properties.containsKey("visible") || int("visible") != 0

@Composable
internal fun LuiNode.colorProp(name: String): Color? =
    LuiTheme.color(string(name))

@Composable
internal fun LuiNode.shape(): RoundedCornerShape =
    RoundedCornerShape((int("corner-radius") ?: 0).dp)

@Composable
internal fun LuiNode.styleModifier(): Modifier {
    var modifier: Modifier = Modifier
    int("width")?.let { modifier = modifier.width(it.dp) }
    int("height")?.let { modifier = modifier.height(it.dp) }
    int("min-width")?.let { modifier = modifier.widthIn(min = it.dp) }
    int("max-width")?.let { modifier = modifier.widthIn(max = it.dp) }
    int("min-height")?.let { modifier = modifier.heightIn(min = it.dp) }
    int("max-height")?.let { modifier = modifier.heightIn(max = it.dp) }
    when (string("sizing")) {
        "fill" -> modifier = modifier.fillMaxWidth()
        else -> {}
    }
    if (flag("fill-width")) modifier = modifier.fillMaxWidth()
    if (flag("fill-height") || flag("fill")) modifier = modifier.fillMaxHeight()
    if ((double("grow") ?: 0.0) > 0.0) modifier = modifier.fillMaxWidth()
    int("padding")?.let { modifier = modifier.padding(it.dp) }
    int("padding-horizontal")?.let { modifier = modifier.padding(horizontal = it.dp) }
    int("padding-vertical")?.let { modifier = modifier.padding(vertical = it.dp) }
    int("padding-top")?.let { modifier = modifier.padding(top = it.dp) }
    int("padding-bottom")?.let { modifier = modifier.padding(bottom = it.dp) }
    int("padding-start")?.let { modifier = modifier.padding(start = it.dp) }
    int("padding-end")?.let { modifier = modifier.padding(end = it.dp) }
    val opacity = double("opacity")
    if (opacity != null) modifier = modifier.alpha(opacity.toFloat().coerceIn(0f, 1f))
    string("accessibility-identifier")?.let { modifier = modifier.testTag(it) }
    string("accessibility-label")?.let { label ->
        modifier = modifier.semantics { contentDescription = label }
    }
    return modifier
}

@Composable
internal fun LuiNode.surfaceModifier(): Modifier {
    var modifier = styleModifier()
    val radius = shape()
    colorProp("background")?.let { modifier = modifier.background(it, radius) }
    val borderColor = colorProp("border-color")
    val borderWidth = int("border-width")
    if (borderColor != null && borderWidth != null && borderWidth > 0) {
        modifier = modifier.border(borderWidth.dp, borderColor, radius)
    }
    if ((int("corner-radius") ?: 0) > 0 || flag("clip")) {
        modifier = modifier.clip(radius)
    }
    return modifier
}

internal fun LuiNode.gapDp() = (int("gap") ?: 0).dp

internal fun LuiNode.mainAxisAlignment(): androidx.compose.foundation.layout.Arrangement.Horizontal =
    when (string("main")) {
        "center" -> androidx.compose.foundation.layout.Arrangement.Center
        "end" -> androidx.compose.foundation.layout.Arrangement.End
        "space-between" -> androidx.compose.foundation.layout.Arrangement.SpaceBetween
        "space-around" -> androidx.compose.foundation.layout.Arrangement.SpaceAround
        "space-evenly" -> androidx.compose.foundation.layout.Arrangement.SpaceEvenly
        else -> androidx.compose.foundation.layout.Arrangement.spacedBy(gapDp())
    }

internal fun LuiNode.mainAxisVertical(): androidx.compose.foundation.layout.Arrangement.Vertical =
    when (string("main")) {
        "center" -> androidx.compose.foundation.layout.Arrangement.Center
        "end", "bottom" -> androidx.compose.foundation.layout.Arrangement.Bottom
        "space-between" -> androidx.compose.foundation.layout.Arrangement.SpaceBetween
        "space-around" -> androidx.compose.foundation.layout.Arrangement.SpaceAround
        "space-evenly" -> androidx.compose.foundation.layout.Arrangement.SpaceEvenly
        else -> androidx.compose.foundation.layout.Arrangement.spacedBy(gapDp())
    }

internal fun LuiNode.crossAxisHorizontal(): androidx.compose.ui.Alignment.Horizontal =
    when (string("cross")) {
        "center" -> androidx.compose.ui.Alignment.CenterHorizontally
        "end" -> androidx.compose.ui.Alignment.End
        else -> androidx.compose.ui.Alignment.Start
    }

internal fun LuiNode.crossAxisVertical(): androidx.compose.ui.Alignment.Vertical =
    when (string("cross")) {
        "center" -> androidx.compose.ui.Alignment.CenterVertically
        "end", "bottom" -> androidx.compose.ui.Alignment.Bottom
        else -> androidx.compose.ui.Alignment.Top
    }

internal fun LuiNode.textAlign(): TextAlign? = when (string("text-alignment")) {
    "center" -> TextAlign.Center
    "end", "right" -> TextAlign.End
    "start", "left" -> TextAlign.Start
    "justify" -> TextAlign.Justify
    else -> null
}

@Composable
internal fun LuiNode.textStyle(): TextStyle {
    val base = when (string("size")) {
        "sm" -> MaterialTheme.typography.bodySmall
        "lg" -> MaterialTheme.typography.titleMedium
        "heading" -> MaterialTheme.typography.headlineSmall
        "display" -> MaterialTheme.typography.displaySmall
        "icon" -> MaterialTheme.typography.bodyMedium
        else -> MaterialTheme.typography.bodyMedium
    }
    return base.copy(
        color = colorProp("foreground") ?: MaterialTheme.colorScheme.onSurface,
        fontWeight = when (string("weight")) {
            "bold", "semibold" -> FontWeight.SemiBold
            "medium" -> FontWeight.Medium
            "light" -> FontWeight.Light
            else -> base.fontWeight
        },
        fontStyle = if (string("style") == "italic") FontStyle.Italic else base.fontStyle,
    )
}

@Composable
internal fun LuiNode.headingStyle(): TextStyle {
    val theme = MaterialTheme.typography
    val level = int("level") ?: int("heading-level") ?: 1
    val base = when (level) {
        1 -> theme.headlineLarge
        2 -> theme.headlineMedium
        3 -> theme.titleLarge
        4 -> theme.titleMedium
        5 -> theme.titleSmall
        else -> theme.labelLarge
    }
    return base.copy(color = colorProp("foreground") ?: MaterialTheme.colorScheme.onSurface)
}
