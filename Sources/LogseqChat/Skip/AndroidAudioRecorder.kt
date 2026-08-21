package logseq.chat

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object AndroidAudioRecorder {
    private lateinit var activity: ComponentActivity
    private lateinit var context: Context
    private var permissionLauncher: ActivityResultLauncher<String>? = null
    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var pendingStart: (() -> Unit)? = null
    private var pendingError: ((String) -> Unit)? = null

    fun initialize(activity: ComponentActivity) {
        this.activity = activity
        context = activity.applicationContext
        permissionLauncher = activity.registerForActivityResult(
            ActivityResultContracts.RequestPermission()
        ) { granted ->
            val started = pendingStart
            val failed = pendingError
            pendingStart = null
            pendingError = null
            if (granted) startRecorder(started ?: {}, failed ?: {})
            else failed?.invoke("Microphone access is required to record audio.")
        }
    }

    fun start(onStarted: () -> Unit, onError: (String) -> Unit) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            startRecorder(onStarted, onError)
        } else {
            pendingStart = onStarted
            pendingError = onError
            permissionLauncher?.launch(Manifest.permission.RECORD_AUDIO)
                ?: onError("Audio recorder is not initialized.")
        }
    }

    fun stop(
        onSaved: (String, String, Int, String, String) -> Unit,
        onError: (String) -> Unit
    ) {
        val file = outputFile ?: return onError("No audio recording is active.")
        runCatching {
            recorder?.stop()
            recorder?.release()
            recorder = null
            outputFile = null
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            onSaved(
                file.name,
                "m4a",
                file.length().coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                digest.digest().joinToString("") { "%02x".format(it) },
                file.absolutePath
            )
        }.onFailure {
            recorder?.release()
            recorder = null
            outputFile = null
            file.delete()
            onError(it.message ?: "Could not save audio recording.")
        }
    }

    fun cancel() {
        runCatching { recorder?.stop() }
        recorder?.release()
        recorder = null
        outputFile?.delete()
        outputFile = null
    }

    @Suppress("DEPRECATION")
    private fun startRecorder(onStarted: () -> Unit, onError: (String) -> Unit) {
        runCatching {
            val directory = File(context.filesDir, "Assets").apply { mkdirs() }
            val stamp = SimpleDateFormat("yyyy-MM-dd HH-mm-ss", Locale.US).format(Date())
            val file = File(directory, "Audio-$stamp.m4a")
            val next = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                MediaRecorder()
            }
            next.setAudioSource(MediaRecorder.AudioSource.MIC)
            next.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            next.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            next.setAudioSamplingRate(16_000)
            next.setAudioChannels(1)
            next.setOutputFile(file.absolutePath)
            next.setMaxDuration(AudioRecordingPolicy.maximumDurationSeconds * 1000)
            next.prepare()
            next.start()
            recorder = next
            outputFile = file
            onStarted()
        }.onFailure {
            cancel()
            onError(it.message ?: "Could not start audio recording.")
        }
    }
}
