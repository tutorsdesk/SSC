package com.tutorsdesk.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // Safety net: any uncaught Java/Kotlin exception (including from
        // plugins) is saved to crash.log BEFORE the process dies. On the
        // next launch the app shows the report to the user so a crash is
        // never a silent, unexplainable "app closed" again.
        try {
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { t, e ->
                try {
                    val sb = StringBuilder()
                    sb.append("time: ").append(System.currentTimeMillis()).append('\n')
                    // No exception messages, thread names, payloads or file paths.
                    sb.append("type: ").append(e.javaClass.name).append('\n')
                    sb.append("sdk: ").append(android.os.Build.VERSION.SDK_INT).append('\n')
                    e.stackTrace.filter { it.className.startsWith("com.tutorsdesk.app.") }
                        .take(12).forEach {
                            sb.append(it.className).append('.').append(it.methodName)
                                .append(':').append(it.lineNumber).append('\n')
                        }
                    val f = File(getDir("flutter", MODE_PRIVATE), "crash.log")
                    f.parentFile?.mkdirs()
                    f.writeText(sb.toString() + "\n---\n")
                } catch (_: Exception) {
                }
                previous?.uncaughtException(t, e)
            }
        } catch (_: Exception) {
        }
        super.onCreate(savedInstanceState)
    }
    private val channelName = "com.tutorsdesk.app/storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // App updates: the device ABI, and handing a verified APK to the
        // system installer. Android still asks the user to confirm.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.tutorsdesk.app/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "")
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            result.success(installApk(path))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canManageAllFiles" -> {
                        // The permission exists from Android 11 (API 30) up;
                        // on older devices the legacy write path is best-effort.
                        result.success(
                            if (Build.VERSION.SDK_INT >= 30)
                                Environment.isExternalStorageManager()
                            else true
                        )
                    }
                    "requestManageAllFiles" -> {
                        if (Build.VERSION.SDK_INT >= 30 &&
                            !Environment.isExternalStorageManager()
                        ) {
                            try {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                        Uri.parse("package:$packageName")
                                    )
                                )
                            } catch (e: Exception) {
                                try {
                                    startActivity(
                                        Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                    )
                                } catch (e2: Exception) {
                                    // Some OEM settings pages are missing both intents.
                                }
                            }
                        }
                        result.success(true)
                    }
                    "externalStorageDir" -> {
                        result.success(Environment.getExternalStorageDirectory().absolutePath)
                    }
                    "copyToDownloads" -> {
                        // Copy one file into the shared Download folder via
                        // MediaStore — the scoped-storage-sanctioned route
                        // that needs no permission on Android 10+, and the
                        // one place every file manager shows. The
                        // app-specific Android/data folder (where the debug
                        // images are always written) is hidden in most
                        // file managers, so the Downloads copy is what the
                        // user actually sends over. Returns the display
                        // path, or null when unavailable/failed.
                        var path: String? = null
                        try {
                            val source = call.argument<String>("source")
                            val name = call.argument<String>("name")
                            val mime = call.argument<String>("mime")
                            // One value drives both where MediaStore writes and
                            // what the caller is told, so the app can never
                            // report a folder it did not write to.
                            val relative = call.argument<String>("relativePath")
                                ?: "Download/TutorsDeskDebug"
                            if (Build.VERSION.SDK_INT >= 29 &&
                                source != null && name != null && mime != null
                            ) {
                                val values = android.content.ContentValues().apply {
                                    put(android.provider.MediaStore.Downloads.DISPLAY_NAME, name)
                                    put(android.provider.MediaStore.Downloads.MIME_TYPE, mime)
                                    put(android.provider.MediaStore.Downloads.RELATIVE_PATH, relative)
                                    put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
                                }
                                val uri = contentResolver.insert(
                                    android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                                if (uri != null) {
                                    var written = false
                                    val bytes = java.io.File(source).readBytes()
                                    contentResolver.openOutputStream(uri)?.use { out ->
                                        out.write(bytes)
                                        written = true
                                    }
                                    values.clear()
                                    values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
                                    contentResolver.update(uri, values, null, null)
                                    if (written) {
                                        path = relative
                                            .removePrefix("Download/")
                                            .removePrefix("Downloads/") + "/$name"
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            path = null
                        }
                        result.success(path)
                    }
                    "scannerModuleStatus" -> {
                        // The Google scanner's UI + models live in an
                        // installable Play services "module".
                        // Returns {status, error}: 1 = ready, 0 =
                        // downloadable, -1 = query failed, -2 = the
                        // scanner client could not even be constructed.
                        // error carries the underlying exception so the
                        // app can show exactly what failed.
                        // Errors included: a missing class throws
                        // NoClassDefFoundError (an Error, not Exception).
                        try {
                            val scanner = com.google.mlkit.vision.documentscanner.GmsDocumentScanning
                                .getClient(com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions.Builder().build())
                            com.google.android.gms.common.moduleinstall.ModuleInstall.getClient(this)
                                .areModulesAvailable(scanner)
                                .addOnSuccessListener { response ->
                                    result.success(
                                        mapOf(
                                            "status" to (if (response.areModulesAvailable()) 1 else 0),
                                            "error" to null
                                        )
                                    )
                                }
                                .addOnFailureListener { e ->
                                    result.success(mapOf("status" to -1, "error" to e.toString()))
                                }
                        } catch (t: Throwable) {
                            result.success(mapOf("status" to -2, "error" to t.toString()))
                        }
                    }
                    "installScannerModule" -> {
                        // One-time download of the scanner module from
                        // Play services. 1 = downloaded, 0 = already
                        // installed; error if the download fails.
                        try {
                            val scanner = com.google.mlkit.vision.documentscanner.GmsDocumentScanning
                                .getClient(com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions.Builder().build())
                            val request = com.google.android.gms.common.moduleinstall.ModuleInstallRequest.newBuilder()
                                .addApi(scanner)
                                .build()
                            com.google.android.gms.common.moduleinstall.ModuleInstall.getClient(this)
                                .installModules(request)
                                .addOnSuccessListener { response ->
                                    result.success(if (response.areModulesAlreadyInstalled()) 0 else 1)
                                }
                                .addOnFailureListener { e ->
                                    result.error("ScannerModuleInstall", e.message ?: "download failed", null)
                                }
                        } catch (t: Throwable) {
                            result.error("ScannerModuleInstall", t.toString(), null)
                        }
                    }
                    "gmsVersion" -> {
                        // Installed Play services version code (0 = no
                        // Play services package at all), for the
                        // diagnostics dialog.
                        try {
                            val info = packageManager.getPackageInfo("com.google.android.gms", 0)
                            // versionCode (not longVersionCode): works on
                            // every API level this app supports.
                            result.success(info.versionCode)
                        } catch (t: Throwable) {
                            result.success(0)
                        }
                    }
                    "openPlayServices" -> {
                        // Deep-link to the Play services entry in the
                        // Play Store (browser fallback if no store app).
                        try {
                            startActivity(
                                Intent(
                                    Intent.ACTION_VIEW,
                                    Uri.parse("market://details?id=com.google.android.gms")
                                )
                            )
                        } catch (e: Throwable) {
                            try {
                                startActivity(
                                    Intent(
                                        Intent.ACTION_VIEW,
                                        Uri.parse("https://play.google.com/store/apps/details?id=com.google.android.gms")
                                    )
                                )
                            } catch (e2: Throwable) {
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Opens the system installer for [path]. Returns `started`, or
    /// `needs_permission` after sending the user to the install-apps setting.
    private fun installApk(path: String): String {
        val file = File(path)
        if (!file.isFile) return "missing"
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            val settings = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
            settings.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(settings)
            return "needs_permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return "started"
    }
}
