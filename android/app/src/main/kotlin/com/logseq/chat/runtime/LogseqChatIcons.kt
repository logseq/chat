package com.logseq.chat.runtime

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp
import dev.lui.LuiIconResolver

// Small filled dot (iOS status-dot size) inside the standard 24dp icon
// slot — Material's Circle would fill the whole slot.
private val statusDot: ImageVector = ImageVector.Builder(
    name = "StatusDot",
    defaultWidth = 24.dp,
    defaultHeight = 24.dp,
    viewportWidth = 24f,
    viewportHeight = 24f,
).path(fill = SolidColor(Color.Black)) {
    moveTo(12f, 9f)
    curveTo(13.657f, 9f, 15f, 10.343f, 15f, 12f)
    curveTo(15f, 13.657f, 13.657f, 15f, 12f, 15f)
    curveTo(10.343f, 15f, 9f, 13.657f, 9f, 12f)
    curveTo(9f, 10.343f, 10.343f, 9f, 12f, 9f)
    close()
}.build()

// App icon vocabulary (the former logseq_chat_icons.dart) mapped onto
// Material Symbols vectors — same symbolic names the core emits.
internal val logseqChatAppIcons: Map<String, ImageVector> = mapOf(
    "outliner-bullet" to Icons.Filled.Circle,
    "add" to Icons.Filled.Add,
    "arrow-up" to Icons.Filled.KeyboardArrowUp,
    "arrow-down" to Icons.Filled.KeyboardArrowDown,
    "calendar" to Icons.Outlined.DateRange,
    "chevron-down" to Icons.Filled.KeyboardArrowDown,
    "chevron-right" to Icons.Filled.KeyboardArrowRight,
    "close" to Icons.Filled.Close,
    "composer-add" to Icons.Outlined.AddCircle,
    "composer-file" to Icons.Filled.Add,
    "composer-photo" to Icons.Filled.Add,
    "disclosure-down" to Icons.Filled.KeyboardArrowDown,
    "disclosure-right" to Icons.Filled.KeyboardArrowRight,
    "graph-locked" to Icons.Outlined.Lock,
    "document" to Icons.Outlined.Add,
    "download" to Icons.Outlined.Share,
    "flashcards" to Icons.Outlined.Star,
    "folder" to Icons.Outlined.Star,
    "graph-local" to Icons.Filled.Star,
    "graph-remote" to Icons.Outlined.Star,
    "history" to Icons.Filled.Refresh,
    "logo" to Icons.Filled.Star,
    "more-horiz" to Icons.Filled.MoreVert,
    "more-vert" to Icons.Filled.MoreVert,
    "navigation-back" to Icons.AutoMirrored.Filled.ArrowBack,
    "open-external" to Icons.Filled.Share,
    "refresh" to Icons.Filled.Refresh,
    "search" to Icons.Filled.Search,
    "send" to Icons.AutoMirrored.Filled.Send,
    "selected" to Icons.Filled.CheckCircle,
    "settings" to Icons.Outlined.Settings,
    "share" to Icons.Outlined.Share,
    "sidebar-toggle" to Icons.Filled.Menu,
    "sign-out" to Icons.AutoMirrored.Filled.Logout,
    "star" to Icons.Outlined.Star,
    "star-filled" to Icons.Filled.Star,
    "status-dot" to statusDot,
    "sync-status" to Icons.Filled.Refresh,
    "task-backlog" to Icons.Outlined.Circle,
    "task-canceled" to Icons.Outlined.Clear,
    "task-doing" to Icons.Filled.Refresh,
    "task-done" to Icons.Outlined.CheckCircle,
    "task-review" to Icons.Outlined.CheckCircle,
    "task-todo" to Icons.Outlined.Circle,
    "terminal" to Icons.Filled.Star,
    "toolbar-attachment" to Icons.Filled.Add,
    "toolbar-audio" to Icons.Filled.Edit,
    "toolbar-camera" to Icons.Filled.Add,
    "toolbar-copy" to Icons.Filled.Edit,
    "toolbar-copy-reference" to Icons.Filled.Edit,
    "toolbar-copy-url" to Icons.Filled.Share,
    "toolbar-delete" to Icons.Outlined.Delete,
    "toolbar-hide-keyboard" to Icons.Filled.KeyboardArrowDown,
    "toolbar-indent" to Icons.Filled.ArrowForward,
    "toolbar-move-down" to Icons.Filled.KeyboardArrowDown,
    "toolbar-move-up" to Icons.Filled.KeyboardArrowUp,
    "toolbar-outdent" to Icons.Filled.ArrowBack,
    "toolbar-tag" to Icons.Filled.Tag,
    "toolbar-task" to Icons.Outlined.CheckBox,
    "toolbar-unselect" to Icons.Filled.Clear,
    "trash" to Icons.Outlined.Delete,
    "unselected" to Icons.Outlined.Circle,
    "warning" to Icons.Filled.Warning,
)

internal val logseqChatIconResolver = LuiIconResolver { name ->
    // `app:`-prefixed names are app-owned icon identifiers from the schema.
    val key = name.removePrefix("app:")
    logseqChatAppIcons[key]
        ?: logseqChatAppIcons[name]
        ?: LuiIconResolver.DEFAULT.icon(name)
        ?: LuiIconResolver.DEFAULT.icon(key)
}
