package ci.novae.antenne

import android.app.ActivityManager
import android.app.UiModeManager
import android.content.Intent
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "antenne/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> result.success(isTelevision())
                "appVersion" -> result.success(appVersion())
                "deviceReport" -> result.success(deviceReport())
                // Partage du diagnostic (WhatsApp, e-mail…). Faux s'il n'y a aucune app pour le recevoir.
                "shareText" -> {
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, call.arguments as String)
                    }
                    try {
                        startActivity(Intent.createChooser(send, "Envoyer le diagnostic"))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                // Pendant la lecture, ni mise en veille ni économiseur d'écran (Android TV compris).
                "keepScreenOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** « 1.0.0 (8) » : nom de version et numéro de build, pour savoir quel APK est installé. */
    private fun appVersion(): String {
        val info = packageManager.getPackageInfo(packageName, 0)
        val build = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
        return "${info.versionName} ($build)"
    }

    /** Appareil, puce, version d'OpenGL ES et décodeurs vidéo : ce qu'il faut pour comprendre un écran noir. */
    private fun deviceReport(): Map<String, Any?> {
        val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder }
            .flatMap { info ->
                info.supportedTypes.filter { it.startsWith("video/") }.map { type ->
                    mapOf("type" to type, "name" to info.name, "hardware" to isHardware(info))
                }
            }
        val metrics = resources.displayMetrics
        val gles = getSystemService(ActivityManager::class.java)?.deviceConfigurationInfo?.glEsVersion
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "hardware" to Build.HARDWARE,
            "soc" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}" else null,
            "android" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "gles" to gles,
            "screen" to "${metrics.widthPixels}×${metrics.heightPixels}",
            "decoders" to decoders,
        )
    }

    private fun isHardware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.isHardwareAccelerated
        else !(info.name.startsWith("OMX.google.") || info.name.startsWith("c2.android."))

    /** Téléviseur ou boîtier Android TV / Google TV / Fire TV : on y navigue à la télécommande. */
    private fun isTelevision(): Boolean {
        val uiMode = getSystemService(UiModeManager::class.java)?.currentModeType
        return uiMode == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }
}
