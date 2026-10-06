package dev.lui

import android.util.Log
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties

private const val TAG = "LuiRender"

@Composable
internal fun LuiRoot(backend: LuiBackend, rootId: Long) {
    Box(
        Modifier
            .fillMaxSize()
            .semantics { testTagsAsResourceId = true }
    ) {
        val root = backend.node(rootId)
        if (root != null) {
            for (childId in root.children.toList()) {
                key(childId) { LuiNodeView(backend, childId) }
            }
        }
    }
}

@Composable
private fun <T> key(id: Long, content: @Composable () -> T) =
    androidx.compose.runtime.key(id) { content() }

@Composable
internal fun LuiNodeView(backend: LuiBackend, id: Long) {
    val node = backend.node(id) ?: return
    if (!node.visible()) return
    LuiTheme.NodeScope(node) {
        if (node.isExtension) {
            ExtensionView(backend, node)
        } else {
            NodeView(backend, node)
        }
    }
}

@Composable
private fun ExtensionView(backend: LuiBackend, node: LuiNode) {
    val result = backend.extensions.resolve(node)
    result.onSuccess { builder ->
        builder.Render(LuiExtensionContext(node, backend))
    }.onFailure { error ->
        Surface(
            modifier = Modifier.padding(8.dp),
            color = MaterialTheme.colorScheme.errorContainer,
            shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
        ) {
            Text(
                text = "Extension \"${node.identifier}\" unavailable: ${error.message}",
                modifier = Modifier.padding(12.dp),
                color = MaterialTheme.colorScheme.onErrorContainer,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun Children(backend: LuiBackend, node: LuiNode) {
    for (childId in node.children.toList()) {
        key(childId) { LuiNodeView(backend, childId) }
    }
}

@Composable
private fun AppearOnce(backend: LuiBackend, node: LuiNode) {
    if (node.enabled("appear-enabled")) {
        LaunchedEffect(node.id) { backend.dispatch(LuiEvent.Appear(node.id)) }
    }
}

// Emits the press/long-press/double-press gestures a node opted into.
@Composable
private fun Modifier.gestures(backend: LuiBackend, node: LuiNode): Modifier {
    val hasLong = node.enabled("long-press-enabled")
    val hasDouble = node.enabled("double-press-enabled")
    val hasPress = node.enabled("press-enabled") || node.kind == "button" ||
        node.kind == "toggle-button" || node.kind == "link" ||
        node.kind == "menu-item" || node.kind == "bottom-tab" ||
        node.kind == "list-item" || node.kind == "radio"
    return if (hasPress || hasLong || hasDouble) {
        combinedClickable(
            onClick = { backend.dispatch(LuiEvent.Press(node.id)) },
            onLongClick = if (hasLong) {
                { backend.dispatch(LuiEvent.LongPress(node.id)) }
            } else null,
            onDoubleClick = if (hasDouble) {
                { backend.dispatch(LuiEvent.DoublePress(node.id)) }
            } else null,
        )
    } else this
}

@Composable
private fun NodeView(backend: LuiBackend, node: LuiNode) {
    AppearOnce(backend, node)
    when (node.kind) {
        "root", "box", "edge-inset", "view-that-fits" ->
            Frame(backend, node)
        "column" -> ColumnNode(backend, node)
        "row" -> RowNode(backend, node)
        "grid" -> GridNode(backend, node)
        "stack", "overlay" -> StackNode(backend, node)
        "scroll" -> ScrollNode(backend, node)
        "list", "list-section" -> ListNode(backend, node)
        "virtual-list" -> VirtualListNode(backend, node)
        "spacer" -> SpacerNode(node)
        "divider" -> HorizontalDivider(
            modifier = node.styleModifier(),
            color = node.colorProp("foreground")
                ?: MaterialTheme.colorScheme.outlineVariant,
        )
        "text", "label" -> TextNode(backend, node)
        "heading" -> Text(
            text = node.string("text") ?: node.string("title").orEmpty(),
            modifier = node.styleModifier().gestures(backend, node),
            style = node.headingStyle(),
        )
        "paragraph" -> Text(
            text = node.string("text").orEmpty(),
            modifier = node.styleModifier().gestures(backend, node),
            style = node.textStyle(),
        )
        "kbd" -> Text(
            text = node.string("text").orEmpty(),
            modifier = node.styleModifier(),
            style = node.textStyle().copy(fontFamily = FontFamily.Monospace),
        )
        "icon" -> IconNode(backend, node)
        "button", "toggle-button" -> ButtonNode(backend, node)
        "link" -> Text(
            text = node.string("text") ?: node.string("title").orEmpty(),
            modifier = node.styleModifier().gestures(backend, node),
            style = node.textStyle().copy(
                color = MaterialTheme.colorScheme.primary,
            ),
        )
        "toggle", "switch" -> Switch(
            checked = node.flag("checked"),
            onCheckedChange = { backend.dispatch(LuiEvent.ToggleChanged(node.id, it)) },
            enabled = node.enabled("enabled", true),
            modifier = node.styleModifier(),
        )
        "checkbox" -> Checkbox(
            checked = node.flag("checked"),
            onCheckedChange = { backend.dispatch(LuiEvent.ToggleChanged(node.id, it)) },
            enabled = node.enabled("enabled", true),
            modifier = node.styleModifier(),
        )
        "radio" -> RadioButton(
            selected = node.flag("checked") || node.flag("selected"),
            onClick = { backend.dispatch(LuiEvent.Press(node.id)) },
            enabled = node.enabled("enabled", true),
            modifier = node.styleModifier(),
        )
        "radio-group", "button-group", "toggle-group" ->
            ColumnNode(backend, node)
        "slider" -> Slider(
            value = (node.double("value") ?: 0.0).toFloat(),
            onValueChange = {
                backend.dispatch(LuiEvent.ValueChanged(node.id, it.toDouble()))
            },
            enabled = node.enabled("enabled", true),
            modifier = node.styleModifier(),
        )
        "progress" -> LinearProgressIndicator(
            progress = { (node.double("value") ?: 0.0).toFloat() },
            modifier = node.styleModifier().fillMaxWidth(),
        )
        "spinner" -> CircularProgressIndicator(
            modifier = node.styleModifier(),
            color = node.colorProp("foreground") ?: MaterialTheme.colorScheme.primary,
        )
        "text-field", "input", "secure-field", "textarea" ->
            TextFieldNode(backend, node)
        "search-field" -> TextFieldNode(backend, node)
        "card", "panel", "bubble" -> CardNode(backend, node)
        "alert" -> AlertNode(backend, node)
        "toolbar", "status-bar", "breadcrumb" -> RowNode(backend, node)
        "list-item" -> RowNode(backend, node)
        "image", "file-image", "file-preview" -> ImageNode(backend, node)
        "tabs", "bottom-tabs" -> TabsNode(backend, node)
        "bottom-tab", "tab" -> ButtonNode(backend, node)
        "menu-item" -> RowNode(backend, node)
        "menu-trigger" -> MenuTrigger(backend, node)
        "dropdown-menu", "context-menu" -> MenuNode(backend, node)
        "dialog" -> DialogNode(backend, node)
        "sheet" -> SheetNode(backend, node)
        "drawer" -> DrawerNode(backend, node)
        "popover", "tooltip" -> PopupNode(backend, node)
        "toast" -> ToastNode(backend, node)
        "tree" -> ColumnNode(backend, node)
        "badge" -> BadgeNode(backend, node)
        "br" -> Spacer(Modifier.height(4.dp))
        "media-surface" -> Surface(
            modifier = node.styleModifier().fillMaxWidth(),
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
        ) {}
        "file-picker" -> FilePickerNode(backend, node)
        "select", "combobox" -> SelectNode(backend, node)
        "number-stepper" -> StepperNode(backend, node)
        "stepper" -> StepperNode(backend, node)
        "step" -> Frame(backend, node)
        "accordion", "table", "table-row", "table-cell", "timeline",
        "timeline-item", "resizable", "split", "swipe-actions",
        "swipe-action", "input-group", "input-group-actions",
        "pagination", "list-section-header", "list-section-footer",
        "avatar", "segmented-control" -> FallbackContainer(backend, node)
        else -> FallbackContainer(backend, node)
    }
}

@Composable
private fun Frame(backend: LuiBackend, node: LuiNode) {
    Box(
        modifier = node
            .surfaceModifier()
            .gestures(backend, node),
    ) {
        Children(backend, node)
    }
}

@Composable
private fun ColumnNode(backend: LuiBackend, node: LuiNode) {
    Column(
        modifier = node.surfaceModifier().gestures(backend, node),
        verticalArrangement = node.mainAxisVertical(),
        horizontalAlignment = node.crossAxisHorizontal(),
    ) {
        for (childId in node.children.toList()) {
            val child = backend.node(childId) ?: continue
            if (!child.visible()) continue
            val grow = child.double("grow")
            key(childId) {
                if (grow != null && grow > 0) {
                    Box(Modifier.weight(grow.toFloat())) { LuiNodeView(backend, childId) }
                } else {
                    LuiNodeView(backend, childId)
                }
            }
        }
    }
}

@Composable
private fun RowNode(backend: LuiBackend, node: LuiNode) {
    Row(
        modifier = node.surfaceModifier().gestures(backend, node),
        horizontalArrangement = node.mainAxisAlignment(),
        verticalAlignment = node.crossAxisVertical(),
    ) {
        for (childId in node.children.toList()) {
            val child = backend.node(childId) ?: continue
            if (!child.visible()) continue
            val grow = child.double("grow")
            key(childId) {
                if (grow != null && grow > 0) {
                    Box(Modifier.weight(grow.toFloat())) { LuiNodeView(backend, childId) }
                } else {
                    LuiNodeView(backend, childId)
                }
            }
        }
    }
}

@Composable
private fun GridNode(backend: LuiBackend, node: LuiNode) {
    val columns = (node.int("columns") ?: 2).coerceAtLeast(1)
    Column(
        modifier = node.surfaceModifier().gestures(backend, node),
        verticalArrangement = node.mainAxisVertical(),
    ) {
        val children = node.children.toList()
        for (row in children.chunked(columns)) {
            Row(horizontalArrangement = Arrangement.spacedBy(node.gapDp())) {
                for (childId in row) {
                    key(childId) {
                        Box(Modifier.weight(1f)) { LuiNodeView(backend, childId) }
                    }
                }
            }
        }
    }
}

@Composable
private fun StackNode(backend: LuiBackend, node: LuiNode) {
    Box(
        modifier = node.surfaceModifier().gestures(backend, node),
        contentAlignment = when (node.string("cross-alignment")) {
            "center" -> Alignment.Center
            "end" -> Alignment.BottomEnd
            else -> Alignment.TopStart
        },
    ) {
        Children(backend, node)
    }
}

@Composable
private fun ScrollNode(backend: LuiBackend, node: LuiNode) {
    Column(
        modifier = node
            .surfaceModifier()
            .gestures(backend, node)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = node.mainAxisVertical(),
        horizontalAlignment = node.crossAxisHorizontal(),
    ) {
        Children(backend, node)
    }
}

@Composable
private fun ListNode(backend: LuiBackend, node: LuiNode) {
    Column(
        modifier = node.surfaceModifier().gestures(backend, node),
        verticalArrangement = node.mainAxisVertical(),
        horizontalAlignment = node.crossAxisHorizontal(),
    ) {
        Children(backend, node)
    }
}

@Composable
private fun VirtualListNode(backend: LuiBackend, node: LuiNode) {
    val listState = rememberLazyListState()
    val trackRange = node.enabled("track-visible-range")
    if (trackRange) {
        LaunchedEffect(node.id) {
            snapshotFlow { listState.firstVisibleItemIndex to listState.layoutInfo.visibleItemsInfo }
                .collect { (first, visible) ->
                    val last = first + visible.size - 1
                    backend.dispatch(LuiEvent.VisibleRange(node.id, first.toLong(), last.toLong()))
                }
        }
    }
    LazyColumn(
        state = listState,
        modifier = node.surfaceModifier().gestures(backend, node),
        verticalArrangement = node.mainAxisVertical(),
        horizontalAlignment = node.crossAxisHorizontal(),
    ) {
        for (childId in node.children.toList()) {
            item(key = childId) { LuiNodeView(backend, childId) }
        }
    }
}

@Composable
private fun SpacerNode(node: LuiNode) {
    Spacer(
        Modifier
            .width((node.int("width") ?: 8).dp)
            .height((node.int("height") ?: 8).dp)
    )
}

@Composable
private fun TextNode(backend: LuiBackend, node: LuiNode) {
    Text(
        text = node.string("text") ?: node.string("title").orEmpty(),
        modifier = node.styleModifier().gestures(backend, node),
        style = node.textStyle(),
        textAlign = node.textAlign(),
        overflow = if (node.flag("wrap")) {
            androidx.compose.ui.text.style.TextOverflow.Clip
        } else {
            androidx.compose.ui.text.style.TextOverflow.Ellipsis
        },
        maxLines = node.int("max-lines") ?: Int.MAX_VALUE,
    )
}

@Composable
private fun IconNode(backend: LuiBackend, node: LuiNode) {
    val name = node.string("name") ?: node.string("icon") ?: return
    val vector = backend.icons.icon(name)
    if (vector != null) {
        Icon(
            imageVector = vector,
            contentDescription = node.string("accessibility-label"),
            tint = node.colorProp("foreground") ?: MaterialTheme.colorScheme.onSurface,
            modifier = node.styleModifier().size((node.int("width") ?: 20).dp),
        )
    } else {
        Text(
            text = name,
            modifier = node.styleModifier(),
            style = node.textStyle(),
        )
    }
}

@Composable
private fun ButtonNode(backend: LuiBackend, node: LuiNode) {
    val variant = node.string("variant") ?: "filled"
    val enabled = node.enabled("enabled", true)
    val modifier = node.styleModifier()
    val colors = ButtonDefaults.buttonColors(
        containerColor = node.colorProp("background") ?: Color.Unspecified,
        contentColor = node.colorProp("foreground") ?: Color.Unspecified,
    )
    val content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = {
        node.string("icon")?.let { iconName ->
            backend.icons.icon(iconName)?.let {
                Icon(it, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
            }
        }
        node.string("text")?.let { Text(it) }
        node.string("title")?.let { Text(it) }
        Children(backend, node)
    }
    when (variant) {
        "tonal", "secondary" -> FilledTonalButton(
            onClick = { backend.dispatch(LuiEvent.Press(node.id)) },
            enabled = enabled,
            modifier = modifier,
            colors = colors,
            content = content,
        )
        "outline", "outlined" -> OutlinedButton(
            onClick = { backend.dispatch(LuiEvent.Press(node.id)) },
            enabled = enabled,
            modifier = modifier,
            content = content,
        )
        "ghost", "text" -> TextButton(
            onClick = { backend.dispatch(LuiEvent.Press(node.id)) },
            enabled = enabled,
            modifier = modifier,
            content = content,
        )
        else -> Button(
            onClick = { backend.dispatch(LuiEvent.Press(node.id)) },
            enabled = enabled,
            modifier = modifier,
            colors = colors,
            content = content,
        )
    }
}

@Composable
private fun TextFieldNode(backend: LuiBackend, node: LuiNode) {
    val propValue = node.string("text") ?: ""
    var fieldValue by remember(node.id) { mutableStateOf(TextFieldValue(propValue)) }
    // Keep local IME state in sync when the core patches `value` back.
    if (fieldValue.text != propValue && !node.enabled("editing")) {
        fieldValue = fieldValue.copy(text = propValue)
    }
    val focusRequester = remember { FocusRequester() }
    val onSubmit: () -> Unit = { backend.dispatch(LuiEvent.Submit(node.id)) }
    val fieldModifier = node
        .styleModifier()
        .focusRequester(focusRequester)
        .fillMaxWidth()
    val commonKeyboard = KeyboardOptions(
        keyboardType = when {
            node.kind == "secure-field" -> KeyboardType.Password
            else -> KeyboardType.Text
        },
    )
    val actions = KeyboardActions(onDone = { onSubmit() }, onSend = { onSubmit() })
    val change: (TextFieldValue) -> Unit = { newValue ->
        fieldValue = newValue
        backend.dispatch(LuiEvent.TextChanged(node.id, newValue.text))
    }
    val visualTransformation = if (node.kind == "secure-field") {
        PasswordVisualTransformation()
    } else {
        androidx.compose.ui.text.input.VisualTransformation.None
    }
    if (node.kind == "search-field") {
        OutlinedTextField(
            value = fieldValue,
            onValueChange = change,
            modifier = fieldModifier,
            enabled = node.enabled("enabled", true),
            placeholder = node.string("placeholder")?.let { { Text(it) } },
            leadingIcon = {
                backend.icons.icon("search")?.let {
                    Icon(it, contentDescription = null)
                }
            },
            singleLine = true,
            keyboardOptions = commonKeyboard,
            keyboardActions = actions,
            visualTransformation = visualTransformation,
        )
    } else {
        TextField(
            value = fieldValue,
            onValueChange = change,
            modifier = fieldModifier,
            enabled = node.enabled("enabled", true),
            placeholder = node.string("placeholder")?.let { { Text(it) } },
            label = node.string("label")?.let { { Text(it) } },
            singleLine = node.kind != "textarea",
            minLines = if (node.kind == "textarea") 3 else 1,
            keyboardOptions = commonKeyboard,
            keyboardActions = actions,
            visualTransformation = visualTransformation,
        )
    }
    if (node.enabled("autofocus")) {
        LaunchedEffect(node.id) { focusRequester.requestFocus() }
    }
}

@Composable
private fun CardNode(backend: LuiBackend, node: LuiNode) {
    Card(
        modifier = node.styleModifier().gestures(backend, node),
        shape = node.shape(),
        colors = androidx.compose.material3.CardDefaults.cardColors(
            containerColor = node.colorProp("background") ?: Color.Unspecified,
            contentColor = node.colorProp("foreground") ?: Color.Unspecified,
        ),
    ) {
        Column(
            modifier = Modifier.padding((node.int("padding") ?: 0).dp),
            verticalArrangement = node.mainAxisVertical(),
            horizontalAlignment = node.crossAxisHorizontal(),
        ) {
            Children(backend, node)
        }
    }
}

@Composable
private fun AlertNode(backend: LuiBackend, node: LuiNode) {
    Surface(
        modifier = node.styleModifier().gestures(backend, node),
        shape = node.shape(),
        color = node.colorProp("background") ?: MaterialTheme.colorScheme.errorContainer,
        contentColor = node.colorProp("foreground") ?: MaterialTheme.colorScheme.onErrorContainer,
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = node.mainAxisVertical(),
        ) {
            node.string("title")?.let {
                Text(it, style = MaterialTheme.typography.titleSmall)
            }
            node.string("description")?.let {
                Text(it, style = MaterialTheme.typography.bodySmall)
            }
            Children(backend, node)
        }
    }
}

@Composable
private fun ImageNode(backend: LuiBackend, node: LuiNode) {
    // LUI image sources are app-relative paths or remote URLs; the core
    // supplies `url`/`path` props. Coil is intentionally not a LUI
    // dependency — apps register an "image" extension instead; here we
    // render a labelled placeholder when no loader is present.
    Surface(
        modifier = node.styleModifier().gestures(backend, node),
        shape = node.shape(),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        val label = node.string("accessibility-label")
            ?: node.string("title")
            ?: "image"
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height((node.int("height") ?: 120).dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(label, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun TabsNode(backend: LuiBackend, node: LuiNode) {
    // Children carry their own tab chrome; `active-index` marks the
    // selected tab for button children that read `selected`.
    Column(
        modifier = node.surfaceModifier().gestures(backend, node),
    ) {
        Children(backend, node)
    }
}

@Composable
private fun MenuTrigger(backend: LuiBackend, node: LuiNode) {
    Box {
        Children(backend, node)
    }
}

@Composable
private fun MenuNode(backend: LuiBackend, node: LuiNode) {
    if (!node.flag("open") && !node.enabled("open")) return
    DropdownMenu(
        expanded = true,
        onDismissRequest = { backend.dispatch(LuiEvent.Dismiss(node.id)) },
    ) {
        for (childId in node.children.toList()) {
            val child = backend.node(childId) ?: continue
            if (child.kind == "menu-item") {
                DropdownMenuItem(
                    text = {
                        Text(child.string("title") ?: child.string("value").orEmpty())
                    },
                    onClick = { backend.dispatch(LuiEvent.Press(child.id)) },
                )
            } else {
                key(childId) { LuiNodeView(backend, childId) }
            }
        }
    }
}

@Composable
private fun DialogNode(backend: LuiBackend, node: LuiNode) {
    Dialog(
        onDismissRequest = { backend.dispatch(LuiEvent.Dismiss(node.id)) },
    ) {
        Surface(
            modifier = node.styleModifier(),
            shape = node.shape(),
            color = node.colorProp("background") ?: MaterialTheme.colorScheme.surface,
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = node.mainAxisVertical(),
            ) {
                Children(backend, node)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SheetNode(backend: LuiBackend, node: LuiNode) {
    ModalBottomSheet(
        onDismissRequest = { backend.dispatch(LuiEvent.Dismiss(node.id)) },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = node.colorProp("background")
            ?: MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = node.styleModifier(),
            verticalArrangement = node.mainAxisVertical(),
        ) {
            Children(backend, node)
        }
    }
}

@Composable
private fun DrawerNode(backend: LuiBackend, node: LuiNode) {
    // Rendered as a modal popup anchored to the start edge — the interim
    // backend has no scaffold context to attach a real drawer to.
    Popup(
        alignment = Alignment.TopStart,
        onDismissRequest = { backend.dispatch(LuiEvent.Dismiss(node.id)) },
        properties = PopupProperties(focusable = true),
    ) {
        ModalDrawerSheet(
            modifier = node.styleModifier().fillMaxSize(0.9f),
        ) {
            Children(backend, node)
        }
    }
}

@Composable
private fun PopupNode(backend: LuiBackend, node: LuiNode) {
    Popup(
        onDismissRequest = { backend.dispatch(LuiEvent.Dismiss(node.id)) },
        properties = PopupProperties(focusable = node.kind == "popover"),
    ) {
        Surface(
            shape = node.shape(),
            color = node.colorProp("background") ?: MaterialTheme.colorScheme.surfaceContainerHigh,
            shadowElevation = 4.dp,
        ) {
            Box(Modifier.padding(8.dp)) { Children(backend, node) }
        }
    }
}

@Composable
private fun ToastNode(backend: LuiBackend, node: LuiNode) {
    Popup(alignment = Alignment.BottomCenter) {
        Surface(
            shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
            color = node.colorProp("background") ?: MaterialTheme.colorScheme.inverseSurface,
            contentColor = MaterialTheme.colorScheme.inverseOnSurface,
            shadowElevation = 6.dp,
        ) {
            Box(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                Children(backend, node)
            }
        }
    }
}

@Composable
private fun BadgeNode(backend: LuiBackend, node: LuiNode) {
    Badge(modifier = node.styleModifier()) {
        Text(node.string("text") ?: node.string("title").orEmpty())
    }
}

@Composable
private fun FilePickerNode(backend: LuiBackend, node: LuiNode) {
    // The core opens pickers through effects; the node is a trigger.
    Frame(backend, node)
}

@Composable
private fun SelectNode(backend: LuiBackend, node: LuiNode) {
    Frame(backend, node)
}

@Composable
private fun StepperNode(backend: LuiBackend, node: LuiNode) {
    Row(
        modifier = node.styleModifier().gestures(backend, node),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Children(backend, node)
    }
}

@Composable
private fun FallbackContainer(backend: LuiBackend, node: LuiNode) {
    Log.d(TAG, "rendering '${node.kind}' as a plain container")
    Column(modifier = node.surfaceModifier().gestures(backend, node)) {
        Children(backend, node)
    }
}
