package cn.qingzhou.qingzhou
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import cn.qingzhou.bridge.mobile.Host
import org.json.JSONArray
import org.json.JSONObject
import java.net.NetworkInterface

object NetworkState {
    fun physicalNetwork(connectivity: ConnectivityManager): android.net.Network? {
        val candidates = connectivity.allNetworks.filter {
            val c = connectivity.getNetworkCapabilities(it)
            c?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true && !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
        return candidates.firstOrNull {it == connectivity.activeNetwork} ?: candidates.maxByOrNull {
            val c = connectivity.getNetworkCapabilities(it)!!
            (if(c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 4 else 0) +
                (if(c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) 2 else 0)
        }
    }
    fun interfaces(context: Context): String {
        val connectivity=context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val result = JSONArray()
        for (network in connectivity.allNetworks) {
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            val link = connectivity.getLinkProperties(network) ?: continue
            val name = link.interfaceName ?: continue
            val it = NetworkInterface.getByName(name) ?: continue
            result.put(JSONObject(mapOf("Name" to name,"Index" to it.index,"MTU" to if(it.mtu>0)it.mtu else 1500,"Addresses" to link.linkAddresses.map {"${it.address.hostAddress}/${it.prefixLength}"},"DNS" to link.dnsServers.map {it.hostAddress},"Type" to if(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))1 else if(caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR))2 else 3,"Metered" to !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))))
        }
        return result.toString()
    }
    fun defaultInterface(context: Context): String {
        val connectivity=context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = physicalNetwork(connectivity) ?: return JSONObject(mapOf("Name" to "","Index" to -1)).toString()
        val link=connectivity.getLinkProperties(network) ?: error("底层网络不可用")
        val caps=connectivity.getNetworkCapabilities(network) ?: error("底层网络不可用")
        val name=link.interfaceName ?: error("网络接口缺失")
        return JSONObject(mapOf("Name" to name,"Index" to (NetworkInterface.getByName(name)?.index ?: -1),"Expensive" to !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),"Constrained" to false)).toString()
    }
}
class ProbeHost(private val context: Context): Host {
    override fun openTun(options: String): Int {error("测速禁止打开隧道")}
    override fun protectSocket(fd: Int) {}
    override fun isExtension() = false
    override fun interfaces() = NetworkState.interfaces(context)
    override fun defaultInterface() = NetworkState.defaultInterface(context)
}
