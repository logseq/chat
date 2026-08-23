package logseq.chat

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

object AndroidNetworkAvailabilityMonitor {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    fun initialize(context: Context) {
        val manager = context.applicationContext
            .getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                publish(true)
            }

            override fun onLost(network: Network) {
                publish(isConnected(manager))
            }

            override fun onUnavailable() {
                publish(false)
            }
        }
        publish(isConnected(manager))
        manager.registerDefaultNetworkCallback(callback)
    }

    private fun publish(available: Boolean) {
        scope.launch {
            LogseqChatRuntime.shared.syncCoordinator.setNetworkAvailable(available)
        }
    }

    private fun isConnected(manager: ConnectivityManager): Boolean {
        val network = manager.activeNetwork ?: return false
        val capabilities = manager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }
}
