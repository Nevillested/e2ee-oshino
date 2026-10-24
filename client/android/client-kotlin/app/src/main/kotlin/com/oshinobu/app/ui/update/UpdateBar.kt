package com.oshinobu.app.ui.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.UpdateAvailability
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.system.ApkState
import com.oshinobu.app.ui.ErrorLine
import com.oshinobu.app.ui.home.AppDialog
import com.oshinobu.app.ui.home.DialogButton
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.net.AppVersionInfo
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

private const val BAR_MS = 350

/**
 * Кнопка «Обновить приложение» под панелью вкладок главного экрана — во всю
 * ширину, со скруглёнными верхними углами, в цветах темы; фон уходит под
 * системную панель навигации. Появляется, когда есть что ставить
 * ([com.oshinobu.app.system.AppUpdater.updateReady]): выезжает снизу, а содержимое экрана (и панель вкладок)
 * поднимается вместе с ней. Место под системной панелью держится всегда — как
 * без кнопки, поэтому ни появление, ни уход ничего не дёргают.
 */
@Composable
fun UpdateBar() {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val updater = context.app.updater
    val ready by updater.updateReady.collectAsState()
    val available by updater.available.collectAsState()
    val shown by animateFloatAsState(
        if (ready) 1f else 0f,
        tween(BAR_MS, easing = FastOutSlowInEasing),
        label = "updateBar",
    )
    val navBottom = WindowInsets.navigationBars.getBottom(LocalDensity.current)
    var dialog by remember { mutableStateOf<AppVersionInfo?>(null) }
    val updateFromPlay = rememberPlayUpdate()

    Box(
        Modifier
            .fillMaxWidth()
            .clipToBounds()
            .layout { measurable, constraints ->
                // видимая высота растёт от места под системной панелью до полной,
                // кнопка въезжает снизу из-за края экрана
                val bar = measurable.measure(constraints)
                val height = navBottom + ((bar.height - navBottom) * shown).roundToInt()
                layout(bar.width, height) {
                    if (shown > 0f) bar.place(0, height - (bar.height * shown).roundToInt())
                }
            },
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                .background(colors.primary)
                .clickable(enabled = ready) {
                    val latest = available
                    // APK не выложен — обновляться всё равно есть откуда: из Play
                    if (updater.fromPlay || latest?.apkUrl == null) {
                        updateFromPlay()
                    } else {
                        dialog = latest
                        updater.prepare(latest)
                    }
                },
        ) {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 16.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.SystemUpdate, null, tint = colors.onPrimary, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.update_button), color = colors.onPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars))
        }
    }

    dialog?.let { latest -> ApkUpdateDialog(latest, onClose = { dialog = null }) }
}

/**
 * Окно обновления из APK: скачивание с прогрессом и «Отмена» → «Новая версия
 * скачана» с «Установить»/«Позже» (APK остаётся до следующего раза) или ошибка
 * с «Повторить».
 */
@Composable
private fun ApkUpdateDialog(latest: AppVersionInfo, onClose: () -> Unit) {
    val updater = LocalContext.current.app.updater
    val colors = LocalAppColors.current
    // проверку скачанного APK не показываем: при «Повторить» остаётся прежнее окно, а не мигает пустота
    val state by remember(updater) { updater.apkState.filter { it != ApkState.Checking } }.collectAsState(ApkState.Idle)
    var needsPermission by remember { mutableStateOf(false) }

    fun close() {
        updater.dismiss()
        onClose()
    }

    when (val s = state) {
        ApkState.Idle, ApkState.Checking -> Unit
        is ApkState.Downloading -> AppDialog(
            stringResource(R.string.update_downloading),
            onDismiss = {
                updater.cancel()
                onClose()
            },
            confirm = {
                DialogButton(stringResource(R.string.common_cancel)) {
                    updater.cancel()
                    onClose()
                }
            },
            // случайный тап мимо окна не должен обрывать скачивание; «назад» — как «Отмена»
            properties = DialogProperties(dismissOnClickOutside = false),
        ) {
            Column {
                val progress = s.progress
                if (progress != null) {
                    LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth(), color = colors.primary)
                    Spacer(Modifier.height(8.dp))
                    Text("${(progress * 100).roundToInt()}%", color = colors.textMuted, fontSize = 13.sp)
                } else {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = colors.primary)
                }
            }
        }
        is ApkState.Ready -> AppDialog(
            stringResource(R.string.update_readyTitle),
            onDismiss = ::close,
            confirm = {
                DialogButton(stringResource(R.string.update_install)) {
                    if (updater.install(s.file)) onClose() else needsPermission = true
                }
            },
            dismiss = { DialogButton(stringResource(R.string.update_later), onClick = ::close) },
        ) {
            Column {
                Text(stringResource(R.string.update_readyBody), color = colors.textMuted)
                if (needsPermission) ErrorLine(stringResource(R.string.update_allowInstall))
            }
        }
        is ApkState.Failed -> AppDialog(
            stringResource(R.string.update_failedTitle),
            onDismiss = ::close,
            confirm = { DialogButton(stringResource(R.string.common_retry)) { updater.prepare(latest) } },
            dismiss = { DialogButton(stringResource(R.string.common_close), onClick = ::close) },
        ) {
            Text(stringResource(s.message), color = colors.textMuted)
        }
    }
}

/** Обновление из Play: окно обновления Play внутри приложения, если Play его даёт, иначе — страница приложения в Play. */
@Composable
private fun rememberPlayUpdate(): () -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { }
    return remember(context) {
        {
            scope.launch {
                val update = context.app.updater.playUpdateInfo()
                val options = AppUpdateOptions.defaultOptions(AppUpdateType.IMMEDIATE)
                val resumable = update?.updateAvailability() == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS
                if (update != null && (resumable || update.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE && update.isUpdateTypeAllowed(options))) {
                    AppUpdateManagerFactory.create(context).startUpdateFlowForResult(update, launcher, options)
                } else {
                    context.openPlayPage()
                }
            }
        }
    }
}

private fun Context.openPlayPage() {
    val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$packageName"))
    runCatching { startActivity(market) }.onFailure {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$packageName")))
    }
}
