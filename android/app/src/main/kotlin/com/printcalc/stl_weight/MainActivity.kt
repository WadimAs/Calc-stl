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
    private val saveRequest = 4712
    private var pendingSave: MethodChannel.Result? = null
    private var pendingSaveBytes: ByteArray? = null
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
                "appInfo" -> {
                    try {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        val code: Long = if (Build.VERSION.SDK_INT >= 28) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION")
                            info.versionCode.toLong()
                        }
                        result.success(hashMapOf<String, Any>("versionCode" to code, "versionName" to (info.versionName ?: "")))
                    } catch (e: Exception) {
                        result.error("info", e.message, null)
                    }
                }
                "openUrl" -> {
                    val url = call.argument<String>("url") ?: ""
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("url", e.message, null)
                    }
                }
                "saveFile" -> {
                    val name = call.argument<String>("name") ?: "export.csv"
                    val mime = call.argument<String>("mime") ?: "text/csv"
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("args", "no bytes", null)
                    } else {
                        pendingSave?.success(false)
                        pendingSave = result
                        pendingSaveBytes = bytes
                        val i = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mime
                            putExtra(Intent.EXTRA_TITLE, name)
                        }
                        try {
                            startActivityForResult(i, saveRequest)
                        } catch (e: Exception) {
                            pendingSave = null
                            pendingSaveBytes = null
                            result.error("save", e.message, null)
                        }
                    }
                }
                "shareFile" -> {
                    val name = (call.argument<String>("name") ?: "file.png").replace("/", "_")
                    val mime = call.argument<String>("mime") ?: "image/png"
                    val text = call.argument<String>("text")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("args", "no bytes", null)
                    } else {
                        try {
                            val dir = java.io.File(cacheDir, "share")
                            dir.mkdirs()
                            java.io.File(dir, name).writeBytes(bytes)
                            val uri = Uri.parse("content://$packageName.share/$name")
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = mime
                                putExtra(Intent.EXTRA_STREAM, uri)
                                if (text != null) putExtra(Intent.EXTRA_TEXT, text)
                                clipData = android.content.ClipData.newRawUri(name, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            val chooser = Intent.createChooser(send, null)
                            chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            startActivity(chooser)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("share", e.message, null)
                        }
                    }
                }
                "shareText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, text)
                    }
                    try {
                        startActivity(Intent.createChooser(send, null))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("share", e.message, null)
                    }
                }
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
        if (requestCode == saveRequest) {
            val res = pendingSave ?: return
            val bytes = pendingSaveBytes
            pendingSave = null
            pendingSaveBytes = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null || bytes == null) {
                res.success(false)
                return
            }
            Thread {
                var ok = false
                try {
                    contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ok = true
                } catch (e: Exception) {
                    ok = false
                }
                val done = ok
                mainHandler.post { res.success(done) }
            }.start()
            return
        }
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
