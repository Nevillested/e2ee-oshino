package com.oshinobu.oshinobu_client

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

private const val TAG = "MainActivity"
private const val PIP_CHANNEL = "oshinobu/pip"

// Те же ключи используются в CallRingService/call_ring_plugin (отдельный
// Gradle-модуль, поэтому не общие константы, а просто одинаковые строки в
// обоих местах).
private const val EXTRA_SHOW_OVER_LOCKSCREEN = "oshinobu.SHOW_OVER_LOCKSCREEN"
private const val EXTRA_AUTO_ACCEPT = "oshinobu.AUTO_ACCEPT_CALL"
private const val EXTRA_OPEN_CALL_SCREEN = "oshinobu.OPEN_CALL_SCREEN"

// Ключ, под которым живой движок кэшируется в FlutterEngineCache — по нему
// его находит EndCallReceiver (call_ring_plugin), у которого своего
// Activity/Flutter-движка нет: кнопка "Завершить звонок" в уведомлении
// "Идёт разговор" не может идти через обычный action у
// flutter_local_notifications (тот для действий без открытия UI ВСЕГДА
// поднимает отдельный, изолированный от живого приложения движок — там
// свой пустой CallService, никак не связанный с реальным звонком, поэтому
// такая кнопка молча ничего не делала). Вместо этого уведомление и кнопка
// собраны нативно в call_ring_plugin, а обработчик достаёт именно ЭТОТ,
// ЖИВОЙ движок из кэша и зовёт его напрямую.
private const val MAIN_ENGINE_ID = "main_engine"

class MainActivity : FlutterActivity() {
    // Держим свой канал, чтобы слать pipModeChanged из onPictureInPictureModeChanged
    // без повторного создания MethodChannel на лету.
    private var pipChannel: MethodChannel? = null
    private var callActive = false

    // Автовход в PiP при сворачивании имеет смысл ТОЛЬКО если собеседник
    // сейчас реально передаёт видео — иначе сворачивать в плавающее окошко
    // просто нечего показывать. Для аудио-звонка вместо этого показывается
    // обычное уведомление "идёт разговор" (см. Dart-сторону) — на ручной
    // вход через кнопку в CallScreen (enterPipNow) это ограничение не
    // распространяется, пользователь явно так решил.
    private var remoteVideoActive = false

