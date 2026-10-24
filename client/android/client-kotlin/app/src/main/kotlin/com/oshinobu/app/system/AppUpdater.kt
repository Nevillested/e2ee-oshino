package com.oshinobu.app.system

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.annotation.StringRes
import androidx.core.content.FileProvider
import com.google.android.play.core.appupdate.AppUpdateInfo
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.install.model.UpdateAvailability
import com.oshinobu.app.R
import com.oshinobu.core.OshinobuCore
import com.oshinobu.core.net.AppVersionInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

/** versionCode установленного приложения. */
fun Context.installedVersionCode(): Int = packageInfoVersion(packageManager.getPackageInfo(packageName, 0))

private fun packageInfoVersion(info: PackageInfo): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode.toInt() else @Suppress("DEPRECATION") info.versionCode

/** Поставлено из Google Play (иначе — APK-файлом). */
fun Context.installedFromPlay(): Boolean {
    val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        runCatching { packageManager.getInstallSourceInfo(packageName).installingPackageName }.getOrNull()
    } else {
        @Suppress("DEPRECATION")
        packageManager.getInstallerPackageName(packageName)
    }
    return installer == "com.android.vending"
}

/** APK обновления у установок не из Play. */
sealed interface ApkState {
    /** Ничего не происходит (скачанный APK, если есть, лежит на диске). */
    data object Idle : ApkState

    /** Смотрим, не скачан ли уже нужный APK. */
    data object Checking : ApkState

    /** Скачивается; [progress] 0..1, null — размер неизвестен. */
    data class Downloading(val progress: Float?) : ApkState

    /** Скачан APK версии [versionCode] (не старше последней) — можно ставить. */
    data class Ready(val file: File, val versionCode: Int) : ApkState

    data class Failed(@StringRes val message: Int) : ApkState
}

/**
 * Обновление приложения: есть что ставить — [updateReady], на главном экране кнопка
 * «Обновить приложение». Проверка ([checkForUpdate]) — при каждом входе в приложение и
 * дальше каждые [checkIntervalMs], пока оно на экране:
 *  - установка из Play — спрашиваем сам Play: кнопка появляется, только когда Play
 *    действительно готов обновить (публикация до телефона доходит не сразу), и по ней
 *    открывается его окно обновления; наш сервер для кнопки не нужен;
 *  - установка из APK — последнюю версию сообщает сервер, новее установленной —
 *    [available].
 *
 * Установки не из Play — APK с сервера, и без
 * лишних скачиваний: APK живёт в files/updates/ (кэш система может стереть сама)
 * до тех пор, пока установленная версия его не догонит; уже скачанный APK
 * последней версии ставится сразу, оборванное скачивание продолжается с места
 * обрыва (Range + If-Range: файл на сервере сменился — качаем заново).
 */
class AppUpdater(private val context: Context, private val core: OshinobuCore) {
    val installedVersion = context.installedVersionCode()
    val fromPlay = context.installedFromPlay()

    private val dir = File(context.filesDir, "updates")
    private val apk = File(dir, APK_NAME)
    private val part = File(dir, "$APK_NAME.part")

    /** Last-Modified (или ETag) файла на сервере, с которого начато [part]. */
    private val partValidator = File(dir, "$APK_NAME.part.validator")

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    /** Версия новее установленной, если сервер о такой сообщил; null — обновляться не на что. */
    val available: StateFlow<AppVersionInfo?> = core.api.latestVersion
        .map { latest -> latest?.takeIf { it.versionCode > installedVersion } }
        .stateIn(core.scope, SharingStarted.Eagerly, null)

    private val playUpdate = MutableStateFlow(false)

    /** Есть что ставить — показать кнопку «Обновить приложение». */
    val updateReady: StateFlow<Boolean> =
        combine(available, playUpdate) { server, play -> if (fromPlay) play else server != null }
            .stateIn(core.scope, SharingStarted.Eagerly, false)

    /** Как часто проверять, пока приложение на экране: Play отвечает с телефона, без нашего сервера. */
    val checkIntervalMs: Long = if (fromPlay) PLAY_CHECK_INTERVAL_MS else SERVER_CHECK_INTERVAL_MS

    private val _apkState = MutableStateFlow<ApkState>(ApkState.Idle)
    val apkState: StateFlow<ApkState> = _apkState.asStateFlow()

    private var job: Job? = null

    init {
        core.scope.launch { removeStale() }
    }

    /** Проверить, есть ли обновление (результат — в [updateReady]). */
    suspend fun checkForUpdate() {
        if (fromPlay) checkPlay() else core.api.getAppVersion()
    }

    /** Что Play знает об обновлении этой установки; null — Play не ответил. */
    suspend fun playUpdateInfo(): AppUpdateInfo? = suspendCancellableCoroutine { cont ->
        AppUpdateManagerFactory.create(context).appUpdateInfo
            .addOnSuccessListener { cont.resume(it) }
            .addOnFailureListener { cont.resume(null) }
    }

    private suspend fun checkPlay() {
        val info = playUpdateInfo() ?: return
        // начатое и брошенное обновление тоже считается: по кнопке Play его продолжит
        val ready = info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE ||
            info.updateAvailability() == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS
        if (ready != playUpdate.value) {
            core.logger.log("Update via Play: ready=$ready availableVersionCode=${info.availableVersionCode()} installed=$installedVersion")
        }
        playUpdate.value = ready
    }

