package com.faria2177.pdf_studio

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.IdentityHashMap
import java.util.concurrent.Executors

/**
 * PDF operations PDFium (pdfrx) can't do, done with PdfBox-Android:
 *  - protect: AES-256 encryption with user/owner passwords and permissions
 *  - compress: downscale and recompress embedded images as JPEG (text stays vector)
 */
class PdfBoxChannel(context: Context, messenger: BinaryMessenger) {
    private val appContext = context.applicationContext
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var initialized = false

    init {
        MethodChannel(messenger, "pdf_studio/pdfbox").setMethodCallHandler { call, result ->
            worker.execute {
                try {
                    ensureInit()
                    val value: Any? = when (call.method) {
                        "protect" -> protect(call)
                        "compress" -> compress(call)
                        else -> {
                            main.post { result.notImplemented() }
                            return@execute
                        }
                    }
                    main.post { result.success(value) }
                } catch (e: OutOfMemoryError) {
                    main.post { result.error("oom", "Not enough memory for this file", null) }
                } catch (e: Exception) {
                    val msg = when {
                        e.javaClass.simpleName.contains("InvalidPassword") -> "Wrong password"
                        else -> e.message ?: e.javaClass.simpleName
                    }
                    main.post { result.error("failed", msg, null) }
                }
            }
        }
    }

    fun dispose() = worker.shutdown()

    private fun ensureInit() {
        if (!initialized) {
            PDFBoxResourceLoader.init(appContext)
            initialized = true
        }
    }

    private fun load(path: String, password: String?): PDDocument {
        val doc = PDDocument.load(File(path), password ?: "")
        // Saving an opened protected file needs its security removed first.
        if (doc.isEncrypted) doc.isAllSecurityToBeRemoved = true
        return doc
    }

    private fun protect(call: MethodCall): Map<String, Any> {
        val input = call.argument<String>("input")!!
        val output = call.argument<String>("output")!!
        val userPw = call.argument<String>("userPassword") ?: ""
        val ownerPw = call.argument<String>("ownerPassword")?.takeIf { it.isNotEmpty() } ?: userPw
        val perms = AccessPermission().apply {
            val print = call.argument<Boolean>("allowPrint") ?: true
            val copy = call.argument<Boolean>("allowCopy") ?: true
            val modify = call.argument<Boolean>("allowModify") ?: true
            setCanPrint(print)
            setCanPrintDegraded(print)
            setCanExtractContent(copy)
            setCanExtractForAccessibility(true)
            setCanModify(modify)
            setCanModifyAnnotations(modify)
            setCanAssembleDocument(modify)
            setCanFillInForm(true)
        }
        load(input, call.argument("password")).use { doc ->
            val policy = StandardProtectionPolicy(ownerPw, userPw, perms)
            policy.setEncryptionKeyLength(256)
            doc.protect(policy)
            doc.save(File(output))
        }
        return mapOf("size" to File(output).length())
    }

    private fun compress(call: MethodCall): Map<String, Any> {
        val input = call.argument<String>("input")!!
        val output = call.argument<String>("output")!!
        val quality = (call.argument<Double>("quality") ?: 0.6).toFloat()
        val maxSide = call.argument<Int>("maxSide") ?: 1600
        var found = 0
        var replaced = 0
        load(input, call.argument("password")).use { doc ->
            val done = IdentityHashMap<COSBase, PDImageXObject?>()
            val visitedForms = IdentityHashMap<COSBase, Boolean>()

            fun process(res: PDResources?) {
                res ?: return
                for (name in res.xObjectNames.toList()) {
                    val xo = try { res.getXObject(name) } catch (_: Exception) { null } ?: continue
                    when (xo) {
                        is PDFormXObject -> {
                            if (visitedForms.put(xo.cosObject, true) == null) process(xo.resources)
                        }
                        is PDImageXObject -> {
                            val key = xo.cosObject
                            if (done.containsKey(key)) {
                                done[key]?.let { res.put(name, it) }
                                continue
                            }
                            found++
                            val repl = recompress(doc, xo, quality, maxSide)
                            done[key] = repl
                            if (repl != null) {
                                res.put(name, repl)
                                replaced++
                            }
                        }
                    }
                }
            }

            for (page in doc.pages) process(page.resources)
            doc.save(File(output))
        }
        return mapOf("images" to found, "replaced" to replaced, "size" to File(output).length())
    }

    /** Returns a smaller JPEG copy of [img], or null to keep the original. */
    private fun recompress(doc: PDDocument, img: PDImageXObject, quality: Float, maxSide: Int): PDImageXObject? {
        try {
            if (img.isStencil || img.bitsPerComponent <= 1) return null
            if (img.softMask != null || img.mask != null) return null // JPEG has no transparency
            val w = img.width
            val h = img.height
            if (w * h < 150 * 150) return null
            val oldLen = img.cosObject.length
            var bmp: Bitmap = img.image ?: return null
            val longest = maxOf(bmp.width, bmp.height)
            if (longest > maxSide) {
                val s = maxSide.toFloat() / longest
                val scaled = Bitmap.createScaledBitmap(
                    bmp, (bmp.width * s).toInt().coerceAtLeast(1), (bmp.height * s).toInt().coerceAtLeast(1), true
                )
                if (scaled !== bmp) bmp.recycle()
                bmp = scaled
            }
            val jpeg = JPEGFactory.createFromImage(doc, bmp, quality)
            bmp.recycle()
            return if (jpeg.cosObject.length < oldLen * 0.9) jpeg else null
        } catch (e: OutOfMemoryError) {
            return null
        } catch (e: Exception) {
            return null // JBIG2/JPX or unusual colour spaces: keep as is
        }
    }
}