    // Android НЕ различает на уровне API "пользователь развернул PiP кнопкой
    // разворота внутри самого окошка" и "пользователь заново открыл
    // приложение через лаунчер/недавние" — оба случая выходят из PiP через
    // один и тот же onPictureInPictureModeChanged(false), без указания
    // источника. Единственный доступный нам признак: при повторном открытии
    // через лаунчер Android ДОСТАВЛЯЕТ обычный intent (ACTION_MAIN +
    // CATEGORY_LAUNCHER) в onNewIntent — а разворот кнопкой внутри PiP
    // никакого intent не несёт вообще, это чисто оконная операция. Поэтому
    // ловим такой intent сюда и используем это как признак "это не разворот
    // кнопкой", когда чуть позже придёт колбэк выхода из PiP.
    //
    // Это эвристика, а не гарантия API — поведение проверено логически, но
    // не на реальном устройстве; если оно не подтвердится в тестах, придётся
    // подбирать сигнал заново по логам.
    private var pendingLauncherReopen = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(
            TAG,
            "onCreate: savedInstanceState=${savedInstanceState != null} " +
                "autoAccept=${intent?.getBooleanExtra(EXTRA_AUTO_ACCEPT, false)} " +
                "openCallScreen=${intent?.getBooleanExtra(EXTRA_OPEN_CALL_SCREEN, false)} " +
                "action=${intent?.action} categories=${intent?.categories} " +
                "extras=${intent?.extras?.keySet()?.joinToString()}",
        )
        applyLockScreenFlagsIfNeeded(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(
            TAG,
            "onNewIntent: action=${intent.action} categories=${intent.categories} " +
                "autoAccept=${intent.getBooleanExtra(EXTRA_AUTO_ACCEPT, false)} " +
                "openCallScreen=${intent.getBooleanExtra(EXTRA_OPEN_CALL_SCREEN, false)} " +
                "extras=${intent.extras?.keySet()?.joinToString()}",
        )
        // Activity уже жива (запущена в singleTop) — без этого getIntent()
        // по-прежнему возвращал бы СТАРЫЙ intent, и consumeAutoAccept() не
        // увидел бы флаг из нового запуска (нажатия "Ответить" по
        // уведомлению, когда приложение не было полностью закрыто).
        setIntent(intent)
        applyLockScreenFlagsIfNeeded(intent)

        // Признак именно повторного открытия через лаунчер/недавние — см.
        // комментарий у pendingLauncherReopen выше.
        //
        // ВАЖНО: ВСЕ наши собственные intent'ы (accept-call из
        // CallRingService.buildLaunchIntent, тап по уведомлению "Идёт
        // разговор" из OngoingCallNotifier) тоже строятся через
        // getLaunchIntentForPackage() и потому ТОЖЕ несут ACTION_MAIN +
        // CATEGORY_LAUNCHER — без доп. проверки на наши собственные экстры
        // это ложно засчитывалось бы как "повторное открытие через лаунчер"
        // даже для них. Раньше это и произошло: intent от кнопки "Ответить"
        // выставил pendingLauncherReopen=true, а поскольку сбрасывается он
        // только при следующей смене PiP-режима, это значение "протекло" в
        // совершенно не связанную, гораздо более позднюю сессию PiP и
        // ошибочно классифицировало настоящий разворот кнопкой как
        // переоткрытие через лаунчер.
        val isOwnPurposeBuiltIntent =
            intent.getBooleanExtra(EXTRA_AUTO_ACCEPT, false) || intent.getBooleanExtra(EXTRA_OPEN_CALL_SCREEN, false)
        if (
            intent.action == Intent.ACTION_MAIN &&
            intent.categories?.contains(Intent.CATEGORY_LAUNCHER) == true &&
            !isOwnPurposeBuiltIntent
        ) {
            Log.d(TAG, "onNewIntent: похоже на повторное открытие через лаунчер")
            pendingLauncherReopen = true
        }

        // Приложение уже было живо (не холодный старт) — HomePlaceholderScreen
        // не пересоздастся и не спросит consumeAutoAccept() заново сама.
        // Поэтому именно для этого случая явно ТОЛКАЕМ событие в Dart —
        // движок и его обработчики уже точно готовы их принять.
        if (intent.getBooleanExtra(EXTRA_AUTO_ACCEPT, false)) {
            intent.removeExtra(EXTRA_AUTO_ACCEPT)
            if (pipChannel == null) {
                Log.e(TAG, "onNewIntent: autoAccept=true, НО pipChannel==null — событие потеряно, Dart его не увидит")
            } else {
                Log.d(TAG, "onNewIntent: отправляю autoAcceptRequested в Dart")
                pipChannel?.invokeMethod(
                    "autoAcceptRequested",
                    null,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            Log.d(TAG, "onNewIntent: autoAcceptRequested доставлен и обработан Dart-стороной")
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                            Log.e(TAG, "onNewIntent: autoAcceptRequested провалился: $errorCode $errorMessage")
                        }

                        override fun notImplemented() {
                            Log.e(TAG, "onNewIntent: autoAcceptRequested — Dart не слушает этот канал (notImplemented)")
                        }
                    },
                )
            }
        }

        // Тап по уведомлению "Идёт разговор" (не по кнопке "Завершить
        // звонок", а по самому телу) — уведомление собрано нативно (см.
        // OngoingCallNotifier в call_ring_plugin), поэтому и открытие экрана
        // разговора помечается так же, через intent-экстру, а не через
        // payload flutter_local_notifications.
        if (intent.getBooleanExtra(EXTRA_OPEN_CALL_SCREEN, false)) {
            intent.removeExtra(EXTRA_OPEN_CALL_SCREEN)
            Log.d(TAG, "onNewIntent: отправляю openCallScreenRequested в Dart, pipChannel=$pipChannel")
            pipChannel?.invokeMethod("openCallScreenRequested", null)
        }
    }

    // Уведомление о входящем звонке (CallRingService) запускает эту Activity
    // через fullScreenIntent — но чтобы она реально нарисовалась ПОВЕРХ
    // экрана блокировки (а не легла позади него, становясь видимой только
    // после свайпа/разблокировки — то, что мы и видели до этого фикса),
    // сама Activity должна явно попросить об этом систему. Делаем это
    // только когда запуск явно помечен как "про звонок" — чтобы обычное
    // открытие приложения по-прежнему уважало блокировку экрана.
    private fun applyLockScreenFlagsIfNeeded(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_SHOW_OVER_LOCKSCREEN, false) != true) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(MAIN_ENGINE_ID, flutterEngine)
        Log.d(TAG, "configureFlutterEngine: движок закэширован под '$MAIN_ENGINE_ID', engine=$flutterEngine")
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
        pipChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setCallActive" -> {
                    callActive = call.argument<Boolean>("active") ?: false
                    updatePipParams()
                    result.success(null)
                }
                "setRemoteVideoActive" -> {
                    remoteVideoActive = call.argument<Boolean>("active") ?: false
                    updatePipParams()
                    result.success(null)
                }
                "enterPipNow" -> {
                    // Ручной вход по кнопке в CallScreen — работает всегда,
                    // независимо от того, есть ли видео у собеседника,
                    // пользователь явно об этом попросил.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val params = PictureInPictureParams.Builder()
                            .setAspectRatio(Rational(9, 16))
                            .build()
                        enterPictureInPictureMode(params)
                    }
                    result.success(null)
                }
                "exitPip" -> {
                    // У Android нет прямого "exitPictureInPictureMode()" —
                    // общепринятый обходной путь: заново запустить ту же
                    // Activity с REORDER_TO_FRONT, что возвращает её на весь
                    // экран и тем самым закрывает PiP-окошко. Используется,
                    // когда звонок завершился, пока PiP был активен —
                    // видео иначе осталось бы висеть замороженным кадром.
                    if (isInPictureInPictureMode) {
                        val reorderIntent = Intent(this, MainActivity::class.java).apply {
                            addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        }
                        startActivity(reorderIntent)
                    }
                    result.success(null)
                }
                "clearShowWhenLocked" -> {
                    clearShowWhenLocked()
                    result.success(null)
                }
                "consumeAutoAccept" -> {
                    // "Consume" — читаем и сразу стираем флаг из текущего
                    // intent, чтобы повторный вызов (или следующий обычный
                    // звонок в рамках той же сессии Activity) не принял
                    // чужой звонок автоматически по ошибке.
                    val autoAccept = intent?.getBooleanExtra(EXTRA_AUTO_ACCEPT, false) ?: false
                    intent?.removeExtra(EXTRA_AUTO_ACCEPT)
                    Log.d(TAG, "consumeAutoAccept() -> $autoAccept")
                    result.success(autoAccept)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun clearShowWhenLocked() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(false)
            setTurnScreenOn(false)
        } else {
            window.clearFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
            )
        }
    }

    // На Android 12+ setAutoEnterEnabled сам переводит активность в PiP при
    // сворачивании — ничего больше делать не нужно. На 8–11 такого флага
    // нет, поэтому там вход запускается вручную из onUserLeaveHint. В обоих
    // случаях — только если есть реальное видео собеседника, иначе
    // сворачивание идёт как обычно (Dart-сторона покажет уведомление о
    // разговоре вместо этого).
    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(9, 16))
                .setAutoEnterEnabled(callActive && remoteVideoActive)
                .build()
            setPictureInPictureParams(params)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (callActive && remoteVideoActive &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S
        ) {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(9, 16))
                .build()
            enterPictureInPictureMode(params)
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)

        // Выходим из PiP — см. комментарий у pendingLauncherReopen: если
        // прямо перед этим не было "лаунчерного" intent, считаем, что это
        // пользователь развернул PiP собственной кнопкой разворота внутри
        // самого окошка — тогда Dart-стороне нужно вернуть полноэкранный
        // CallScreen. Если же intent был — значит, это скорее открытие
        // приложения через лаунчер/недавние, и полноэкранный экран звонка
        // показывать НЕ нужно (пользователь должен увидеть обычное
        // приложение, звонок продолжается в фоне, вернуться на экран
        // разговора можно через уведомление).
        val reason = if (!isInPictureInPictureMode) {
            val wasLauncherReopen = pendingLauncherReopen
            pendingLauncherReopen = false
            if (wasLauncherReopen) "reopen" else "expand"
        } else {
            // Входим в PiP — сбрасываем флаг здесь тоже, а не только на
            // выходе: иначе интент, вообще не имеющий отношения к PiP (см.
            // комментарий выше про "Ответить"), мог случиться ДО входа в
            // эту PiP-сессию и по ошибке засчитаться при следующем выходе
            // из неё, хотя реального переоткрытия через лаунчер во время
            // этой конкретной сессии PiP не было.
            pendingLauncherReopen = false
            null
        }
        Log.d(TAG, "onPictureInPictureModeChanged: isInPip=$isInPictureInPictureMode, reason=$reason")
        pipChannel?.invokeMethod(
            "pipModeChanged",
            mapOf("isInPip" to isInPictureInPictureMode, "reason" to reason),
        )
    }
}
