package net.hideip.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState

/**
 * Android VpnService that hosts the sing-box core (via libbox).
 *
 * The flow:
 *  1. Libbox.setup() once with writable paths.
 *  2. Create a CommandServer with this class as both the PlatformInterface
 *     (so sing-box can ask us to open the TUN) and the CommandServerHandler.
 *  3. start() + startOrReloadService(configJson) boots the proxy.
 *
 * openTun() is where the real Android tunnel is built: sing-box hands us the
 * addresses, routes and MTU it wants, and we turn that into a VpnService TUN
 * file descriptor.
 */
class HideipVpnService : VpnService(), PlatformInterface, CommandServerHandler {

    companion object {
        private const val TAG = "HideipVpn"
        private const val NOTIF_CHANNEL = "hideip_vpn"
        private const val NOTIF_ID = 1

        const val ACTION_START = "net.hideip.vpn.START"
        const val ACTION_STOP = "net.hideip.vpn.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_LABEL = "label"

        // Native prefs shared with MainActivity: whether the user opted into
        // Always-on support in the app's own settings. The system's Always-on
        // toggle lives in Android settings and is out of our control; this flag
        // decides how we respond when the system starts us because of it.
        const val NATIVE_PREFS = "hideip_native"
        const val KEY_ALWAYS_ON = "always_on_enabled"
        const val KEY_KILL_SWITCH = "kill_switch_enabled"
        private const val LAST_CONFIG_FILE = "last_config.enc"
        private const val LEGACY_CONFIG_FILE = "last_config.json"
        private const val LAST_LABEL_FILE = "last_label.txt"

        /** Updated so Flutter can poll/observe status. */
        @Volatile var running: Boolean = false
            private set
        @Volatile var lastError: String? = null
            private set

        /** Whether Android's system Always-on VPN is enabled for this app, as
         *  last observed by the service. The UI uses it to warn the user that a
         *  disconnect may leave the system holding traffic. */
        @Volatile var alwaysOnActive: Boolean = false
            private set

        // Live traffic counters, fed by the sing-box status CommandClient. Rates
        // are bytes/second over the last interval; totals are cumulative bytes for
        // this session. Flutter polls these via the `stats` method channel.
        @Volatile var uplink: Long = 0
        @Volatile var downlink: Long = 0
        @Volatile var uplinkTotal: Long = 0
        @Volatile var downlinkTotal: Long = 0

        private fun resetStats() {
            uplink = 0; downlink = 0; uplinkTotal = 0; downlinkTotal = 0
        }
    }

    private var commandServer: CommandServer? = null
    // Local client that subscribes to the core's status stream for live traffic.
    private var statusClient: CommandClient? = null
    private var tunFd: ParcelFileDescriptor? = null
    // The raw tun fd handed to the sing-box core. We force-close it on stop
    // because this libbox build does not reliably close it itself.
    private var coreTunFd: Int = -1
    private var setupDone = false

    // Distinguishes teardown the user (or the system) asked for from the core
    // dying on its own. serviceStop() consults it: an unexpected death with the
    // kill switch on triggers a reconnect instead of a teardown.
    @Volatile private var stopRequested = false
    private var lastReconnectAt = 0L
    private var reconnectAttempts = 0

