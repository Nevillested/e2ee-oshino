package com.oshinobu.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.protocol.MessageType
import com.oshinobu.core.service.DownloadRow
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.launch

/** Строка панели передач. */
private data class TransferRow(
    val key: String,
    val label: String,
    val peer: String,
    val percent: Double,
    val showPercent: Boolean,
    val onCancel: suspend () -> Unit,
)

/**
 * Панель передач (окно поверх экрана): вкладка "Отправка" — тексты и файлы
 * в очереди, "Загрузка" — ручная и автоматическая очереди скачивания.
 * Любую строку можно отменить.
 */
@OptIn(FlowPreview::class)
@Composable
fun TransfersPanel() {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val config = LocalConfiguration.current
    val scope = rememberCoroutineScope()
    var tab by remember { mutableIntStateOf(0) }
    var textRows by remember { mutableStateOf(emptyList<TransferRow>()) }
    var fileRows by remember { mutableStateOf(emptyList<TransferRow>()) }
    var manualRows by remember { mutableStateOf(emptyList<TransferRow>()) }
    var autoRows by remember { mutableStateOf(emptyList<TransferRow>()) }
    val textLabel = stringResource(R.string.transfers_textMessage)
    val voiceLabel = stringResource(R.string.media_voiceNote)
    val videoNoteLabel = stringResource(R.string.media_videoNote)

    LaunchedEffect(Unit) {
        merge(
            core.downloads.snapshot.map { }, core.downloads.progress.map { },
            core.pendingSender.jobsChanged.map { }, core.pendingSender.progress.map { }, core.chats.changes,
        ).onStart { emit(Unit) }.debounce(120).collect {
            textRows = core.chats.getSendingTextMessages().map { t ->
                TransferRow("t:${t.messageId}", textLabel, t.peerLogin, 0.0, false) { core.cleanup.cancelOutgoing(t.peerLogin, listOf(t.messageId)) }
            }
            fileRows = core.pendingSender.rows().map { r ->
                val label = r.fileName ?: if (r.kind == MessageType.VIDEO_NOTE) videoNoteLabel else voiceLabel
                TransferRow("f:${r.rowKey}", label, r.peerLogin, r.percent, r.active) {
                    if (r.rowKey != r.jobId) core.pendingSender.cancelGroupItem(r.jobId, r.rowKey) else core.pendingSender.cancelJob(r.jobId)
                }
            }
            val snapshot = core.downloads.snapshot.value
            fun dl(prefix: String) = { r: DownloadRow ->
                TransferRow("$prefix:${r.mediaId}", r.label, r.peerLogin, r.percent, r.active) { core.downloads.cancelUserDownload(r.mediaId) }
            }
            manualRows = snapshot.manual.map(dl("m"))
            autoRows = snapshot.auto.map(dl("a"))
        }
    }

    Column(
        Modifier.width((config.screenWidthDp * 5 / 6).dp).height((config.screenHeightDp * 5 / 6).dp)
            .clip(RoundedCornerShape(16.dp)).background(colors.surface),
    ) {
        TabSplit(tab, onTab = { tab = it })
        HorizontalDivider(color = colors.textMuted.copy(alpha = 0.18f))
        Row(Modifier.fillMaxSize()) {
            val upload = tab == 0
            val cancel: (TransferRow) -> Unit = { scope.launch { it.onCancel() } }
            TransferColumn(
                stringResource(if (upload) R.string.transfers_textQueue else R.string.transfers_manualQueue),
                if (upload) textRows else manualRows, Modifier.weight(1f), cancel,
            )
            VerticalDivider(color = colors.textMuted.copy(alpha = 0.18f))
            TransferColumn(
                stringResource(if (upload) R.string.transfers_fileQueue else R.string.transfers_autoQueue),
                if (upload) fileRows else autoRows, Modifier.weight(1f), cancel,
            )
        }
    }
}

/** Две вкладки, разделённые наклонной чертой; активная подсвечена. */
@Composable
private fun TabSplit(active: Int, onTab: (Int) -> Unit) {
    val colors = LocalAppColors.current
    Box(Modifier.fillMaxWidth().height(46.dp)) {
        Canvas(Modifier.fillMaxSize()) {
            val mid = size.width / 2
            val slant = 16.dp.toPx()
            val top = mid + slant
            val bottom = mid - slant
            val path = Path().apply {
                if (active == 0) {
                    moveTo(0f, 0f); lineTo(top, 0f); lineTo(bottom, size.height); lineTo(0f, size.height)
                } else {
                    moveTo(top, 0f); lineTo(size.width, 0f); lineTo(size.width, size.height); lineTo(bottom, size.height)
                }
                close()
            }
            drawPath(path, colors.primary.copy(alpha = 0.13f))
            drawLine(colors.primary.copy(alpha = 0.55f), Offset(top, 0f), Offset(bottom, size.height), strokeWidth = 2.dp.toPx())
        }
        Row(Modifier.fillMaxSize()) {
            listOf(R.string.transfers_upload, R.string.transfers_download).forEachIndexed { i, label ->
                Box(Modifier.weight(1f).fillMaxHeight().clickable { onTab(i) }, contentAlignment = Alignment.Center) {
                    Text(
                        stringResource(label), fontSize = 13.5.sp,
                        fontWeight = if (active == i) FontWeight.Bold else FontWeight.Normal,
                        color = if (active == i) colors.primary else colors.textMuted.copy(alpha = 0.5f),
                    )
                }
            }
        }
    }
}

@Composable
private fun TransferColumn(title: String, rows: List<TransferRow>, modifier: Modifier, onCancel: (TransferRow) -> Unit) {
    val colors = LocalAppColors.current
    Column(modifier) {
        Text(
            title.uppercase(), fontSize = 10.5.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.4.sp, color = colors.textMuted,
            modifier = Modifier.padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 6.dp),
        )
        LazyColumn(Modifier.fillMaxSize()) {
            items(rows, key = { it.key }) { r ->
                Row(Modifier.animateItem().fillMaxWidth().padding(start = 12.dp, end = 2.dp, top = 5.dp, bottom = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(r.label, fontSize = 12.5.sp, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(r.peer, fontSize = 10.5.sp, color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    if (r.showPercent) Text("${r.percent.toInt()}%", fontSize = 11.sp, color = colors.primary, modifier = Modifier.padding(start = 4.dp))
                    Icon(Icons.Filled.Close, null, tint = colors.textMuted, modifier = Modifier.clickable { onCancel(r) }.padding(4.dp).size(16.dp))
                }
            }
        }
    }
}
