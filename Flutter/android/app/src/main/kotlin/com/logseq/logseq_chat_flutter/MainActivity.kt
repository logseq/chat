package com.logseq.chat

import android.content.Intent
import android.net.Uri
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import logseq.chat.AndroidE2EECrypto
import logseq.chat.AndroidHttpTransport
import logseq.chat.AndroidRuntimeLogLevel
import logseq.chat.AndroidRuntimeLogSource
import logseq.chat.AndroidRuntimeLogs

internal fun flutterEncodableResult(value: Any?): Any? = if (value == Unit) null else value

class MainActivity : FlutterActivity() {
    init {
        System.loadLibrary("logseq_chat_core")
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        AndroidE2EECrypto.initialize(applicationContext)
        AndroidHttpTransport.initialize(applicationContext)
        AndroidRuntimeLogs.shared.append(
            AndroidRuntimeLogLevel.INFO,
            AndroidRuntimeLogSource.UI,
            "Android host started",
        )
        super.onCreate(savedInstanceState)
        assetImporter = AndroidAssetImporter(this, scope)
        handleAppIntent(intent)
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val authentication by lazy { CognitoAuthProvider(applicationContext, this) }
    private val platformServices by lazy { AndroidPlatformServices(this) }
    private lateinit var assetImporter: AndroidAssetImporter
    private val audioRecorder by lazy { AndroidAudioRecorder(this) }
    private val audioPlayer by lazy { AndroidAudioPlayer(this) }
    private val pendingAppEntries = ArrayDeque<Map<String, Any>>()
    private var appEntrySink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            appEntryChannel,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                appEntrySink = events
                while (pendingAppEntries.isNotEmpty()) {
                    events.success(pendingAppEntries.removeFirst())
                }
            }