    // Default-network monitoring. sing-box's `auto_detect_interface` needs to be
    // told which physical interface its (protected) outbound sockets should bind
    // to. We feed it Android's current default network via this callback; without
    // it, the core has no underlying interface and outbound dials go nowhere.
    private var connectivityManager: ConnectivityManager? = null
    private var defaultNetworkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var interfaceListener: InterfaceUpdateListener? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel(startId)
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG)
                if (config.isNullOrBlank()) {
                    lastError = "Empty config"
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                val label = intent.getStringExtra(EXTRA_LABEL)
                persistLastConfig(config, label)
                startTunnel(config, label)
            }
            else -> {
                // System-initiated start: Android's Always-on VPN restarts the
                // service with SERVICE_INTERFACE (or a null intent). Reconnect
                // with the last used config ONLY when the user opted into
                // Always-on inside the app's settings; otherwise bow out
                // immediately so we never hold traffic the user didn't ask us
                // to hold.
                val allowed = getSharedPreferences(NATIVE_PREFS, MODE_PRIVATE)
                    .getBoolean(KEY_ALWAYS_ON, false)
                val saved = if (allowed) readLastConfig() else null
                if (saved != null) {
                    Log.i(TAG, "always-on start: reconnecting last profile")
                    startTunnel(saved.first, saved.second)
                } else {
                    Log.i(TAG, "always-on start refused (not enabled in app settings)")
                    stopSelf(startId)
                }
            }
        }
        // NOT_STICKY: a VPN must never silently auto-restart after being killed,
        // and a sticky redelivery would also keep the service "started" so that
        // stopSelf() couldn't fully tear it down (leaving tun0 + the VPN key up).
        return START_NOT_STICKY
    }

    /** Keep the last config around for system-initiated (Always-on) starts,
     *  when there is no Flutter side to hand us one. App-private storage. */
    private fun persistLastConfig(config: String, label: String?) {
        try {
            val encrypted = java.io.File(filesDir, LAST_CONFIG_FILE)
            ConfigVault.write(encrypted, config)
            if (ConfigVault.read(encrypted) != config) {
                throw IllegalStateException("encrypted config verification failed")
            }
            java.io.File(filesDir, LEGACY_CONFIG_FILE).delete()
            java.io.File(filesDir, LAST_LABEL_FILE).writeText(label ?: "")
        } catch (e: Exception) {
            Log.w(TAG, "persistLastConfig: ${e.message}")
        }
    }

    private fun readLastConfig(): Pair<String, String?>? {
        return try {
            val encrypted = java.io.File(filesDir, LAST_CONFIG_FILE)
            var config = ConfigVault.read(encrypted)
            if (config.isNullOrBlank()) {
                val legacy = java.io.File(filesDir, LEGACY_CONFIG_FILE)
                    .takeIf { it.exists() }?.readText()
                if (!legacy.isNullOrBlank()) {
                    ConfigVault.write(encrypted, legacy)
                    if (ConfigVault.read(encrypted) == legacy) {
                        java.io.File(filesDir, LEGACY_CONFIG_FILE).delete()
                    }
                    config = legacy
                }
            }
            if (config.isNullOrBlank()) return null
            val label = java.io.File(filesDir, LAST_LABEL_FILE)
                .takeIf { it.exists() }?.readText()?.ifBlank { null }
            config to label
        } catch (e: Exception) {
            Log.w(TAG, "readLastConfig: ${e.message}")
            null
        }
    }

    private fun ensureSetup() {
        if (setupDone) return
        val base = filesDir.absolutePath
        val opts = SetupOptions().apply {
            basePath = base
            workingPath = "$base/work"
            tempPath = cacheDir.absolutePath
            // Go runtime tweak required on Android.
            fixAndroidStack = true
        }
        java.io.File("$base/work").mkdirs()
        Libbox.setup(opts)
        setupDone = true
    }

    private fun startTunnel(config: String, label: String? = null) {
        stopRequested = false
        try {
            ensureSetup()
            startForegroundNotification(label)

            // Validate before we try to run it, so we surface clean errors.
            Libbox.checkConfig(config)

            val server = Libbox.newCommandServer(this, this)
            server.start()
            server.startOrReloadService(config, OverrideOptions())
            commandServer = server

            resetStats()
            startStatusClient()

            lastError = null
            running = true
            // Snapshot the system Always-on state while we can (instance method,
            // API 29+); the UI reads it to warn about disconnect-while-always-on.
            alwaysOnActive = Build.VERSION.SDK_INT >= 29 && isAlwaysOn
            Log.i(TAG, "sing-box tunnel started (alwaysOn=$alwaysOnActive)")
        } catch (e: Exception) {
            lastError = e.message ?: e.toString()
            Log.e(TAG, "startTunnel failed", e)
            stopTunnel()
        }
    }

    /**
     * Subscribes to the core's status stream so we get live traffic counters.
     * The client connects to the same in-process command server we just started.
     * Failure here is non-fatal: the tunnel still works, we just show no stats.
     */
    private fun startStatusClient() {
        try {
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandStatus)
                statusInterval = 1_000_000_000L // 1s, in nanoseconds
            }
            val client = CommandClient(StatusHandler(), options)
            client.connect()
            statusClient = client
        } catch (e: Exception) {
            Log.w(TAG, "startStatusClient failed: ${e.message}")
        }
    }

    /** Receives the status stream; we only care about the traffic numbers. */
    private inner class StatusHandler : CommandClientHandler {
        override fun connected() {}
        override fun disconnected(message: String?) {}
        override fun writeStatus(message: StatusMessage) {
            uplink = message.uplink
            downlink = message.downlink
            uplinkTotal = message.uplinkTotal
            downlinkTotal = message.downlinkTotal
        }

        // Unused command channels; we only registered CommandStatus.
        override fun clearLogs() {}
        override fun writeLogs(messages: LogIterator?) {}
        override fun writeGroups(groups: OutboundGroupIterator?) {}
        override fun writeConnectionEvents(events: ConnectionEvents?) {}
        override fun initializeClashMode(modes: StringIterator?, current: String?) {}
        override fun updateClashMode(mode: String?) {}
        override fun setDefaultLogLevel(level: Int) {}
    }

    private fun stopTunnel(stopStartId: Int = -1) {
        // Every intentional teardown funnels through here; mark it before
        // closeService so the serviceStop callback it triggers doesn't read
        // this as the core dying and try to reconnect.
        stopRequested = true
        running = false

        // Drop the status client before the server it reads from goes away.
        try {
            statusClient?.disconnect()
        } catch (e: Exception) {
            Log.w(TAG, "statusClient disconnect: ${e.message}")
        }
        statusClient = null
        resetStats()

        // Tear down our default-network monitor first so no late callback can
        // re-touch a half-closed core.
        try {
            closeDefaultInterfaceMonitor(interfaceListener)
        } catch (e: Exception) {
            Log.w(TAG, "closeDefaultInterfaceMonitor: ${e.message}")
        }

        // Tell sing-box to stop FIRST so the core stops reading the fd / releases
        // its auto_route handling, then drop our own fd.
        try {
            commandServer?.closeService()
        } catch (e: Exception) {
            Log.w(TAG, "closeService: ${e.message}")
        }
        try {
            commandServer?.close()
        } catch (e: Exception) {
            Log.w(TAG, "close: ${e.message}")
        }
        commandServer = null

        // Close OUR retained fd; we kept the establish() owner (a dup went to the
        // core). Android tears down the tun interface (and removes the status-bar
        // VPN key) only when the establish() owner's fd is closed. This is the
        // step that actually brings the tunnel down.
        try {
            tunFd?.close()
        } catch (_: Exception) {}
        tunFd = null

        // Force-close the fd the core was given. This is what finally drops the
        // tun interface (and the status-bar VPN key): Android keeps the VPN up as
        // long as ANY fd points at /dev/tun, and this libbox build leaks it.
        // adoptFd() wraps the raw int in a ParcelFileDescriptor that owns it, so
        // close() performs the actual close(2).
        if (coreTunFd >= 0) {
            try {
                ParcelFileDescriptor.adoptFd(coreTunFd).close()
                Log.i(TAG, "force-closed core tun fd=$coreTunFd")
            } catch (e: Exception) {
                Log.w(TAG, "force-close core tun fd: ${e.message}")
            }
            coreTunFd = -1
        }

        // Remove the foreground notification and stop the service for good.
        // stopSelf(startId) matches the exact start command so Android actually
        // DESTROYS the service (onDestroy); a bare stopSelf() leaves it alive if
        // any start command is unmatched, and the VpnService instance staying
        // alive is what kept tun0 + the status-bar VPN key up after disconnect.
        stopForegroundCompat()
        if (stopStartId >= 0) stopSelf(stopStartId) else stopSelf()
        Log.i(TAG, "sing-box tunnel stopped")
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy")
        if (running) stopTunnel()
        super.onDestroy()
    }

    override fun onRevoke() {
        // Another VPN took over, or the user revoked consent.
        Log.i(TAG, "onRevoke")
        stopTunnel()
        super.onRevoke()
    }

    // ---------------------------------------------------------------------
    // PlatformInterface: openTun is the bridge from sing-box to Android VPN.
    // ---------------------------------------------------------------------

    override fun openTun(options: TunOptions): Int {
        val builder = Builder()
        builder.setMtu(options.mtu)
        builder.setSession("hideip")

        // IPv4 addresses sing-box assigned to the tunnel.
        val inet4 = options.inet4Address
        while (inet4.hasNext()) {
            val p = inet4.next()
            builder.addAddress(p.address(), p.prefix())
        }
        // IPv6 addresses, if any.
        val inet6 = options.inet6Address
        while (inet6.hasNext()) {
            val p = inet6.next()
            builder.addAddress(p.address(), p.prefix())
        }

        if (options.autoRoute) {
            // Route everything through the tunnel.
            val r4 = options.inet4RouteAddress
            if (r4.hasNext()) {
                while (r4.hasNext()) {
                    val p = r4.next()
                    builder.addRoute(p.address(), p.prefix())
                }
            } else {
                builder.addRoute("0.0.0.0", 0)
            }
            val r6 = options.inet6RouteAddress
            if (r6.hasNext()) {
                while (r6.hasNext()) {
                    val p = r6.next()
                    builder.addRoute(p.address(), p.prefix())
                }
            }
            // DNS the core wants us to advertise.
            try {
                val dns = options.dnsServerAddress
                builder.addDnsServer(dns.value)
            } catch (_: Exception) {}
        }

        // NOTE: we intentionally do NOT exclude our own app from the tunnel.
        // sing-box's outbound dial to the server is already kept off the tunnel
        // by protect(fd) in autoDetectInterfaceControl, so there is no loop.
        // Routing our own traffic through the VPN means the in-app IP check (and
        // any future in-app browsing) is actually protected like every other app.

        // Per-app routing requested by the config.
        val include = options.includePackage
        var addedIncluded = false
        while (include.hasNext()) {
            try {
                builder.addAllowedApplication(include.next()); addedIncluded = true
            } catch (_: Exception) {}
        }
        if (!addedIncluded) {
            val exclude = options.excludePackage
            while (exclude.hasNext()) {
                try {
                    builder.addDisallowedApplication(exclude.next())
                } catch (_: Exception) {}
            }
        }

        val pfd = builder.establish() ?: throw IllegalStateException("VPN establish() returned null (permission revoked?)")
        // Hand the core the raw fd. The core reads/polls it; on shutdown it is
        // SUPPOSED to close it, but this libbox build leaks it (an fd to /dev/tun
        // stays open after closeService, keeping the interface + VPN key alive).
        // So we remember the number and force-close it ourselves in stopTunnel().
        val rawFd = pfd.detachFd()
        coreTunFd = rawFd
        tunFd = null
        return rawFd
    }

    // The remaining PlatformInterface methods are not required to bring up a
    // basic tunnel. We provide safe defaults; auto-detect interface control is
    // delegated to the platform so sing-box uses Android's own routing.

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun useProcFS(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun underNetworkExtension(): Boolean = false

    override fun findConnectionOwner(
        ipProto: Int, srcIp: String?, srcPort: Int, destIp: String?, destPort: Int
    ): io.nekohasekai.libbox.ConnectionOwner {
        // sing-box derefs the result; returning null SIGSEGVs the core.
        // We don't do per-process routing in v1, so report "not found".
        throw UnsupportedOperationException("process matching disabled")
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        // sing-box's auto-detect resolves the bind interface against this list.
        // Returning the real device interfaces (with kernel index + flags) is
        // what lets a protected outbound socket actually find a route out.
        val boxes = ArrayList<io.nekohasekai.libbox.NetworkInterface>()
        try {
            val nifs = java.net.NetworkInterface.getNetworkInterfaces() ?: java.util.Collections.emptyEnumeration()
            for (nif in nifs) {
                val box = io.nekohasekai.libbox.NetworkInterface()
                box.name = nif.name
                box.index = nif.index
                box.mtu = try { nif.mtu } catch (_: Exception) { 1500 }
                val addrs = ArrayList<String>()
                for (ia in nif.interfaceAddresses) {
                    val host = ia.address?.hostAddress ?: continue
                    // Strip any scope id (e.g. fe80::1%wlan0); Go can't parse it.
                    val clean = host.substringBefore('%')
                    addrs.add("$clean/${ia.networkPrefixLength}")
                }
                box.addresses = StringList(addrs)
                var flags = 0
                if (nif.isUp) flags = flags or 0x1          // net.FlagUp
                if (nif.isLoopback) flags = flags or 0x4    // net.FlagLoopback
                if (nif.isPointToPoint) flags = flags or 0x8 // net.FlagPointToPoint
                if (nif.supportsMulticast()) flags = flags or 0x10 // net.FlagMulticast
                box.flags = flags
                box.metered = false
                boxes.add(box)
            }
        } catch (e: Exception) {
            Log.w(TAG, "getInterfaces: ${e.message}")
        }
        return InterfaceListIterator(boxes)
    }

    /** Minimal StringIterator over a Kotlin list, for libbox NetworkInterface. */
    private class StringList(private val items: List<String>) : StringIterator {
        private var i = 0
        override fun hasNext(): Boolean = i < items.size
        override fun next(): String = items[i++]
        override fun len(): Int = items.size
    }

    private class InterfaceListIterator(
        private val items: List<io.nekohasekai.libbox.NetworkInterface>,
    ) : NetworkInterfaceIterator {
        private var i = 0
        override fun hasNext(): Boolean = i < items.size
        override fun next(): io.nekohasekai.libbox.NetworkInterface = items[i++]
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        interfaceListener = listener
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivityManager = cm

        // On ANY default-network change we re-scan for the best non-VPN physical
        // network and report THAT (never the VPN itself). registerDefaultNetwork-
        // Callback() needs no special permission, and routing the decision through
        // pushBestUnderlyingInterface() means even when the callback fires for our
        // own tun0 we still hand the core wlan0/cellular; no loop, no race.
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                pushBestUnderlyingInterface()
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                pushBestUnderlyingInterface()
            }

            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) {
                pushBestUnderlyingInterface()
            }

            override fun onLost(network: Network) {
                // A network dropped: re-resolve; if none remain, report "none".
                if (!pushBestUnderlyingInterface()) {
                    try {
                        interfaceListener?.updateDefaultInterface("", -1, false, false)
                    } catch (e: Exception) {
                        Log.w(TAG, "updateDefaultInterface(lost): ${e.message}")
                    }
                }
            }
        }
        defaultNetworkCallback = callback

        try {
            cm.registerDefaultNetworkCallback(callback)
        } catch (e: Exception) {
            Log.e(TAG, "registerDefaultNetworkCallback failed", e)
        }

        // Push the current underlying network immediately so the core doesn't
        // wait for the first async callback before it can dial out.
        try {
            pushBestUnderlyingInterface()
        } catch (e: Exception) {
            Log.w(TAG, "initial pushBestUnderlyingInterface: ${e.message}")
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        val cb = defaultNetworkCallback
        val cm = connectivityManager
        if (cb != null && cm != null) {
            try {
                cm.unregisterNetworkCallback(cb)
            } catch (e: Exception) {
                Log.w(TAG, "unregisterNetworkCallback: ${e.message}")
            }
        }
        defaultNetworkCallback = null
        interfaceListener = null
    }

    /** Scan all networks for a non-VPN INTERNET one and report it. Returns true
     *  if an interface was successfully handed to the core. */
    private fun pushBestUnderlyingInterface(): Boolean {
        val cm = connectivityManager ?: return false
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            ) {
                return pushDefaultInterface(network, caps)
            }
        }
        return false
    }

    /** Resolve [network] to an interface name/index and hand it to the core.
     *  Returns true if an interface was reported. */
    private fun pushDefaultInterface(
        network: Network,
        caps: NetworkCapabilities? = null,
        lp: LinkProperties? = null,
    ): Boolean {
        val listener = interfaceListener ?: return false
        val cm = connectivityManager ?: return false
        try {
            val capabilities = caps ?: cm.getNetworkCapabilities(network)
            // Never report our own VPN tunnel as the underlying interface; that
            // would make sing-box bind outbound sockets back into tun0 (a loop).
            if (capabilities != null &&
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            ) {
                return false
            }

            val linkProps = lp ?: cm.getLinkProperties(network) ?: return false
            val ifaceName = linkProps.interfaceName ?: return false
            // The kernel interface index is what sing-box binds sockets to.
            val nif = java.net.NetworkInterface.getByName(ifaceName) ?: return false
            val index = nif.index

            val isExpensive = capabilities?.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_NOT_METERED
            )?.not() ?: false
            val isConstrained = if (Build.VERSION.SDK_INT >= 34) {
                capabilities?.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED
                )?.not() ?: false
            } else {
                false
            }

            listener.updateDefaultInterface(ifaceName, index, isExpensive, isConstrained)
            Log.d(TAG, "default interface -> $ifaceName (index $index)")
            return true
        } catch (e: Exception) {
            Log.w(TAG, "pushDefaultInterface: ${e.message}")
            return false
        }
    }

    // Android has no usable resolv.conf for the Go resolver. Resolve bootstrap
    // hostnames using the physical network's system resolver, never the VPN.
    override fun localDNSTransport(): io.nekohasekai.libbox.LocalDNSTransport =
        object : io.nekohasekai.libbox.LocalDNSTransport {
            override fun raw(): Boolean = false

            override fun lookup(
                ctx: io.nekohasekai.libbox.ExchangeContext?,
                network: String?,
                domain: String?,
            ) {
                requireNotNull(ctx)
                require(!domain.isNullOrBlank())
                val cm = connectivityManager ?: throw java.io.IOException("No physical network")
                fun usable(n: Network): Boolean {
                    val caps = cm.getNetworkCapabilities(n) ?: return false
                    return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                }
                val physical = cm.activeNetwork?.takeIf(::usable)
                    ?: cm.allNetworks.firstOrNull(::usable)
                    ?: throw java.io.IOException("No physical network")
                val addresses = physical.getAllByName(domain).filter {
                    when (network) {
                        "ip4" -> it is java.net.Inet4Address
                        "ip6" -> it is java.net.Inet6Address
                        else -> true
                    }
                }
                ctx.success(addresses.joinToString("\n") { it.hostAddress!!.substringBefore('%') })
            }

            override fun exchange(ctx: io.nekohasekai.libbox.ExchangeContext?, message: ByteArray?) {
                throw UnsupportedOperationException("Only bootstrap address lookups are supported")
            }
        }

    override fun systemCertificates(): StringIterator? = null

    override fun readWIFIState(): WIFIState? = null

    override fun clearDNSCache() {}

    override fun sendNotification(notification: io.nekohasekai.libbox.Notification?) {}

    // ---------------------------------------------------------------------
    // CommandServerHandler
    // ---------------------------------------------------------------------

    override fun serviceReload() {
        Log.i(TAG, "serviceReload")
    }

    override fun serviceStop() {
        if (!stopRequested && killSwitchEnabled()) {
            android.os.Handler(mainLooper).post { reconnectForKillSwitch() }
        } else {
            stopTunnel()
        }
    }

    private fun killSwitchEnabled(): Boolean =
        getSharedPreferences(NATIVE_PREFS, MODE_PRIVATE)
            .getBoolean(KEY_KILL_SWITCH, false)

    /** The core died without anyone asking it to and the kill switch is on:
     *  restart it with the last config instead of tearing the tunnel down.
     *  The current TUN stays up through the restart, so with the default
     *  route still pointing at it traffic blackholes instead of leaking out
     *  the physical interface; the fresh core's openTun() establishes a
     *  replacement interface, and only then is the old core fd closed. */
    private fun reconnectForKillSwitch() {
        if (stopRequested) return
        val saved = readLastConfig()
        // Rapid successive deaths mean something is genuinely broken (bad
        // config, revoked permission); give up so we don't loop forever.
        val now = android.os.SystemClock.elapsedRealtime()
        reconnectAttempts =
            if (now - lastReconnectAt < 15_000) reconnectAttempts + 1 else 1
        lastReconnectAt = now
        if (saved == null || reconnectAttempts > 3) {
            Log.w(TAG, "kill switch: giving up after $reconnectAttempts attempts")
            lastError = "Connection dropped"
            stopTunnel()
            return
        }
        Log.i(TAG, "kill switch: core died, reconnecting (attempt $reconnectAttempts)")
        val staleFd = coreTunFd
        coreTunFd = -1
        try {
            statusClient?.disconnect()
        } catch (_: Exception) {}
        statusClient = null
        try {
            closeDefaultInterfaceMonitor(interfaceListener)
        } catch (_: Exception) {}
        // The core is already dead, so no closeService(); just drop the server.
        try {
            commandServer?.close()
        } catch (e: Exception) {
            Log.w(TAG, "close: ${e.message}")
        }
        commandServer = null
        startTunnel(saved.first, saved.second)
        if (staleFd >= 0) {
            try {
                ParcelFileDescriptor.adoptFd(staleFd).close()
            } catch (_: Exception) {}
        }
    }

    override fun getSystemProxyStatus(): io.nekohasekai.libbox.SystemProxyStatus? = null

    override fun setSystemProxyEnabled(enabled: Boolean) {}

    override fun writeDebugMessage(message: String?) {
        if (message != null) Log.d(TAG, message)
    }

    // ---------------------------------------------------------------------
    // Foreground notification (required for a long-running VPN service).
    // ---------------------------------------------------------------------

    private fun startForegroundNotification(label: String? = null) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIF_CHANNEL, "hideip VPN", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows the active VPN connection"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }

        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

        // Tapping the notification opens the app.
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )

        // The action button stops the tunnel via our own ACTION_STOP.
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, HideipVpnService::class.java).setAction(ACTION_STOP),
            flags,
        )

        val text = if (!label.isNullOrBlank()) "Connected · $label" else "Connected"
        val notif: Notification =
            Notification.Builder(this, NOTIF_CHANNEL)
                .setContentTitle("hideip.net")
                .setContentText(text)
                .setSmallIcon(R.drawable.ic_stat_vpn)
                .setContentIntent(openIntent)
                .addAction(
                    Notification.Action.Builder(
                        Icon.createWithResource(this, R.drawable.ic_stat_vpn),
                        "Disconnect", stopIntent,
                    ).build()
                )
                .setOngoing(true)
                .build()
        startForeground(NOTIF_ID, notif)
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
