package cn.qingzhou.qingzhou

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.ParcelFileDescriptor
import cn.qingzhou.bridge.mobile.Host
import cn.qingzhou.bridge.mobile.Mobile
import cn.qingzhou.bridge.mobile.Session
import org.json.JSONArray
import org.json.JSONObject
import java.net.NetworkInterface
import java.util.concurrent.Executors

class QingzhouVpnService : VpnService(), Host {
    companion object {
        @Volatile var state = "disconnected"
        @Volatile var session: Session? = null
    }
    private val worker = java.util.concurrent.Executors.newSingleThreadScheduledExecutor()
    override fun onCreate() {super.onCreate();worker.scheduleWithFixedDelay({if(state=="connected" && session?.running()!=true)closeTunnel()},2,2,java.util.concurrent.TimeUnit.SECONDS)}
    private var tunnel: ParcelFileDescriptor? = null
    private val connectivity get() = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop" || intent == null) {worker.execute {closeTunnel()};return START_NOT_STICKY}
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("vpn", "轻舟代理连接", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 1, Intent(this, javaClass).setAction("stop"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val open = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(1, Notification.Builder(this, "vpn").setContentTitle("轻舟代理").setContentText("VPN 服务运行中").setSmallIcon(android.R.drawable.stat_sys_upload_done).setContentIntent(open).addAction(Notification.Action.Builder(null,"断开",stop).build()).setOngoing(true).build())
        val request = intent.getStringExtra("request")
        worker.execute {
            try {
                if (request == null || session != null) error("运行请求无效")
                if (connectivity.allNetworks.any {connectivity.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true}) error("存在其他 VPN")
                val core = Mobile.newSession(filesDir.resolve("runtime").absolutePath, this)
                session = core
                core.start(request)
                state = "connected"
            } catch (_: Exception) {closeTunnel(true)}
        }
        return START_NOT_STICKY
    }
    private fun closeTunnel(failure: Boolean = false, stopService: Boolean = true) {
        val core = session; session = null
        val descriptor = tunnel; tunnel = null
        val coreFailed = runCatching {core?.stop()}.isFailure
        val descriptorFailed = runCatching {descriptor?.close()}.isFailure
        state = if(failure || coreFailed || descriptorFailed) "error" else "disconnected"
        runCatching {stopForeground(STOP_FOREGROUND_REMOVE)}
        if(stopService) stopSelf()
    }
    override fun onRevoke() {worker.execute {closeTunnel()};super.onRevoke()}
    override fun onDestroy() {worker.execute {closeTunnel(state=="error",false)};worker.shutdown();super.onDestroy()}
    override fun isExtension() = false
    override fun protectSocket(fd: Int) { if (!super.protect(fd)) error("底层连接绕行失败") }
    override fun openTun(options: String): Int {
        val o = JSONObject(options)
        val builder = Builder().setSession("轻舟代理").setMtu(o.getInt("mtu")).setBlocking(false)
        builder.addDisallowedApplication(packageName)
        if(o.optBoolean("httpProxy"))builder.setHttpProxy(android.net.ProxyInfo.buildDirectProxy("127.0.0.1",o.getInt("httpPort")))
        val addresses = o.getJSONArray("addresses")
        for (i in 0 until addresses.length()) {val p=addresses.getString(i).split('/');builder.addAddress(p[0],p[1].toInt())}
        val dns = o.getJSONArray("dns");for (i in 0 until dns.length()) builder.addDnsServer(dns.getString(i))
        val routes = o.getJSONArray("routes")
        if (routes.length() == 0) {builder.addRoute("0.0.0.0",0);if ((0 until addresses.length()).any {addresses.getString(it).contains(':')}) builder.addRoute("::",0)}
        else for (i in 0 until routes.length()) {val p=routes.getString(i).split('/');builder.addRoute(p[0],p[1].toInt())}
        if (o.getJSONArray("excludes").length() != 0) error("此构建尚未提供排除路由")
        val fd = builder.establish() ?: error("VPN 授权不可用")
        tunnel = fd
        return fd.fd
    }
    override fun interfaces() = NetworkState.interfaces(this)
    override fun defaultInterface(): String {
        setUnderlyingNetworks(NetworkState.physicalNetwork(connectivity)?.let {arrayOf(it)})
        return NetworkState.defaultInterface(this)
    }

}