    /**
     * Нажали «Обновить приложение» (установка не из Play): уже скачан APK не
     * старше [latest] — сразу [ApkState.Ready], иначе — скачивание.
     */
    fun prepare(latest: AppVersionInfo) {
        if (job?.isActive == true) return
        _apkState.value = ApkState.Checking
        job = core.scope.launch {
            val ready = downloadedApk()?.takeIf { it.versionCode >= latest.versionCode }
            if (ready != null) {
                _apkState.value = ready
                return@launch
            }
            val url = latest.apkUrl
            if (url == null) {
                _apkState.value = ApkState.Failed(R.string.update_failed)
                return@launch
            }
            _apkState.value = ApkState.Downloading(null)
            _apkState.value = try {
                download(url)
                val got = verifiedPart()
                if (got == null) {
                    ApkState.Failed(R.string.update_notNewer)
                } else {
                    apk.delete()
                    check(part.renameTo(apk)) { "не переименовать $part" }
                    partValidator.delete()
                    core.logger.log("Update apk downloaded versionCode=$got")
                    ApkState.Ready(apk, got)
                }
            } catch (e: Exception) {
                coroutineContext.ensureActive()
                core.logger.error("Update apk download failed: $e")
                ApkState.Failed(R.string.update_failed)
            }
        }
    }

    /** Отмена скачивания: скачанная часть остаётся — следующий раз продолжим с неё. */
    fun cancel() {
        job?.cancel()
        job = null
        _apkState.value = ApkState.Idle
    }

    /** Окно обновления закрыто («Позже», ошибка): скачанный APK остаётся на диске. */
    fun dismiss() {
        if (job?.isActive != true) _apkState.value = ApkState.Idle
    }

    /**
     * Открыть системную установку [file]. false — приложению не разрешено ставить
     * пакеты: открыты настройки этого разрешения, после них — нажать ещё раз.
     */
    fun install(file: File): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
            context.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return false
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        context.startActivity(
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, APK_MIME)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        _apkState.value = ApkState.Idle
        return true
    }

    /** Скачанный целиком APK этого приложения новее установленного. */
    private fun downloadedApk(): ApkState.Ready? {
        val code = archiveVersion(apk) ?: return null
        return if (code > installedVersion) ApkState.Ready(apk, code) else null
    }

    /** versionCode докачанного [part], если это APK этого приложения новее установленного. */
    private fun verifiedPart(): Int? {
        val code = archiveVersion(part)?.takeIf { it > installedVersion }
        if (code == null) {
            part.delete()
            partValidator.delete()
        }
        return code
    }

    /** versionCode APK-файла этого приложения; null — нет файла, не APK или чужой пакет. */
    private fun archiveVersion(file: File): Int? {
        if (!file.isFile) return null
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageArchiveInfo(file.path, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageArchiveInfo(file.path, 0)
        } ?: return null
        return if (info.packageName == context.packageName) packageInfoVersion(info) else null
    }

    /** Установленная версия догнала скачанный APK — он больше не нужен. */
    private fun removeStale() {
        // до +70 APK качался в кэш — там ему больше не место
        File(context.cacheDir, "updates").deleteRecursively()
        if (apk.isFile && downloadedApk() == null) {
            core.logger.log("Update apk removed: not newer than installed $installedVersion")
            apk.delete()
        }
    }

    /** Скачать [url] в [part], продолжая с места обрыва, если файл на сервере тот же. */
    private suspend fun download(url: String) = withContext(Dispatchers.IO) {
        dir.mkdirs()
        val validator = partValidator.takeIf { it.isFile }?.readText()?.takeIf { it.isNotBlank() }
        val offset = if (validator != null && part.isFile) part.length() else 0L
        val request = Request.Builder().url(url).apply {
            if (offset > 0) header("Range", "bytes=$offset-").header("If-Range", validator!!)
        }.build()
        val call = http.newCall(request)
        coroutineContext.job.invokeOnCompletion { call.cancel() }
        call.execute().use { response ->
            // докачивать нечего: часть уже целиком (оборвались между скачиванием и проверкой)
            if (response.code == HTTP_RANGE_NOT_SATISFIABLE && offset > 0) return@withContext
            val resumed = response.code == 206
            check(response.isSuccessful) { "HTTP ${response.code}" }
            val body = response.body ?: error("пустой ответ")
            val start = if (resumed) offset else 0L
            if (!resumed) {
                // с начала: файл на сервере новый (или докачивать нечего)
                partValidator.writeText(response.header("ETag") ?: response.header("Last-Modified").orEmpty())
            }
            val total = body.contentLength().takeIf { it > 0 }?.plus(start)
            core.logger.log("Update apk download from=$start total=$total")
            var done = start
            var shown = -1
            FileOutputStream(part, resumed).use { output ->
                body.byteStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        done += n
                        if (total != null) {
                            // по полпроцента — не дёргать интерфейс на каждые 64 КБ
                            val step = (done * 200 / total).toInt()
                            if (step != shown) {
                                shown = step
                                _apkState.value = ApkState.Downloading(done.toFloat() / total)
                            }
                        }
                    }
                }
            }
        }
    }

    private companion object {
        const val APK_NAME = "oshinobu.apk"
        const val APK_MIME = "application/vnd.android.package-archive"
        const val HTTP_RANGE_NOT_SATISFIABLE = 416
        const val PLAY_CHECK_INTERVAL_MS = 5 * 60_000L
        const val SERVER_CHECK_INTERVAL_MS = 60 * 60_000L
    }
}
