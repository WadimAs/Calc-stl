package com.printcalc.stl_weight

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "stl_weight/files"
    private val pickRequest = 4711
    private var channel: MethodChannel? = null
    private var pendingPick: MethodChannel.Result? = null
    private var initialUri: Uri? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initialUri = extractUri(intent)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFile" -> {
                    pendingPick?.success(null)
                    pendingPick = result
                    val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    try {
                        startActivityForResult(i, pickRequest)
                    } catch (e: Exception) {
                        pendingPick = null
                        result.error("picker", e.message, null)
                    }
                }
                "getInitialFile" -> {
                    val uri = initialUri
                    initialUri = null
                    if (uri == null) result.success(null) else readUri(uri) { result.success(it) }
                }
                "filesDir" -> result.success(filesDir.absolutePath)
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = extractUri(intent) ?: return
        readUri(uri) { map ->
            if (map != null) channel?.invokeMethod("fileOpened", map)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickRequest) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        readUri(uri) { result.success(it) }
    }

    private fun extractUri(intent: Intent?): Uri? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> {
                if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                }
            }
            else -> null
        }
    }

    /** Reads the whole document off the main thread, replies on the main thread. */
    private fun readUri(uri: Uri, done: (HashMap<String, Any>?) -> Unit) {
        Thread {
            var map: HashMap<String, Any>? = null
            try {
                var name = uri.lastPathSegment ?: "model.stl"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (idx >= 0) c.getString(idx)?.let { name = it }
                    }
                }
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (bytes != null) {
                    map = hashMapOf<String, Any>("name" to name, "bytes" to bytes)
                }
            } catch (e: Exception) {
                map = null
            }
            val out = map
            mainHandler.post { done(out) }
        }.start()
    }
}
