package com.jahid2177.pdftools

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Base64
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Hosts the PdfCraft WebAssembly build (bundled in assets/www by CI) inside a WebView.
 *
 * Everything is served from https://appassets.androidplatform.net so the page runs in a
 * secure context (needed for WebGPU/clipboard) with correct MIME types for .wasm.
 *  - /app/...   -> assets/www/...
 *  - /open/...  -> a PDF handed to us by another app ("Open with")
 * Saves (anchor downloads of blob: URLs) are routed through a JS bridge to a
 * "Save as" picker, so no storage permission is needed.
 */
class MainActivity : ComponentActivity() {

    private lateinit var webView: WebView
    private var fileCallback: ValueCallback<Array<Uri>>? = null

    // Pending save: temp file + suggested name/mime, waiting for the CreateDocument result.
    private var pendingSave: Triple<File, String, String>? = null

    private val openPicker =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val cb = fileCallback ?: return@registerForActivityResult
            fileCallback = null
            val data = result.data
            val uris: Array<Uri>? = if (result.resultCode == RESULT_OK && data != null) {
                val clip = data.clipData
                if (clip != null && clip.itemCount > 0) {
                    Array(clip.itemCount) { clip.getItemAt(it).uri }
                } else {
                    data.data?.let { arrayOf(it) }
                }
            } else null
            cb.onReceiveValue(uris)
        }

    private val savePicker =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val (tmp, name, _) = pendingSave ?: return@registerForActivityResult
            pendingSave = null
            val uri = result.data?.data
            if (result.resultCode == RESULT_OK && uri != null) {
                try {
                    contentResolver.openOutputStream(uri, "w")?.use { out ->
                        tmp.inputStream().use { it.copyTo(out) }
                    }
                    toast("Saved: $name")
                } catch (e: Exception) {
                    toast("Save failed: ${e.message}")
                }
            }
            tmp.delete()
        }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = FrameLayout(this)
        webView = WebView(this)
        root.addView(
            webView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
        setContentView(root)

        // Android 15 (targetSdk 35) draws edge-to-edge; keep the canvas clear of bars and keyboard.
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or
                    WindowInsetsCompat.Type.displayCutout() or
                    WindowInsetsCompat.Type.ime()
            )
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mediaPlaybackRequiresUserGesture = true
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            useWideViewPort = true
            loadWithOverviewMode = false
            cacheMode = WebSettings.LOAD_DEFAULT
            textZoom = 100
        }
        webView.overScrollMode = WebView.OVER_SCROLL_NEVER
        webView.addJavascriptInterface(Bridge(), "AndroidBridge")
        webView.webViewClient = Client()
        webView.webChromeClient = Chrome()

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                AlertDialog.Builder(this@MainActivity)
                    .setMessage("Exit? Unsaved changes will be lost.")
                    .setPositiveButton("Exit") { _, _ -> finish() }
                    .setNegativeButton("Cancel", null)
                    .show()
            }
        })

        if (savedInstanceState != null) {
            webView.restoreState(savedInstanceState)
        }
        if (savedInstanceState == null || webView.url == null) {
            loadApp(fileFromIntent(intent))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val opened = fileFromIntent(intent) ?: return
        AlertDialog.Builder(this)
            .setMessage("Open \"$opened\"? Unsaved changes in the current document will be lost.")
            .setPositiveButton("Open") { _, _ -> loadApp(opened) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        webView.saveState(outState)
    }

    override fun onDestroy() {
        webView.destroy()
        super.onDestroy()
    }

    private fun loadApp(openedName: String?) {
        var url = "$ORIGIN/app/index.html"
        if (openedName != null) {
            val fileUrl = "$ORIGIN/open/" + enc(openedName)
            url += "?file=" + enc(fileUrl)
        }
        webView.loadUrl(url)
    }

    /** Copies a PDF passed by VIEW/SEND into cache/open and returns its file name. */
    private fun fileFromIntent(intent: Intent?): String? {
        intent ?: return null
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
            else -> null
        }
        uri ?: return null
        return try {
            val name = sanitize(displayName(uri) ?: "document.pdf")
            val dir = File(cacheDir, "open").apply { mkdirs() }
            dir.listFiles()?.forEach { it.delete() }
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(File(dir, name)).use { input.copyTo(it) }
            } ?: return null
            name
        } catch (e: Exception) {
            toast("Couldn't open file: ${e.message}")
            null
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

    private fun toast(msg: String) =
        runOnUiThread { Toast.makeText(this, msg, Toast.LENGTH_SHORT).show() }

    // ---------------------------------------------------------------- serving

    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest
        ): WebResourceResponse? {
            val url = request.url
            if (url.host != HOST) return null
            val path = url.path ?: return notFound()
            return when {
                path.startsWith("/app/") -> serveAsset(path.removePrefix("/app/"))
                path.startsWith("/open/") -> {
                    val f = File(File(cacheDir, "open"), sanitize(url.lastPathSegment ?: ""))
                    if (f.isFile) response("application/pdf", f.inputStream()) else notFound()
                }
                else -> notFound()
            }
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url
            if (url.host == HOST) return false
            // External links (help, website) open in the browser.
            return try {
                startActivity(Intent(Intent.ACTION_VIEW, url))
                true
            } catch (_: Exception) {
                true
            }
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            toast("The viewer crashed (out of memory?). Restarting.")
            recreate()
            return true
        }
    }

    private fun serveAsset(rel: String): WebResourceResponse {
        val clean = rel.ifEmpty { "index.html" }
        if (clean.contains("..")) return notFound()
        return try {
            if (clean == "index.html") {
                val html = assets.open("www/index.html").bufferedReader().use { it.readText() }
                val injected = html.replaceFirst("<head>", "<head>\n<script>$BRIDGE_JS</script>")
                response("text/html", ByteArrayInputStream(injected.toByteArray()), noCache = true)
            } else {
                response(mimeFor(clean), assets.open("www/$clean"))
            }
        } catch (_: Exception) {
            notFound()
        }
    }

    private fun response(mime: String, body: InputStream, noCache: Boolean = false) =
        WebResourceResponse(mime, if (mime.startsWith("text/")) "utf-8" else null, body).apply {
            responseHeaders = mapOf(
                "Access-Control-Allow-Origin" to "*",
                "Cache-Control" to if (noCache) "no-cache" else "public, max-age=31536000"
            )
        }

    private fun notFound() =
        WebResourceResponse("text/plain", "utf-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    private fun mimeFor(path: String): String = when (path.substringAfterLast('.', "").lowercase()) {
        "html", "htm" -> "text/html"
        "js", "mjs" -> "text/javascript"
        "wasm" -> "application/wasm"
        "css" -> "text/css"
        "json" -> "application/json"
        "svg" -> "image/svg+xml"
        "png" -> "image/png"
        "txt", "md" -> "text/plain"
        else -> "application/octet-stream"
    }

    // ---------------------------------------------------------------- open dialog

    private inner class Chrome : WebChromeClient() {
        override fun onShowFileChooser(
            webView: WebView,
            callback: ValueCallback<Array<Uri>>,
            params: FileChooserParams
        ): Boolean {
            fileCallback?.onReceiveValue(null)
            fileCallback = callback
            val accept = params.acceptTypes
                .flatMap { it.split(',') }
                .map { it.trim() }
                .filter { it.contains('/') }
                .distinct()
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                // The page mostly filters by extension (".pdf"), so allow any type and let it decide.
                type = if (accept.size == 1) accept[0] else "*/*"
                if (accept.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, accept.toTypedArray())
                putExtra(
                    Intent.EXTRA_ALLOW_MULTIPLE,
                    params.mode == FileChooserParams.MODE_OPEN_MULTIPLE
                )
            }
            return try {
                openPicker.launch(intent)
                true
            } catch (e: Exception) {
                fileCallback = null
                false
            }
        }
    }

    // ---------------------------------------------------------------- save bridge

    private inner class Bridge {
        private val ids = AtomicInteger()
        private val open = ConcurrentHashMap<Int, Triple<File, String, String>>()

        @JavascriptInterface
        fun begin(name: String, mime: String): Int {
            val id = ids.incrementAndGet()
            val dir = File(cacheDir, "save").apply { mkdirs() }
            val f = File(dir, "out-$id")
            f.delete()
            open[id] = Triple(f, sanitize(name.ifBlank { "document.pdf" }), mime.ifBlank { "application/octet-stream" })
            return id
        }

        @JavascriptInterface
        fun chunk(id: Int, b64: String) {
            val (f, _, _) = open[id] ?: return
            FileOutputStream(f, true).use { it.write(Base64.decode(b64, Base64.DEFAULT)) }
        }

        @JavascriptInterface
        fun end(id: Int) {
            val entry = open.remove(id) ?: return
            runOnUiThread {
                pendingSave?.first?.delete()
                pendingSave = entry
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = entry.third
                    putExtra(Intent.EXTRA_TITLE, entry.second)
                }
                try {
                    savePicker.launch(intent)
                } catch (e: Exception) {
                    toast("No file picker available")
                }
            }
        }

        @JavascriptInterface
        fun error(msg: String) = toast("Save failed: $msg")
    }

    companion object {
        private const val HOST = "appassets.androidplatform.net"
        private const val ORIGIN = "https://$HOST"

        private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

        private fun sanitize(name: String) =
            name.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_").take(150).ifBlank { "document.pdf" }

        /**
         * Runs before the app's module script. The web build saves files by clicking an
         * <a download href="blob:..."> — WebView ignores that, so we hand the bytes to Kotlin.
         */
        private val BRIDGE_JS = """
(function () {
  var origRevoke = URL.revokeObjectURL.bind(URL);
  // The app may revoke the blob URL right after click(); keep it alive while we read it.
  URL.revokeObjectURL = function (u) { setTimeout(function () { origRevoke(u); }, 120000); };
  var origClick = HTMLAnchorElement.prototype.click;
  function toB64(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(s);
  }
  async function save(href, name) {
    try {
      var blob = await (await fetch(href)).blob();
      var id = AndroidBridge.begin(name, blob.type || 'application/octet-stream');
      var CH = 768 * 1024;
      for (var off = 0; off < blob.size; off += CH) {
        var buf = new Uint8Array(await blob.slice(off, off + CH).arrayBuffer());
        AndroidBridge.chunk(id, toB64(buf));
      }
      AndroidBridge.end(id);
    } catch (e) { AndroidBridge.error(String(e)); }
  }
  HTMLAnchorElement.prototype.click = function () {
    var href = this.href || '';
    if (this.hasAttribute('download') && (href.indexOf('blob:') === 0 || href.indexOf('data:') === 0)) {
      save(href, this.getAttribute('download') || 'document.pdf');
      return;
    }
    return origClick.call(this);
  };
})();
""".trimIndent()
    }
}
