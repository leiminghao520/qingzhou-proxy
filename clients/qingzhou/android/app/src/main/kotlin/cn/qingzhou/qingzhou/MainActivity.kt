package cn.qingzhou.qingzhou

import android.app.Activity
import android.app.NotificationManager
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import cn.qingzhou.bridge.mobile.Mobile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingRequest: String? = null
    private var exportResult: MethodChannel.Result? = null
    private var exportBytes: ByteArray? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "cn.qingzhou/runtime").setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> result.success(JSONObject(mapOf("captureModes" to listOf("tun"), "coreVersion" to Mobile.version(), "httpCompatibility" to true, "fallback" to true)).toString())
                "status" -> result.success(JSONObject(mapOf("state" to QingzhouVpnService.state,"notificationsEnabled" to getSystemService(NotificationManager::class.java).areNotificationsEnabled())).toString())
                "validate" -> background(result) { Mobile.validate(call.arguments as String); null }
                "start" -> {
                    if (pending != null) { result.error("busy", "连接请求正在处理", null); return@setMethodCallHandler }
                    if (QingzhouVpnService.state != "disconnected" && QingzhouVpnService.state != "error") { result.error("busy", "代理正在运行", null); return@setMethodCallHandler }
                    pending = result; pendingRequest = call.arguments as String
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 3003)
                    } else requestVpnConsent()
                }
                "stop", "recover" -> {
                    startService(Intent(this, QingzhouVpnService::class.java).setAction("stop"))
                    awaitState(result, false, 0)
                }
                "probe" -> background(result) {
                    if(QingzhouVpnService.state!="disconnected" && QingzhouVpnService.state!="error")error("代理运行中")
                    val probe=Mobile.newSession(filesDir.resolve("probe").absolutePath,ProbeHost(this))
                    try {probe.startProbe(call.arguments as String);val request=JSONObject(call.arguments as String);val tag="node-"+request.getJSONObject("selected").getString("id").lowercase();JSONObject(mapOf("milliseconds" to probe.delay(tag))).toString()} finally {probe.stop()}
                }
                "delay" -> background(result) { val ms=QingzhouVpnService.session?.delay(call.arguments as String) ?: error("代理未连接");JSONObject(mapOf("milliseconds" to ms)).toString() }
                "query" -> background(result) { QingzhouVpnService.session?.query(call.arguments as String) ?: error("代理未连接") }
                "select" -> background(result) { QingzhouVpnService.session?.select(call.arguments as String) ?: error("代理未连接"); null }
                "export" -> {
                    if (exportResult != null) {result.error("busy", "文件导出正在进行", null); return@setMethodCallHandler}
                    val args = call.arguments as Map<*, *>
                    val bytes = args["bytes"] as ByteArray
                    if (bytes.size > 48 * 1024 * 1024) { result.error("size", "文件过大", null); return@setMethodCallHandler }
                    exportResult = result; exportBytes = bytes
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, args["name"] as String), 3002)
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun background(result: MethodChannel.Result, operation: () -> Any?) {
        executor.execute { try {val value = operation();main.post {result.success(value)}} catch (_: Exception) {main.post {result.error("runtime", "平台运行操作失败", null)}} }
    }
    private fun startTunnel() {
        val request = pendingRequest ?: return
        pendingRequest = null
        try {
            QingzhouVpnService.state = "connecting"
            startForegroundService(Intent(this, QingzhouVpnService::class.java).setAction("start").putExtra("request", request))
            pending?.let {awaitState(it, true, 0)}
        } catch (_: Exception) {
            QingzhouVpnService.state = "error"
            pending?.error("start", "VPN 服务启动失败", null)
        }
        pending = null
    }
    private fun requestVpnConsent() {
        if (pending == null) return
        try {
            val consent = VpnService.prepare(this)
            if (consent != null) startActivityForResult(consent, 3001) else startTunnel()
        } catch (_: Exception) {
            pending?.error("permission", "无法请求 VPN 授权", null)
            pending = null; pendingRequest = null
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // 通知授权与 VPN 授权分开处理；通知被拒绝时在界面提示限制。
        if (requestCode == 3003) requestVpnConsent()
    }
    private fun awaitState(result: MethodChannel.Result, connecting: Boolean, attempt: Int) {
        val state = QingzhouVpnService.state
        if ((connecting && state == "connected") || (!connecting && state == "disconnected")) {result.success(null);return}
        if ((connecting && state == "error") || attempt >= 350) {
            if(connecting && attempt >= 350) {
                // 核心启动超时后排队断开，避免界面报错后服务继续保持连接。
                runCatching {startService(Intent(this,QingzhouVpnService::class.java).setAction("stop"))}
            }
            result.error("runtime", "连接或网络恢复失败，请检查 VPN 冲突与配置", null);return
        }
        main.postDelayed({awaitState(result, connecting, attempt + 1)}, 100)
    }
    @Deprecated("兼容 FlutterActivity 的系统授权回调")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 3001) {
            if (resultCode == Activity.RESULT_OK) startTunnel() else { pending?.error("denied", "VPN 授权已取消", null); pending = null; pendingRequest = null }
        }
        if (requestCode == 3002) {
            val result = exportResult; val bytes = exportBytes; exportResult = null; exportBytes = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {result?.success(null);return}
            if (result != null && bytes != null) background(result) {contentResolver.openOutputStream(data.data!!, "wt")!!.use {it.write(bytes)};null}
        }
    }
    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        pendingRequest = null; pending = null; exportBytes = null; exportResult = null
        executor.shutdown()
        super.onDestroy()
    }

}
