package com.logseq.chat.runtime

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
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

// Copy-block-reference glyph: a rounded-square frame with a diagonal
// reference arrow, matching the iOS r.square asset silhouette.
private val copyReference: ImageVector = ImageVector.Builder(
    name = "CopyReference",
    defaultWidth = 24.dp,
    defaultHeight = 24.dp,
    viewportWidth = 24f,
    viewportHeight = 24f,
).path(
    fill = null,
    stroke = SolidColor(Color.Black),
    strokeLineWidth = 1.8f,
    strokeLineCap = androidx.compose.ui.graphics.StrokeCap.Round,
    strokeLineJoin = androidx.compose.ui.graphics.StrokeJoin.Round,
) {
    moveTo(8f, 5f)
    lineTo(16f, 5f)
    curveTo(17.66f, 5f, 19f, 6.34f, 19f, 8f)
    lineTo(19f, 16f)
    curveTo(19f, 17.66f, 17.66f, 19f, 16f, 19f)
    lineTo(8f, 19f)
    curveTo(6.34f, 19f, 5f, 17.66f, 5f, 16f)
    lineTo(5f, 8f)
    curveTo(5f, 6.34f, 6.34f, 5f, 8f, 5f)
    close()
}.path(
    fill = null,
    stroke = SolidColor(Color.Black),
    strokeLineWidth = 1.8f,
    strokeLineCap = androidx.compose.ui.graphics.StrokeCap.Round,
) {
    moveTo(9.5f, 14.5f)
    lineTo(15f, 9f)
    moveTo(11f, 9f)
    lineTo(15f, 9f)
    lineTo(15f, 13f)
}.build()

// App icon vocabulary (the former logseq_chat_icons.dart) mapped onto
// Material Symbols vectors — same symbolic names the core emits, matched
// to the SF Symbols / asset meanings the iOS renderer uses.
internal val logseqChatAppIcons: Map<String, ImageVector> = mapOf(
    "outliner-bullet" to statusDot,
    "add" to Icons.Filled.Add,
    "arrow-up" to Icons.Filled.ArrowUpward,
    "arrow-down" to Icons.Filled.ArrowDownward,
    "calendar" to Icons.Outlined.DateRange,
    "chevron-down" to Icons.Filled.KeyboardArrowDown,
    "chevron-right" to Icons.AutoMirrored.Filled.KeyboardArrowRight,
    "close" to Icons.Filled.Close,
    "composer-add" to Icons.Filled.Add,
    "composer-file" to Icons.AutoMirrored.Outlined.InsertDriveFile,
    "composer-photo" to Icons.Outlined.PhotoLibrary,
    "disclosure-down" to Icons.Filled.KeyboardArrowDown,
    "disclosure-right" to Icons.AutoMirrored.Filled.KeyboardArrowRight,
    "document" to Icons.Outlined.Description,
    "download" to Icons.Outlined.FileDownload,
    "flashcards" to Icons.Outlined.Layers,
    "folder" to Icons.Outlined.Folder,
    "graph-local" to Icons.Outlined.Storage,
    "graph-locked" to Icons.Outlined.Lock,
    "graph-remote" to Icons.Outlined.CloudQueue,
    "history" to Icons.Outlined.History,
    "logo" to Icons.Outlined.Bolt,
    "more-horiz" to Icons.Filled.MoreHoriz,
    "more-vert" to Icons.Filled.MoreHoriz,
    "navigation-back" to Icons.AutoMirrored.Filled.ArrowBack,
    "open-external" to Icons.AutoMirrored.Outlined.OpenInNew,
    "outliner-editor-done" to Icons.Filled.Check,
    "refresh" to Icons.Filled.Refresh,
    "search" to Icons.Outlined.Search,
    "selected" to Icons.Filled.CheckCircle,
    "send" to Icons.AutoMirrored.Filled.Send,
    "settings" to Icons.Outlined.Settings,
    "share" to Icons.Outlined.Share,
    "sidebar-toggle" to Icons.Filled.Menu,
    "sign-out" to Icons.AutoMirrored.Filled.Logout,
    "star" to Icons.Outlined.Star,
    "star-filled" to Icons.Filled.Star,
    "status-dot" to statusDot,
    "sync-status" to Icons.Filled.Refresh,
    "task-backlog" to Icons.Outlined.WatchLater,
    "task-canceled" to Icons.Outlined.Cancel,
    "task-doing" to Icons.Filled.Timelapse,
    "task-done" to Icons.Outlined.CheckCircle,
    "task-review" to Icons.Outlined.RateReview,
    "task-todo" to Icons.Outlined.RadioButtonUnchecked,
    "terminal" to Icons.Outlined.Terminal,
    "toolbar-attachment" to Icons.Outlined.AttachFile,
    "toolbar-audio" to Icons.Outlined.Mic,
    "toolbar-camera" to Icons.Outlined.PhotoCamera,
    "toolbar-copy" to Icons.Outlined.FileCopy,
    "toolbar-copy-reference" to copyReference,
    "toolbar-copy-url" to Icons.Outlined.Link,
    "toolbar-delete" to Icons.Outlined.Delete,
    "toolbar-hide-keyboard" to Icons.Outlined.KeyboardHide,
    "toolbar-indent" to Icons.AutoMirrored.Filled.ArrowForward,
    "toolbar-move-down" to Icons.Filled.ArrowDownward,
    "toolbar-move-up" to Icons.Filled.ArrowUpward,
    "toolbar-outdent" to Icons.AutoMirrored.Filled.ArrowBack,
    "toolbar-tag" to Icons.Outlined.Tag,
    "toolbar-task" to Icons.Outlined.CheckCircle,
    "toolbar-unselect" to Icons.Filled.Clear,
    "trash" to Icons.Outlined.Delete,
    "unselected" to Icons.Outlined.RadioButtonUnchecked,
    "upload" to Icons.Outlined.FileUpload,
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
