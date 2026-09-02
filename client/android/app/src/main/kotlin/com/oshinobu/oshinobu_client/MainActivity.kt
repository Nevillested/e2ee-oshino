package com.oshinobu.oshinobu_client

import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.database.Cursor
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.util.Rational
import android.view.WindowManager
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.core.view.OnApplyWindowInsetsListener
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

private const val TAG = "MainActivity"
private const val PIP_CHANNEL = "oshinobu/pip"

// См. setupKeyboardInsetsTracking() — обходит известный баг рассинхронизации
// MediaQuery.viewInsets с настоящей клавиатурой на Android (edge-to-edge +
// системный back-жест, см. flutter/flutter#168768 и связанные issues:
// #89914, #131152, #116836). Вместо того чтобы полагаться на то, как Flutter
// сам довозит это значение до Dart (в этом сценарии ненадёжно — либо
// зависает на старом значении, либо приходит одним прыжком заметно позже
// настоящей системной анимации), читаем ВЫСОТУ IME напрямую с нативной
// стороны через WindowInsetsAnimationCallback — покадрово, включая
// промежуточные значения ВО ВРЕМЯ самой системной анимации.
private const val KEYBOARD_INSETS_CHANNEL = "oshinobu/keyboard_insets"

// См. openWithChooser() — ТЗ пользователя: тап по файлу должен всегда
// открывать системное меню "через какое приложение открыть", а не молча
// открывать в приложении, назначенном по умолчанию (обычное поведение
// ACTION_VIEW без обёртки в Intent.createChooser — плагин open_file именно
// так и делает, см. его OpenFilePlugin.startActivity()). Тот же
// FileProvider authority, что уже регистрирует сам плагин open_file в
// своём AndroidManifest.xml (мёрджится в общий манифест автоматически) —
// отдельный provider заводить не нужно, пути (весь filesDir/cacheDir)
// уже открыты его же filepaths.xml.
private const val OPEN_WITH_CHOOSER_CHANNEL = "oshinobu/open_with_chooser"
private const val OPEN_FILE_PROVIDER_AUTHORITY_SUFFIX = ".fileProvider.com.crazecoder.openfile"

// См. saveToDownloads() — ТЗ пользователя: "Сохранить на устройство" должно
// класть файл в предсказуемое фиксированное место (Downloads/Oshinobu), а
// не открывать системный SAF-диалог "Сохранить как" (тот на части устройств/
// эмуляторов — без нормального Files-провайдера — просто ничего не
// показывает, см. разбор с пользователем).
private const val SAVE_TO_DOWNLOADS_CHANNEL = "oshinobu/save_to_downloads"
private const val DOWNLOADS_SUBFOLDER = "Oshinobu"

// См. MediaDownloadForegroundService + media_download_foreground.dart:
// Dart-движок скачивания (MediaDownloadManager) просит поднять/убрать
// тонкий foreground-сервис, который держит процесс живым, пока идёт
// запрошенная пользователем загрузка файла и приложение свёрнуто.
private const val MEDIA_DL_FGS_CHANNEL = "oshinobu/media_download_fgs"

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

// FlutterFragmentActivity (не обычная FlutterActivity) — обязательное
// требование local_auth на Android: системный BiometricPrompt (отпечаток/
// распознавание лица, см. app_lock_store.dart) работает только через
// androidx.biometric, которому нужна именно FragmentActivity. Все уже
// переопределённые здесь методы (PiP/кэш движка/звонки) без изменений —
// FlutterFragmentActivity реализует тот же Flutter-embedding интерфейс,
// это дроп-ин замена базового класса.
class MainActivity : FlutterFragmentActivity() {
    // Держим свой канал, чтобы слать pipModeChanged из onPictureInPictureModeChanged
    // без повторного создания MethodChannel на лету.
    private var pipChannel: MethodChannel? = null
    private var callActive = false

    // См. KEYBOARD_INSETS_CHANNEL выше — простое поле класса, а не состояние
    // внутри самого EventChannel.StreamHandler: тот же приём, что и у
    // pipChannel — configureFlutterEngine() может отработать повторно для
    // ТОЙ ЖЕ Dart-стороны (см. shouldDestroyEngineWithHost=false выше),
    // тогда пересоздаётся сам объект EventChannel/handler, но Dart уже мог
    // подписаться раньше и заново onListen() не позовёт — храня sink здесь,
    // а не внутри одноразового handler'а, emitKeyboardHeight() продолжает
    // работать независимо от того, когда именно Dart подписался.
    private var keyboardInsetsSink: EventChannel.EventSink? = null

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

