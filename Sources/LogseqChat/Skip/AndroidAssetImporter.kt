package logseq.chat

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest
import java.util.UUID

object AndroidAssetImporter {
    private var photoLauncher: ActivityResultLauncher<Array<String>>? = null
    private var fileLauncher: ActivityResultLauncher<Array<String>>? = null
    private var cameraLauncher: ActivityResultLauncher<Void?>? = null
    private var callback: ((String, String, Int, String, String) -> Unit)? = null
    private lateinit var context: Context
    private var activity: ComponentActivity? = null

    fun initialize(activity: ComponentActivity) {
        this.activity = activity
        context = activity.applicationContext
        photoLauncher = activity.registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
            deliver(uris.mapNotNull(::importAsset))
        }
        fileLauncher = activity.registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
            deliver(uris.mapNotNull(::importAsset))
        }
        cameraLauncher = activity.registerForActivityResult(ActivityResultContracts.TakePicturePreview()) { bitmap ->
            deliver(listOfNotNull(bitmap?.let(::importCameraPhoto)))
        }
    }

    fun importSharedAsset(uri: Uri, callback: (String, String, Int, String, String) -> Unit) {
        Thread {
            val asset = importAsset(uri)
            activity?.runOnUiThread {
                if (asset != null) {
                    callback(asset.title, asset.contentType, asset.size, asset.checksum, asset.path)
                }
            }
        }.start()
    }

    fun pickPhotos(callback: (String, String, Int, String, String) -> Unit) {
        this.callback = callback
        photoLauncher?.launch(arrayOf("image/*"))
    }

    fun takePhoto(callback: (String, String, Int, String, String) -> Unit) {
        this.callback = callback
        cameraLauncher?.launch(null)
    }

    fun pickFiles(callback: (String, String, Int, String, String) -> Unit) {
        this.callback = callback
        fileLauncher?.launch(arrayOf("*/*"))
    }

    fun openFile(path: String, contentType: String) {
        runCatching {
            val file = File(path)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val mimeType = if (contentType.contains('/')) {
                contentType
            } else {
                MimeTypeMap.getSingleton().getMimeTypeFromExtension(contentType.lowercase())
                    ?: "application/octet-stream"
            }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { android.util.Log.e("LogseqChat", "Could not open asset", it) }
    }

    private fun deliver(assets: List<ImportedAsset>) {
        val current = callback
        callback = null
        if (current != null) {
            assets.forEach { asset ->
                current(asset.title, asset.contentType, asset.size, asset.checksum, asset.path)
            }
        }
    }

    private fun importAsset(uri: Uri): ImportedAsset? = runCatching {
        val title = displayName(uri)
        val directory = File(context.filesDir, "Assets").apply { mkdirs() }
        val destination = File(directory, "${UUID.randomUUID()}-$title")
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Could not open selected asset" }
            destination.outputStream().use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    digest.update(buffer, 0, count)
                    size += count
                }
            }
        }
        ImportedAsset(
            title = title,
            contentType = context.contentResolver.getType(uri) ?: "application/octet-stream",
            size = size.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            checksum = digest.digest().joinToString("") { "%02x".format(it) },
            path = destination.absolutePath
        )
    }.onFailure { android.util.Log.e("LogseqChat", "Asset import failed", it) }.getOrNull()

    private fun importCameraPhoto(bitmap: Bitmap): ImportedAsset? = runCatching {
        val title = "Camera-${UUID.randomUUID()}.jpg"
        val directory = File(context.filesDir, "Assets").apply { mkdirs() }
        val destination = File(directory, title)
        destination.outputStream().use { output ->
            require(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output)) { "Could not encode camera photo" }
        }
        importedFile(destination, title, "image/jpeg")
    }.onFailure { android.util.Log.e("LogseqChat", "Camera import failed", it) }.getOrNull()

    private fun importedFile(file: File, title: String, contentType: String): ImportedAsset {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return ImportedAsset(
            title = title,
            contentType = contentType,
            size = file.length().coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            checksum = digest.digest().joinToString("") { "%02x".format(it) },
            path = file.absolutePath
        )
    }

    private fun displayName(uri: Uri): String {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return uri.lastPathSegment ?: "Attachment"
    }

    private data class ImportedAsset(
        val title: String,
        val contentType: String,
        val size: Int,
        val checksum: String,
        val path: String
    )
}
