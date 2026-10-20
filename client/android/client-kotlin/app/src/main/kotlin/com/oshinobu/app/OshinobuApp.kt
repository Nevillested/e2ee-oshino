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
import com.oshinobu.app.system.AppUpdater
import com.oshinobu.app.system.CrashDiagnostics
import com.oshinobu.app.system.PushService
import com.oshinobu.app.system.TransfersService
import com.oshinobu.app.system.installedVersionCode
import com.oshinobu.app.ui.theme.AppColors
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
 * Процесс приложения: ядро ([OshinobuCore]) поверх хранилищ телефона
 * (модуль :flutter-compat), глобальный перехват падений в журнал, язык интерфейса и
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
    lateinit var updater: AppUpdater
        private set

    /** Тема приложения (по умолчанию тёмно-синяя); меняется в настройках сразу, без перезапуска. */
    val theme = MutableStateFlow(AppColors.Navy)

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
        updater = AppUpdater(this, core)
        applyLocale(core.settings.locale())
        textScale.value = core.settings.textScale()
        // копия ключа темы читается сразу; нет её (выбирали до +62) — дочитываем из secure storage
        val cachedTheme = core.settings.themeNow()
        if (cachedTheme != null) theme.value = AppColors.byId(cachedTheme)
        else core.scope.launch { theme.value = AppColors.byId(core.settings.theme()) }
        watchNetwork()
        calls = CallController(this, core).also { it.start() }
        PushService.registerOnSessionStart(core)
        TransfersService.follow(this, core)
    }

    fun setTheme(colors: AppColors) {
        theme.value = colors
        core.scope.launch { core.settings.setTheme(colors.id) }
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

    /** Язык из настроек приложения (свой, не системный; по умолчанию en). */
    fun applyLocale(tag: String) {
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(tag))
    }

    /**
     * Сеть появилась/пропала/сменилась — WebSocket переподключается сразу, а не по
     * таймеру. Смена основной сети (Wi-Fi → мобильная) приходит одним onAvailable
     * новой сети, без onLost старой, — её ловим по смене самой сети.
     */
    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java)
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            private var current: Network? = null

            override fun onAvailable(network: Network) {
                val previous = current
                current = network
                if (previous != null && previous != network) core.onNetworkSwitched() else core.ws.onNetworkAvailable()
            }

            override fun onLost(network: Network) {
                if (network == current) current = null
                core.ws.onNetworkLost()
            }
        })
    }
}

val Context.app: OshinobuApp get() = applicationContext as OshinobuApp
