package com.oshinobu.app.ui.update

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.UpdateAvailability
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.ErrorLine
import com.oshinobu.app.ui.PrimaryButton
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.net.AppVersionInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import kotlin.coroutines.resume

/** versionCode установленного приложения. */
fun Context.installedVersionCode(): Int {
    val info = packageManager.getPackageInfo(packageName, 0)
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode.toInt() else @Suppress("DEPRECATION") info.versionCode
}

/** Поставлено из Google Play (иначе — APK-файлом). */
private fun Context.installedFromPlay(): Boolean {
    val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        runCatching { packageManager.getInstallSourceInfo(packageName).installingPackageName }.getOrNull()
    } else {
        @Suppress("DEPRECATION")
        packageManager.getInstallerPackageName(packageName)
    }
    return installer == "com.android.vending"
}

private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/**
 * Обязательная версия: сервер обслуживает только одну версию приложения. Не
 * совпадает (проверка при запуске и при каждом возвращении в приложение, плюс
 * любой ответ сервера 426) — вместо приложения экран "обновите", без вариантов.
 */
@Composable
fun UpdateGate(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val api = context.app.core.api
    val required by api.updateRequired.collectAsState()
    val scope = rememberCoroutineScope()
    val owner = LocalLifecycleOwner.current
    val mine = remember { context.installedVersionCode() }
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) {
                scope.launch {
                    val server = api.getAppVersion() ?: return@launch
                    if (server.versionCode != mine) api.noteUpdateRequired(server)
                }
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    val info = required
    if (info != null && info.versionCode != mine) UpdateScreen(info) else content()
}

@Composable
private fun UpdateScreen(info: AppVersionInfo) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    var progress by remember { mutableStateOf<Float?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val playUpdate = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { }

    BackHandler { context.activity()?.moveTaskToBack(true) }

    fun openMarket() {
        val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=${context.packageName}"))
        runCatching { context.startActivity(market) }.onFailure {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=${context.packageName}")))
        }
    }

    fun updateFromPlay() = scope.launch {
        val manager = AppUpdateManagerFactory.create(context)
        val update = suspendCancellableCoroutine { cont ->
            manager.appUpdateInfo.addOnSuccessListener { cont.resume(it) }.addOnFailureListener { cont.resume(null) }
        }
        val options = AppUpdateOptions.defaultOptions(AppUpdateType.IMMEDIATE)
        if (update != null && update.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE && update.isUpdateTypeAllowed(options)) {
            manager.startUpdateFlowForResult(update, playUpdate, options)
        } else {
            openMarket()
        }
    }

    fun updateFromApk() = scope.launch {
        val url = info.apkUrl ?: return@launch
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
            error = context.getString(R.string.update_allowInstall)
            context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")))
            return@launch
        }
        error = null
        progress = 0f
        val apk = runCatching { download(context, url) { progress = it } }.getOrNull()
        progress = null
        if (apk == null) {
            error = context.getString(R.string.update_failed)
            return@launch
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", apk)
        context.startActivity(
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    Box(Modifier.fillMaxSize().background(colors.background).padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Icon(Icons.Filled.SystemUpdate, null, tint = colors.primary, modifier = Modifier.size(64.dp))
            Spacer(Modifier.height(20.dp))
            Text(stringResource(R.string.update_title), color = colors.textPrimary, fontSize = 22.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(12.dp))
            Text(stringResource(R.string.update_body), color = colors.textMuted, textAlign = TextAlign.Center)
            Spacer(Modifier.height(28.dp))
            val p = progress
            if (p != null) {
                Text(stringResource(R.string.update_downloading), color = colors.textMuted)
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator(progress = { p }, modifier = Modifier.fillMaxWidth(), color = colors.primary)
            } else {
                PrimaryButton(stringResource(R.string.update_button), onClick = {
                    // APK не выложен — обновляться всё равно есть откуда: из Play
                    if (context.installedFromPlay() || info.apkUrl == null) updateFromPlay() else updateFromApk()
                })
            }
            ErrorLine(error)
        }
    }
}

/** Скачать APK в кэш (updates/oshinobu.apk) с прогрессом 0..1. */
private suspend fun download(context: Context, url: String, onProgress: (Float) -> Unit): File = withContext(Dispatchers.IO) {
    val dir = File(context.cacheDir, "updates").apply { mkdirs() }
    val target = File(dir, "oshinobu.apk")
    OkHttpClient().newCall(Request.Builder().url(url).build()).execute().use { response ->
        check(response.isSuccessful) { "HTTP ${response.code}" }
        val body = response.body ?: error("пустой ответ")
        val total = body.contentLength()
        body.byteStream().use { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var done = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    output.write(buffer, 0, n)
                    done += n
                    if (total > 0) withContext(Dispatchers.Main) { onProgress(done.toFloat() / total) }
                }
            }
        }
    }
    target
}
