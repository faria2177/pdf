package com.faria2177.pdf_studio

import android.os.Handler
import android.os.Looper
import com.googlecode.leptonica.android.ReadFile
import com.googlecode.tesseract.android.TessBaseAPI
import com.googlecode.tesseract.android.TessPdfRenderer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Tesseract OCR (Tesseract4Android).
 *  - ocrToPdf:  page images -> searchable PDF (image + invisible text layer)
 *  - ocrToText: page images -> plain text + confidence per page
 * Language files live in <dataPath>/tessdata/<lang>.traineddata (downloaded by the Dart side).
 */
class OcrChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "pdf_studio/ocr")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var cancelled = false
    @Volatile private var current: TessBaseAPI? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "cancel") {
                cancelled = true
                try { current?.stop() } catch (_: Exception) {}
                result.success(null)
                return@setMethodCallHandler
            }
            cancelled = false
            worker.execute {
                try {
                    val value: Any? = when (call.method) {
                        "ocrToPdf" -> ocrToPdf(call)
                        "ocrToText" -> ocrToText(call)
                        else -> {
                            main.post { result.notImplemented() }
                            return@execute
                        }
                    }
                    main.post { result.success(value) }
                } catch (e: OutOfMemoryError) {
                    main.post { result.error("oom", "Not enough memory", null) }
                } catch (e: Exception) {
                    main.post { result.error("failed", e.message ?: e.javaClass.simpleName, null) }
                }
            }
        }
    }

    fun dispose() {
        cancelled = true
        worker.shutdown()
    }

    private fun progress(done: Int, total: Int) {
        main.post { channel.invokeMethod("progress", mapOf("done" to done, "total" to total)) }
    }

    private fun newApi(call: MethodCall): TessBaseAPI {
        val dataPath = call.argument<String>("dataPath")!!
        val lang = call.argument<String>("lang") ?: "eng"
        val api = TessBaseAPI()
        if (!api.init(dataPath, lang)) {
            api.recycle()
            throw IllegalStateException("Could not load language data for \"$lang\"")
        }
        api.setPageSegMode(call.argument<Int>("psm") ?: TessBaseAPI.PageSegMode.PSM_AUTO)
        call.argument<Int>("dpi")?.let { api.setVariable("user_defined_dpi", it.toString()) }
        api.setVariable("preserve_interword_spaces", "1")
        current = api
        return api
    }

    private fun ocrToPdf(call: MethodCall): String {
        val images = call.argument<List<String>>("images")!!
        val output = call.argument<String>("output")!! // without ".pdf"
        val title = call.argument<String>("title") ?: "OCR"
        val api = newApi(call)
        val renderer = TessPdfRenderer(api, output)
        try {
            if (!api.beginDocument(renderer, title)) throw IllegalStateException("Could not start PDF")
            images.forEachIndexed { i, path ->
                if (cancelled) throw InterruptedException("Cancelled")
                val pix = ReadFile.readFile(File(path)) ?: throw IllegalStateException("Could not read page ${i + 1}")
                try {
                    if (!api.addPageToDocument(pix, path, renderer)) {
                        throw IllegalStateException("OCR failed on page ${i + 1}")
                    }
                } finally {
                    pix.recycle()
                }
                progress(i + 1, images.size)
            }
            api.endDocument(renderer)
        } finally {
            renderer.recycle()
            api.recycle()
            current = null
        }
        return "$output.pdf"
    }

    private fun ocrToText(call: MethodCall): List<Map<String, Any>> {
        val images = call.argument<List<String>>("images")!!
        val api = newApi(call)
        val out = ArrayList<Map<String, Any>>()
        try {
            images.forEachIndexed { i, path ->
                if (cancelled) throw InterruptedException("Cancelled")
                api.setImage(File(path))
                val text = api.getUTF8Text() ?: ""
                out.add(mapOf("text" to text, "confidence" to api.meanConfidence()))
                api.clear()
                progress(i + 1, images.size)
            }
        } finally {
            api.recycle()
            current = null
        }
        return out
    }
}
