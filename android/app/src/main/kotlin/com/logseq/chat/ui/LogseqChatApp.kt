package com.logseq.chat.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.logseq.chat.runtime.ChatRuntime
import com.logseq.chat.runtime.RecordedAudioAsset
import com.logseq.chat.ui.extensions.ChatDialogs
import kotlinx.coroutines.delay

// Port of the former Dart app composable + app frame:
// Material theme + a plain surface hosting the LUI backend content,
// plus the modal hosts (audio recording sheet, delete confirmation,
// error snackbar) the runtime requests through ChatDialogs.
@Composable
internal fun LogseqChatApp(runtime: ChatRuntime) {
    val systemDark = isSystemInDarkTheme()
    val dark = when (runtime.effectiveAppearance) {
        "light" -> false
        "dark" -> true
        else -> systemDark
    }
    MaterialTheme(
        colorScheme = if (dark) LogseqChatTheme.darkScheme else LogseqChatTheme.lightScheme,
    ) {
        androidx.compose.runtime.CompositionLocalProvider(
            dev.lui.LocalLuiThemeDark provides dark,
        ) {
            val snackbarHostState = remember { SnackbarHostState() }
            Scaffold(
                snackbarHost = { SnackbarHost(snackbarHostState) },
            ) { padding ->
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding)
                        .windowInsetsPadding(WindowInsets.safeDrawing),
                ) {
                    val rootId = runtime.rootNodeId
                    if (rootId != null) {
                        runtime.backend.Content(rootId)
                    }
                }
            }
            val error = ChatDialogs.errorMessage
            LaunchedEffect(error) {
                if (error != null) {
                    snackbarHostState.showSnackbar(error)
                    ChatDialogs.clearError()
                }
            }
            AudioRecordingDialog()
            DeleteConfirmationDialog()
        }
    }
}

@Composable
private fun AudioRecordingDialog() {
    val request = ChatDialogs.recordingRequest ?: return
    var elapsedSeconds by remember { mutableLongStateOf(0L) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(request) {
        try {
            request.recorder.start()
        } catch (failure: Throwable) {
            request.result.complete(null)
            return@LaunchedEffect
        }
        while (true) {
            delay(1_000)
            elapsedSeconds++
        }
    }

    AlertDialog(
        onDismissRequest = {
            if (!busy) {
                request.recorder.cancel()
                request.result.complete(null)
            }
        },
        title = { Text("Recording") },
        text = {
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    LinearProgressIndicator(modifier = Modifier.weight(1f))
                    Text(
                        "%d:%02d".format(elapsedSeconds / 60, elapsedSeconds % 60),
                        modifier = Modifier.padding(start = 12.dp),
                    )
                }
                if (request.transcriptionSupported) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(top = 8.dp),
                    ) {
                        Checkbox(
                            checked = request.transcriptionEnabled,
                            onCheckedChange = { request.transcriptionEnabled = it },
                        )
                        Text("Transcribe when finished")
                    }
                }
                error?.let {
                    Text(
                        it,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !busy,
                modifier = Modifier.testTag("button.audio.stop"),
                onClick = {
                    busy = true
                    runCatching { request.recorder.stop() }
                        .onSuccess { map ->
                            request.result.complete(
                                RecordedAudioAsset(
                                    uuid = map["uuid"] as String,
                                    title = map["title"] as String,
                                    assetType = map["assetType"] as String,
                                    size = (map["size"] as Number).toLong(),
                                    checksum = map["checksum"] as String,
                                    localPath = map["localPath"] as String,
                                ),
                            )
                        }
                        .onFailure { failure ->
                            busy = false
                            error = failure.toString()
                        }
                },
            ) { Text("Stop") }
        },
        dismissButton = {
            TextButton(
                enabled = !busy,
                onClick = {
                    request.recorder.cancel()
                    request.result.complete(null)
                },
            ) { Text("Cancel") }
        },
    )
}

@Composable
private fun DeleteConfirmationDialog() {
    val request = ChatDialogs.deleteConfirmation ?: return
    AlertDialog(
        onDismissRequest = { request.result.complete(false) },
        title = { Text(if (request.multiple) "Delete blocks?" else "Delete block?") },
        text = {
            Text(
                if (request.multiple) {
                    "The selected blocks will be removed permanently."
                } else {
                    "The selected block will be removed permanently."
                }
            )
        },
        confirmButton = {
            TextButton(
                modifier = Modifier.testTag("button.confirm-delete"),
                onClick = { request.result.complete(true) },
            ) { Text("Delete") }
        },
        dismissButton = {
            TextButton(onClick = { request.result.complete(false) }) { Text("Cancel") }
        },
    )
}
