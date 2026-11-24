package com.faria2177.pdf_studio

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Receives PDFs from other apps (VIEW / SEND), copies them into the cache and
 * hands the file path to Dart over the "pdf_studio/intent" channel.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pdfBox: PdfBoxChannel? = null
    private var ocr: OcrChannel? = null
    private var initialPath: String? = null
    private var initialConsumed = false
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pdfBox = PdfBoxChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        ocr = OcrChannel(flutterEngine.dartExecutor.binaryMessenger)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialFile" -> {
                    if (initialConsumed) {
                        result.success(null)
                    } else {
                        initialConsumed = true
                        val src = intent
                        io.execute {
                            val path = initialPath ?: copyFromIntent(src)
                            runOnUiThread { result.success(path) }
                        }
                    }
                }
                "openWith" -> {
                    val path = call.argument<String>("path")
                    val mime = call.argument<String>("mime") ?: "*/*"
                    val name = call.argument<String>("name") ?: File(path ?: "file").name
                    result.success(path != null && openWith(File(path), sanitize(name), mime))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        io.execute {
            val path = copyFromIntent(intent) ?: return@execute
            runOnUiThread { channel?.invokeMethod("onFile", path) }
        }
    }

    override fun onDestroy() {
        io.shutdown()
        pdfBox?.dispose()
        ocr?.dispose()
        super.onDestroy()
    }

    private fun copyFromIntent(intent: Intent?): String? {
        intent ?: return null
        val uri: Uri = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
            else -> null
        } ?: return null
        return try {
            val name = sanitize(displayName(uri) ?: "document.pdf").let {
                if (it.lowercase().endsWith(".pdf")) it else "$it.pdf"
            }
            val dir = File(cacheDir, "incoming").apply { mkdirs() }
            dir.listFiles()?.forEach { it.delete() }
            val out = File(dir, name)
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { input.copyTo(it) }
            } ?: return null
            out.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    /** Opens a file of ours in another app (Word, Excel, gallery…) through a FileProvider. */
    private fun openWith(src: File, name: String, mime: String): Boolean {
        return try {
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            dir.listFiles()?.forEach { if (it.name != name) it.delete() }
            val out = File(dir, name)
            src.inputStream().use { input -> out.outputStream().use { input.copyTo(it) } }
            val uri = FileProvider.getUriForFile(this, "$packageName.files", out)
            val view = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(view, "Open with").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (_: Exception) {
            null
        }
    }

    private fun sanitize(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_").take(120).ifBlank { "document.pdf" }

    companion object {
        private const val CHANNEL = "pdf_studio/intent"
    }
}