            override fun onCancel(arguments: Any?) {
                appEntrySink = null
            }
        })
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            authenticationChannel
        ).setMethodCallHandler { call, result ->
            scope.launch {
                runCatching {
                    when (call.method) {
                        "hasStoredSession" -> authentication.hasStoredSession()
                        "restoreAccessToken" -> authentication.accessToken()
                        "signIn" -> authentication.signIn()
                        "signOut" -> authentication.signOut()
                        else -> throw NotImplementedError(call.method)
                    }
                }.onSuccess { value -> result.success(flutterEncodableResult(value)) }.onFailure { error ->
                    if (error is NotImplementedError) {
                        result.notImplemented()
                    } else {
                        result.error(
                            "authentication_failed",
                            error.message ?: error.toString(),
                            null
                        )
                    }
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            platformChannel
        ).setMethodCallHandler { call, result ->
            scope.launch {
                runCatching {
                    when (call.method) {
                        "loadStorageState" -> platformServices.loadStorageState()
                        "persistComposerDraft" -> platformServices.persistComposerDraft(
                            call.argument<String>("draft").orEmpty()
                        )
                        "saveSettings" -> platformServices.saveSettings(
                            requireNotNull(call.argument<String>("settings"))
                        )
                        "openExternalUrl" -> platformServices.openExternalUrl(
                            call.argument<String>("url").orEmpty()
                        )
                        "copyText" -> platformServices.copyText(
                            call.argument<String>("text").orEmpty()
                        )
                        "refreshRuntimeLog" -> platformServices.refreshRuntimeLog(
                            call.argument<String>("source").orEmpty(),
                            call.argument<Int>("flags") ?: 0,
                        )
                        "appendRuntimeLog" -> platformServices.appendRuntimeLog(
                            call.argument<String>("level").orEmpty(),
                            call.argument<String>("source").orEmpty(),
                            call.argument<String>("message").orEmpty(),
                        )
                        "presentAttachment" -> platformServices.presentAttachment(
                            call.argument<String>("kind").orEmpty()
                        )
                        "importAttachments" -> assetImporter.import(
                            call.argument<String>("kind").orEmpty()
                        )
                        "presentAsset" -> platformServices.presentAsset(
                            call.argument<String>("metadata").orEmpty()
                        )
                        "presentPageShare" -> platformServices.presentPageShare(
                            call.argument<String>("text").orEmpty(),
                            call.argument<String>("metadata") ?: "[]",
                        )
                        "startAudioRecording" -> audioRecorder.start()
                        "supportsAudioTranscription" -> AndroidAudioTranscriber.isSupported()
                        "stopAudioRecording" -> withContext(Dispatchers.IO) {
                            audioRecorder.stop()
                        }
                        "cancelAudioRecording" -> audioRecorder.cancel()
                        "transcribeAudio" -> withContext(Dispatchers.IO) {
                            AndroidAudioTranscriber.transcribe(
                                call.argument<String>("path").orEmpty(),
                            )
                        }
                        "startAudioPlayback" -> audioPlayer.start(
                            call.argument<String>("path").orEmpty()
                        )
                        "pauseAudioPlayback" -> audioPlayer.pause(
                            requireNotNull(call.argument<Int>("sessionId"))
                        )
                        "resumeAudioPlayback" -> audioPlayer.resume(
                            requireNotNull(call.argument<Int>("sessionId"))
                        )
                        "audioPlaybackStatus" -> audioPlayer.status(
                            requireNotNull(call.argument<Int>("sessionId"))
                        )
                        "stopAudioPlayback" -> audioPlayer.stop(
                            requireNotNull(call.argument<Int>("sessionId"))
                        )
                        "syncNow" -> false
                        "deleteLocalGraph" -> platformServices.deleteLocalGraph(
                            call.argument<String>("graphId").orEmpty()
                        )
                        "exportGraphDatabase" -> platformServices.exportGraphDatabase()
                        "downloadGraphSnapshot" -> platformServices.downloadGraphSnapshot(
                            baseUrl = call.argument<String>("baseUrl").orEmpty(),
                            graphId = call.argument<String>("graphId").orEmpty(),
                            accessToken = call.argument<String>("accessToken").orEmpty(),
                            workingDirectory = call.argument<String>("workingDirectory").orEmpty(),
                        )
                        "persistSelectedGraphId" -> platformServices.persistSelectedGraphId(
                            call.argument<String>("graphId").orEmpty(),
                        )
                        "deleteTemporaryFile" -> platformServices.deleteTemporaryFile(
                            call.argument<String>("path").orEmpty(),
                        )
                        else -> throw NotImplementedError(call.method)
                    }
                }.onSuccess { value -> result.success(flutterEncodableResult(value)) }.onFailure { error ->
                    if (error is NotImplementedError) {
                        result.notImplemented()
                    } else {
                        result.error(
                            "platform_effect_failed",
                            error.message ?: error.toString(),
                            null,
                        )
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (authentication.handleCallback(intent.dataString)) return
        handleAppIntent(intent)
    }

    private fun handleAppIntent(intent: Intent?) {
        if (intent == null) return
        AndroidAppEntryParser.deepLinkKind(intent.dataString)?.let { kind ->
            publishAppEntry(mapOf("kind" to kind))
            return
        }
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) {
            return
        }
        AndroidAppEntryParser.sharedBlockText(
            intent.getStringExtra(Intent.EXTRA_TEXT),
            intent.getStringExtra(Intent.EXTRA_TITLE),
        )?.let { text ->
            publishAppEntry(mapOf("kind" to "shared-text", "text" to text))
        }
        sharedUris(intent).forEach { uri ->
            scope.launch {
                assetImporter.importShared(uri)?.let { asset ->
                    publishAppEntry(mapOf("kind" to "shared-asset", "asset" to asset))
                }
            }
        }
    }

    private fun publishAppEntry(entry: Map<String, Any>) {
        val sink = appEntrySink
        Log.i(
            "LogseqChatAppEntry",
            "Publishing kind=${entry["kind"]} delivery=${if (sink == null) "queued" else "live"}",
        )
        if (sink == null) {
            pendingAppEntries.addLast(entry)
        } else {
            sink.success(entry)
        }
        AndroidRuntimeLogs.shared.append(
            AndroidRuntimeLogLevel.INFO,
            AndroidRuntimeLogSource.UI,
            "Received Android app entry kind=${entry["kind"]}",
        )
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> = buildList {
        intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(::addAll)
        intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(::add)
        intent.clipData?.let { clips ->
            for (index in 0 until clips.itemCount) {
                clips.getItemAt(index).uri?.let(::add)
            }
        }
    }.distinct()

    @Deprecated("Android activity result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (assetImporter.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (audioRecorder.onRequestPermissionsResult(requestCode, grantResults)) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        audioRecorder.cancel()
        audioPlayer.release()
        scope.cancel()
        super.onDestroy()
    }

    private companion object {
        const val authenticationChannel = "com.logseq.chat/authentication"
        const val platformChannel = "com.logseq.chat/platform"
        const val appEntryChannel = "com.logseq.chat/app-entry"
    }
}
