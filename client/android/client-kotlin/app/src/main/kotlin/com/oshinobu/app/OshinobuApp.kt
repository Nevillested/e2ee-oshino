package com.oshinobu.app

import android.app.Application
import android.content.Context
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Network
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import com.oshinobu.app.call.CallController
import com.oshinobu.app.call.WebRtcEngine
import com.oshinobu.app.system.CrashDiagnostics
import com.oshinobu.app.system.PushService
import com.oshinobu.app.system.TransfersService
import com.oshinobu.app.ui.update.installedVersionCode
import com.oshinobu.compat.FlutterPrefsAdapter
import com.oshinobu.compat.FlutterSecureStoreAdapter
import com.oshinobu.compat.flutterAppDirs
import com.oshinobu.core.OshinobuCore
import com.oshinobu.core.net.ApiConfig
import com.oshinobu.core.service.Logger
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * Процесс приложения: ядро ([OshinobuCore]) поверх тех же хранилищ, что
 * у Flutter-сборки, глобальный перехват падений в журнал, язык интерфейса и
 * подписка на сеть устройства для WebSocket.
 */
class OshinobuApp : Application() {
    lateinit var core: OshinobuCore
        private set
    lateinit var routerHost: AndroidRouterHost
        private set
    lateinit var rtc: WebRtcEngine
        private set
    lateinit var calls: CallController
        private set

    /** Тёмная тема (как во Flutter — по умолчанию тёмная); меняется в настройках сразу, без перезапуска. */
    val darkTheme = MutableStateFlow(true)

    /** Масштаб текста интерфейса (настройка "Размер шрифта"). */
    val textScale = MutableStateFlow(1.0)

    override fun onCreate() {
        super.onCreate()
        routerHost = AndroidRouterHost(this)
        // журнал ядра ещё не создан — WebRTC пишет в него, когда дойдёт до дела
        rtc = WebRtcEngine(
            this,
            object : Logger {
                override fun log(message: String) = core.logger.log(message)
                override fun error(message: String) = core.logger.error(message)
            },
        )
        core = OshinobuCore(
            secure = FlutterSecureStoreAdapter(this),
            prefs = FlutterPrefsAdapter(this),
            dirs = flutterAppDirs(this),
            routerHost = routerHost,
            rtcEngine = rtc,
            config = ApiConfig(appVersionCode = installedVersionCode()),
        )
        CrashDiagnostics.install(this)
        applyLocale(core.settings.locale())
        textScale.value = core.settings.textScale()
        core.scope.launch { darkTheme.value = core.settings.theme() != "light" }
        watchNetwork()
        calls = CallController(this, core).also { it.start() }
        PushService.registerOnSessionStart(core)
        TransfersService.follow(this, core)
    }

    fun setDarkTheme(dark: Boolean) {
        darkTheme.value = dark
        core.scope.launch { core.settings.setTheme(if (dark) "dark" else "light") }
    }

    fun setTextScale(scale: Double) {
        textScale.value = scale
        core.settings.setTextScale(scale)
    }

    fun setLanguage(tag: String) {
        core.settings.setLocale(tag)
        applyLocale(tag)
        // язык аккаунта на сервере — для писем и пушей; не критично, если не выйдет
        core.scope.launch { runCatching { core.session.token?.let { core.api.updateLanguage(it, tag) } } }
    }

    /**
     * Контекст на языке приложения — для уведомлений и сервисов: до Android 13
     * AppCompat меняет язык только у Activity, а не у самого приложения.
     */
    fun localized(): Context {
        val config = Configuration(resources.configuration)
        config.setLocale(Locale.forLanguageTag(core.settings.locale()))
        return createConfigurationContext(config)
    }

    /** Язык из настроек приложения (как во Flutter: свой, не системный; по умолчанию en). */
    fun applyLocale(tag: String) {
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(tag))
    }

    /** Сеть появилась/пропала — WebSocket переподключается сразу, а не по таймеру. */
    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java)
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = core.ws.onNetworkAvailable()
            override fun onLost(network: Network) = core.ws.onNetworkLost()
        })
    }
}

val Context.app: OshinobuApp get() = applicationContext as OshinobuApp
