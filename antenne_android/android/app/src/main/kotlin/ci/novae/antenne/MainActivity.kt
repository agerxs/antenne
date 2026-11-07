package ci.novae.antenne

import android.app.UiModeManager
import android.content.pm.PackageManager
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "antenne/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> result.success(isTelevision())
                else -> result.notImplemented()
            }
        }
    }

    /** Téléviseur ou boîtier Android TV / Google TV / Fire TV : on y navigue à la télécommande. */
    private fun isTelevision(): Boolean {
        val uiMode = getSystemService(UiModeManager::class.java)?.currentModeType
        return uiMode == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }
}