    // По умолчанию Flutter создаёт свой движок ЗАНОВО под каждую новую
    // Activity и уничтожает его вместе со старой (onDestroy → engine.destroy()).
    // Это ровно то, что рвёт активный звонок: смахивание задачи из "недавних"
    // уничтожает Activity (и с ней — движок, Dart-изолят, CallService,
    // WebRTC-соединение), даже если сам ПРОЦЕСС уцелел (см.
    // OngoingCallService — именно он не даёт Android убить процесс целиком,
    // пока разговор активен). Без удержания движка процесс мог бы выжить,
    // но при повторном входе получил бы СОВЕРШЕННО НОВЫЙ, пустой
    // CallService — то есть "звонок-призрак": звук по факту оборвался бы
    // всё равно (движок с реальным WebRTC-соединением уничтожен), а заново
    // открытое приложение ничего не знало бы о нём.
    //
    // Оба метода ниже — задокументированный Flutter-паттерн "cache and
    // reuse a FlutterEngine": движок кэшируется уже в configureFlutterEngine
    // (см. MAIN_ENGINE_ID выше), здесь он просто (а) не уничтожается вместе
    // с Activity и (б) переиспользуется следующей Activity вместо создания
    // нового. Вне звонков это тоже безвредно — если процесс всё-таки убьют
    // (например, банальная нехватка памяти без активного foreground-сервиса),
    // кэш умирает вместе с ним, и следующий запуск как обычно поднимет всё
    // с нуля.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        val cached = FlutterEngineCache.getInstance().get(MAIN_ENGINE_ID)
        if (cached != null) {
            Log.d(TAG, "provideFlutterEngine: переиспользую закэшированный движок $cached")
            return cached
        }
        Log.d(TAG, "provideFlutterEngine: кэш пуст, создаю новый движок как обычно")
        return super.provideFlutterEngine(context)
    }

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OPEN_WITH_CHOOSER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val path = call.argument<String>("path")
                    val mimeType = call.argument<String>("mimeType")
                    if (path == null) {
                        result.error("open_with_chooser", "path is null", null)
                    } else {
                        result.success(openWithChooser(path, mimeType))
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAVE_TO_DOWNLOADS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "save" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val fileName = call.argument<String>("fileName")
                    if (sourcePath == null || fileName == null) {
                        result.error("save_to_downloads", "sourcePath/fileName is null", null)
                    } else {
                        result.success(saveToDownloads(sourcePath, fileName))
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_DL_FGS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val text = call.argument<String>("text") ?: "Загрузка файлов"
                    val channelName = call.argument<String>("channelName") ?: "Загрузка файлов"
                    val channelDescription = call.argument<String>("channelDescription") ?: ""
                    MediaDownloadForegroundService.start(
                        applicationContext, text, channelName, channelDescription,
                    )
                    result.success(null)
                }
                "stop" -> {
                    MediaDownloadForegroundService.stop(applicationContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, KEYBOARD_INSETS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    keyboardInsetsSink = events
                }

                override fun onCancel(arguments: Any?) {
                    keyboardInsetsSink = null
                }
            },
        )
        setupKeyboardInsetsTracking()
    }

    // Возвращает true, если чем-то удалось открыть (пусть даже единственным
    // подходящим приложением — Intent.createChooser показывает диалог и
    // тогда, если вариант всего один, просто без выбора нечего показывать),
    // false — на устройстве вообще нет ни одного приложения для этого типа
    // файла (ActivityNotFoundException) — вызывающая сторона в этом случае
    // покажет свою собственную ошибку.
    private fun openWithChooser(path: String, mimeType: String?): Boolean {
        return try {
            val file = File(path)
            val authority = "$packageName$OPEN_FILE_PROVIDER_AUTHORITY_SUFFIX"
            val uri = FileProvider.getUriForFile(this, authority, file)
            val resolvedType = mimeType
                ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
                ?: "*/*"
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, resolvedType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val chooser = Intent.createChooser(viewIntent, null).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(chooser)
            true
        } catch (e: Exception) {
            Log.w(TAG, "openWithChooser: не удалось открыть $path: $e")
            false
        }
    }

    // Копирует уже расшифрованный файл (sourcePath — временная копия из
    // MediaCache/localSourcePath, см. chat_screen.dart) в постоянную папку
    // Download/Oshinobu — фиксированное, предсказуемое место, без
    // SAF-диалога "Сохранить как" (тот на части устройств/эмуляторов без
    // нормального Files-провайдера просто ничего не показывает — реальный
    // кейс с эмулятора, разбор с пользователем). Возвращает
    // человекочитаемый путь для снэкбара ("Download/Oshinobu/файл.pdf") —
    // либо null при ошибке.
    //
    // API 29+ (Q) — только через MediaStore.Downloads: прямая запись в
    // Environment.DIRECTORY_DOWNLOADS обычным File API запрещена scoped
    // storage. API ниже 29 — WRITE_EXTERNAL_STORAGE (см. манифест,
    // maxSdkVersion=28) всё ещё разрешает обычный File.
    private fun saveToDownloads(sourcePath: String, fileName: String): String? {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) return null
        val (baseName, ext) = splitNameAndExtension(fileName)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveToDownloadsMediaStore(sourceFile, baseName, ext)
            } else {
                saveToDownloadsLegacy(sourceFile, baseName, ext)
            }
        } catch (e: Exception) {
            Log.w(TAG, "saveToDownloads: не удалось сохранить $fileName: $e")
            null
        }
    }

    private fun splitNameAndExtension(fileName: String): Pair<String, String> {
        val dot = fileName.lastIndexOf('.')
        if (dot <= 0 || dot == fileName.length - 1) return Pair(fileName, "")
        return Pair(fileName.substring(0, dot), fileName.substring(dot + 1))
    }

    private fun candidateName(baseName: String, ext: String, attempt: Int): String {
        val name = if (attempt == 0) baseName else "$baseName ($attempt)"
        return if (ext.isEmpty()) name else "$name.$ext"
    }

    private fun saveToDownloadsMediaStore(
        sourceFile: File,
        baseName: String,
        ext: String,
    ): String? {
        val resolver = contentResolver
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$DOWNLOADS_SUBFOLDER"
        // Дедупликация имён — та же папка вполне может уже содержать файл с
        // таким же именем (пересохранили ещё раз, или два разных файла в
        // чате случайно называются одинаково); молча перезаписывать чужой
        // файл не должны, поэтому ищем первое свободное "имя (N).расш".
        var finalName = candidateName(baseName, ext, 0)
        var attempt = 1
        while (mediaStoreFileExists(resolver, finalName, relativePath)) {
            finalName = candidateName(baseName, ext, attempt)
            attempt++
        }
        val mimeType = if (ext.isNotEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.lowercase())
        } else {
            null
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, finalName)
            put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
            put(MediaStore.Downloads.IS_PENDING, 1)
            if (mimeType != null) put(MediaStore.Downloads.MIME_TYPE, mimeType)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
        resolver.openOutputStream(uri)?.use { out ->
            sourceFile.inputStream().use { input -> input.copyTo(out) }
        } ?: return null
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return "$relativePath/$finalName"
    }

    private fun mediaStoreFileExists(resolver: android.content.ContentResolver, displayName: String, relativePath: String): Boolean {
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?"
        val args = arrayOf(displayName, "$relativePath/")
        var cursor: Cursor? = null
        return try {
            cursor = resolver.query(MediaStore.Downloads.EXTERNAL_CONTENT_URI, projection, selection, args, null)
            (cursor?.count ?: 0) > 0
        } finally {
            cursor?.close()
        }
    }

    private fun saveToDownloadsLegacy(sourceFile: File, baseName: String, ext: String): String {
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), DOWNLOADS_SUBFOLDER)
        if (!dir.exists()) dir.mkdirs()
        var finalName = candidateName(baseName, ext, 0)
        var attempt = 1
        while (File(dir, finalName).exists()) {
            finalName = candidateName(baseName, ext, attempt)
            attempt++
        }
        val destFile = File(dir, finalName)
        sourceFile.copyTo(destFile)
        // Без этого файл невидим для других приложений (в т.ч. системного
        // "Файлы") до следующей перезагрузки/полного пересканирования —
        // MediaScannerConnection сообщает системе о новом файле сразу.
        MediaScannerConnection.scanFile(this, arrayOf(destFile.absolutePath), null, null)
        return "$DOWNLOADS_SUBFOLDER/$finalName"
    }

    // См. KEYBOARD_INSETS_CHANNEL выше — два независимых источника, оба шлют
    // в один и тот же sink:
    // 1) OnApplyWindowInsetsListener — срабатывает на КАЖДУЮ доставку
    //    insets'ов, включая мгновенные (не анимированные) изменения и
    //    начало/конец анимации — гарантирует, что настоящее итоговое
    //    значение долетит, даже если по какой-то причине анимация вообще не
    //    запустилась (в этом и была родная проблема — Flutter сам иногда
    //    вообще не получает промежуточные кадры, только один прыжок в конце,
    //    иногда с опозданием; здесь же читаем прямо у системы).
    // 2) WindowInsetsAnimationCompat.Callback.onProgress — покадрово, ПОКА
    //    системная анимация клавиатуры реально идёт, что и даёт плавность
    //    там, где она есть в самой системе (а не только там, где Flutter её
    //    сам придумал поверх).
    // DISPATCH_MODE_STOP — не пропускаем insets дальше по дереву самостоятельно
    // (Flutter ниже по дереву их всё равно не резервирует под это никак).
    private fun setupKeyboardInsetsTracking() {
        val root = window.decorView
        ViewCompat.setOnApplyWindowInsetsListener(
            root,
            OnApplyWindowInsetsListener { _, insets ->
                emitKeyboardHeight(insets.getInsets(WindowInsetsCompat.Type.ime()).bottom)
                insets
            },
        )
        ViewCompat.setWindowInsetsAnimationCallback(
            root,
            object : WindowInsetsAnimationCompat.Callback(WindowInsetsAnimationCompat.Callback.DISPATCH_MODE_STOP) {
                override fun onProgress(
                    insets: WindowInsetsCompat,
                    runningAnimations: MutableList<WindowInsetsAnimationCompat>,
                ): WindowInsetsCompat {
                    val imeAnimating = runningAnimations.any {
                        (it.typeMask and WindowInsetsCompat.Type.ime()) != 0
                    }
                    if (imeAnimating) {
                        emitKeyboardHeight(insets.getInsets(WindowInsetsCompat.Type.ime()).bottom)
                    }
                    return insets
                }
            },
        )
    }

    private fun emitKeyboardHeight(px: Int) {
        keyboardInsetsSink?.success(px.toDouble())
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
