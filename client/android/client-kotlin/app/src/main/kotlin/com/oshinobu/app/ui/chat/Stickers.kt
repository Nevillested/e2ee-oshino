package com.oshinobu.app.ui.chat

import android.graphics.BitmapFactory
import android.widget.Toast
import android.util.LruCache
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.airbnb.lottie.LottieComposition
import com.airbnb.lottie.LottieCompositionFactory
import com.airbnb.lottie.compose.LottieAnimation
import com.airbnb.lottie.compose.LottieConstants
import com.airbnb.lottie.compose.animateLottieCompositionAsState
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.ErrorRed
import com.oshinobu.app.ui.emoji.EmojiPicker
import com.oshinobu.app.ui.home.AppDialog
import com.oshinobu.app.ui.home.DialogButton
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.net.StickerInfo
import com.oshinobu.core.net.StickerPackInfo
import com.oshinobu.core.service.StickerFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.zip.GZIPInputStream

/** Стикер в переписке — без пузыря, такого размера. */
val StickerMessageSize = 160.dp

/**
 * Расшифрованные в память стикеры: картинки (по объёму) и анимации — чтобы
 * прокрутка ленты и панели не декодировала одно и то же заново.
 */
private object StickerMemory {
    private val bitmaps = object : LruCache<String, ImageBitmap>(32 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }
    private val animations = LruCache<String, LottieComposition>(48)

    fun bitmap(file: File): ImageBitmap? = bitmaps.get(file.path)

    fun animation(file: File): LottieComposition? = animations.get(file.path)

    fun loadBitmap(file: File): ImageBitmap? =
        BitmapFactory.decodeFile(file.path)?.asImageBitmap()?.also { bitmaps.put(file.path, it) }

    /** TGS — Lottie JSON в gzip. */
    fun loadAnimation(file: File): LottieComposition? =
        LottieCompositionFactory.fromJsonInputStreamSync(GZIPInputStream(file.inputStream().buffered()), "sticker:${file.name}")
            .value?.also { animations.put(file.path, it) }
}

/** Файл стикера: картинка или (TGS) бесконечная анимация. */
@Composable
fun StickerFileView(file: File, animated: Boolean, modifier: Modifier = Modifier) {
    if (animated) {
        var composition by remember(file.path) { mutableStateOf(StickerMemory.animation(file)) }
        LaunchedEffect(file.path) {
            if (composition == null) composition = withContext(Dispatchers.IO) { runCatching { StickerMemory.loadAnimation(file) }.getOrNull() }
        }
        val progress by animateLottieCompositionAsState(composition, iterations = LottieConstants.IterateForever)
        LottieAnimation(composition, { progress }, modifier)
    } else {
        var bitmap by remember(file.path) { mutableStateOf(StickerMemory.bitmap(file)) }
        LaunchedEffect(file.path) {
            if (bitmap == null) bitmap = withContext(Dispatchers.IO) { runCatching { StickerMemory.loadBitmap(file) }.getOrNull() }
        }
        val b = bitmap
        if (b != null) Image(b, null, modifier, contentScale = ContentScale.Fit) else Box(modifier)
    }
}

/** Растёт, когда стикеры на устройстве появились или пропали (скачан пак, очищен кэш). */
@Composable
private fun rememberStickerFilesVersion(): Int {
    val stickers = LocalContext.current.app.core.stickers
    var version by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { stickers.changes.collect { version++ } }
    return version
}

private val RetryDelaysMs = longArrayOf(3_000, 10_000, 30_000, 60_000)

/**
 * Стикер из переписки по id: с устройства, иначе — скачав его пак
 * целиком. Пак удалён автором и файла нет — надпись вместо стикера.
 */
@Composable
fun StickerById(stickerId: String, modifier: Modifier = Modifier, size: Dp = StickerMessageSize) {
    val colors = LocalAppColors.current
    val stickers = LocalContext.current.app.core.stickers
    val version = rememberStickerFilesVersion()
    var state by remember(stickerId) {
        mutableStateOf<StickerFile?>(stickers.cachedFile(stickerId)?.let { StickerFile.Ready(it, it.extension == "tgs") })
    }
    LaunchedEffect(stickerId, version) {
        var attempt = 0
        while (true) {
            val result = stickers.resolve(stickerId)
            state = result
            if (result !is StickerFile.Unavailable) break
            delay(RetryDelaysMs[minOf(attempt++, RetryDelaysMs.lastIndex)])
        }
    }
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        when (val s = state) {
            is StickerFile.Ready -> StickerFileView(s.file, s.animated, Modifier.fillMaxSize())
            StickerFile.PackDeleted -> Text(
                stringResource(R.string.sticker_packDeleted),
                color = colors.textMuted, fontSize = 12.sp, fontStyle = FontStyle.Italic, textAlign = TextAlign.Center,
                modifier = Modifier.background(colors.surface, BubbleShape).padding(horizontal = 12.dp, vertical = 10.dp),
            )
            else -> Icon(
                Icons.Outlined.Image, null, tint = colors.textMuted.copy(alpha = 0.5f),
                modifier = Modifier.fillMaxSize().background(colors.surface.copy(alpha = 0.6f), RoundedCornerShape(20.dp)).padding(size / 3),
            )
        }
    }
}

/** Стикер из панели (известен формат и пак): с устройства или скачав пак. */
@Composable
fun PanelSticker(sticker: StickerInfo, modifier: Modifier = Modifier) {
    val stickers = LocalContext.current.app.core.stickers
    val version = rememberStickerFilesVersion()
    var file by remember(sticker.id) { mutableStateOf(stickers.cachedFile(sticker.id)) }
    LaunchedEffect(sticker.id, version) {
        if (file?.exists() != true) file = stickers.file(sticker)
    }
    val f = file
    if (f != null) StickerFileView(f, sticker.animated, modifier) else Box(modifier)
}

private enum class Touch { TAP, CANCEL }

/**
 * Тап — [onTap]; долгое нажатие — увеличенный стикер ([onPreview]), пока
 * палец держится; отпустили — превью пропадает, ничего не отправляется.
 * Сдвиг пальца до долгого нажатия — прокрутка сетки, не тап.
 */
private fun Modifier.stickerTouch(key: Any, onTap: () -> Unit, onPreview: (Boolean) -> Unit): Modifier = pointerInput(key) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val outcome = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
            var result = Touch.CANCEL
            while (true) {
                val ch = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                if (ch.isConsumed) break
                if (!ch.pressed) {
                    result = Touch.TAP
                    break
                }
                if ((ch.position - down.position).getDistance() > viewConfiguration.touchSlop) break
            }
            result
        }
        when (outcome) {
            Touch.TAP -> onTap()
            Touch.CANCEL -> Unit
            null -> {
                onPreview(true)
                try {
                    while (true) {
                        val ev = awaitPointerEvent()
                        ev.changes.forEach { it.consume() } // сетка под превью не прокручивается
                        if (ev.changes.none { it.pressed }) break
                    }
                } finally {
                    onPreview(false)
                }
            }
        }
    }
}

/** Увеличенный стикер поверх чата на время долгого нажатия. */
@Composable
fun StickerPreviewOverlay(sticker: StickerInfo?) {
    var shown by remember { mutableStateOf<StickerInfo?>(null) }
    if (sticker != null) shown = sticker
    AnimatedVisibility(sticker != null, enter = fadeIn(tween(160)), exit = fadeOut(tween(160))) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
            AnimatedVisibility(sticker != null, enter = scaleIn(tween(180), initialScale = 0.6f), exit = scaleOut(tween(140), targetScale = 0.8f)) {
                shown?.let { PanelSticker(it, Modifier.size(240.dp)) }
            }
        }
    }
}

/** Сетка стикеров: тап — [onSend], долгое нажатие — превью. */
@Composable
fun StickerGrid(
    items: List<StickerInfo>,
    onSend: ((StickerInfo) -> Unit)?,
    onPreview: (StickerInfo?) -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(8.dp),
) {
    val send by rememberUpdatedState(onSend)
    LazyVerticalGrid(GridCells.Fixed(5), modifier, contentPadding = contentPadding) {
        items(items, key = { it.id }) { sticker ->
            PanelSticker(
                sticker,
                Modifier.aspectRatio(1f).padding(4.dp).stickerTouch(
                    sticker.id,
                    onTap = { send?.invoke(sticker) },
                    onPreview = { on -> onPreview(if (on) sticker else null) },
                ),
            )
        }
    }
}

private const val RECENT = "recent"

/**
 * Панель стикеров: сверху — неподвижная строка-пузырь (прокручивается
 * вбок): "Недавние" (открыты по умолчанию), установленные паки (новые
 * первыми; долгое нажатие — убрать из панели) и "+" (загрузить свой пак);
 * под ней — сетка выбранного.
 */
@Composable
fun StickerPanel(
    bottomPadding: Dp,
    onSend: (StickerInfo) -> Unit,
    onPreview: (StickerInfo?) -> Unit,
    onAddPack: () -> Unit,
) {
    val colors = LocalAppColors.current
    val context = LocalContext.current
    val stickers = context.app.core.stickers
    val installed by stickers.installed.collectAsState()
    val recent by stickers.recent.collectAsState()
    var selected by remember { mutableStateOf(RECENT) }
    var removeAsk by remember { mutableStateOf<StickerPackInfo?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { stickers.sync() }
    // пак убрали (здесь или на другом устройстве) — назад к недавним
    if (selected != RECENT && installed.none { it.id == selected }) selected = RECENT

    Column(Modifier.fillMaxSize()) {
        Box(
            Modifier.padding(start = 8.dp, end = 8.dp, top = 8.dp).fillMaxWidth().height(52.dp)
                .clip(RoundedCornerShape(18.dp)).background(colors.background.copy(alpha = 0.7f)),
            contentAlignment = Alignment.CenterStart,
        ) {
            LazyRow(
                contentPadding = PaddingValues(horizontal = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                item(key = RECENT) {
                    PackTab(selected == RECENT, onClick = { selected = RECENT }) {
                        Icon(Icons.Outlined.Schedule, stringResource(R.string.sticker_recent), tint = if (selected == RECENT) colors.primary else colors.textMuted)
                    }
                }
                items(installed, key = { it.id }) { pack ->
                    PackTab(selected == pack.id, onClick = { selected = pack.id }, onLongClick = { removeAsk = pack }) {
                        pack.stickers.firstOrNull()?.let { PanelSticker(it, Modifier.fillMaxSize()) }
                    }
                }
                item(key = "add") {
                    PackTab(false, onClick = onAddPack) {
                        Icon(Icons.Filled.Add, stringResource(R.string.sticker_addPack), tint = colors.primary)
                    }
                }
            }
        }
        val items = if (selected == RECENT) recent else installed.firstOrNull { it.id == selected }?.stickers.orEmpty()
        val padding = PaddingValues(start = 8.dp, end = 8.dp, top = 6.dp, bottom = bottomPadding)
        if (selected == RECENT && items.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.sticker_recentEmpty), color = colors.textMuted, fontSize = 13.sp, textAlign = TextAlign.Center)
            }
        } else {
            key(selected) {
                StickerGrid(items, onSend, onPreview, Modifier.fillMaxSize(), padding)
            }
        }
    }

    removeAsk?.let { pack ->
        AppDialog(
            stringResource(R.string.sticker_removeFromPanelTitle),
            onDismiss = { removeAsk = null },
            confirm = {
                DialogButton(stringResource(R.string.sticker_remove), color = ErrorRed) {
                    removeAsk = null
                    scope.launch {
                        runCatching { stickers.uninstall(pack.id) }.onFailure {
                            Toast.makeText(context, context.getString(R.string.error_stickersFailed), Toast.LENGTH_SHORT).show()
                        }
                    }
                }
            },
            dismiss = { DialogButton(stringResource(R.string.common_cancel)) { removeAsk = null } },
        ) { Text(stringResource(R.string.sticker_removeFromPanelBody, pack.title), color = colors.textMuted) }
    }
}

/** Кнопка строки паков: выбранная — подсвеченная. */
@Composable
private fun PackTab(selected: Boolean, onClick: () -> Unit, onLongClick: (() -> Unit)? = null, content: @Composable () -> Unit) {
    val colors = LocalAppColors.current
    val background by animateColorAsState(if (selected) colors.primary.copy(alpha = 0.18f) else Color.Transparent, tween(200), label = "packTab")
    Box(
        Modifier.size(42.dp).clip(RoundedCornerShape(12.dp)).background(background)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick).padding(6.dp),
        contentAlignment = Alignment.Center,
    ) { content() }
}

/**
 * Панель на месте клавиатуры, той же высоты, со скруглёнными верхними
 * углами. С [stickers] внизу по центру — овал "Эмодзи | Стикеры":
 * стикеры въезжают справа, эмодзи уходят влево, и обратно.
 */
@Composable
fun EmojiPanel(height: Dp, onEmoji: (String) -> Unit, stickers: (@Composable (bottomPadding: Dp) -> Unit)? = null) {
    val colors = LocalAppColors.current
    Box(Modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp)).background(colors.surface)) {
        if (stickers == null) {
            EmojiPicker(onEmoji)
            return@Box
        }
        var page by remember { mutableIntStateOf(0) }
        var stickersOpened by remember { mutableStateOf(false) }
        val shift by animateFloatAsState(page.toFloat(), tween(280, easing = FastOutSlowInEasing), label = "panelShift")
        val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
        val reserve = navBottom + 56.dp
        if (shift < 1f) {
            Box(Modifier.fillMaxSize().graphicsLayer { translationX = -shift * size.width }) {
                EmojiPicker(onEmoji, contentPadding = PaddingValues(start = 8.dp, end = 8.dp, top = 8.dp, bottom = reserve))
            }
        }
        if (stickersOpened) {
            Box(Modifier.fillMaxSize().graphicsLayer { translationX = (1f - shift) * size.width }) { stickers(reserve) }
        }
        PanelSwitch(
            page,
            onSelect = {
                if (it == 1) stickersOpened = true
                page = it
            },
            Modifier.align(Alignment.BottomCenter).padding(bottom = navBottom + 8.dp),
        )
    }
}

/** Овал из двух подписей, как панель вкладок на главном экране. */
@Composable
private fun PanelSwitch(page: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val colors = LocalAppColors.current
    Row(
        modifier.clip(RoundedCornerShape(50)).background(colors.background.copy(alpha = 0.94f))
            .border(1.dp, colors.textMuted.copy(alpha = 0.18f), RoundedCornerShape(50)).padding(4.dp),
    ) {
        SwitchButton(page == 0, stringResource(R.string.sticker_tabEmoji)) { onSelect(0) }
        SwitchButton(page == 1, stringResource(R.string.sticker_tabStickers)) { onSelect(1) }
    }
}

@Composable
private fun SwitchButton(selected: Boolean, label: String, onClick: () -> Unit) {
    val colors = LocalAppColors.current
    val background by animateColorAsState(if (selected) colors.primary.copy(alpha = 0.16f) else Color.Transparent, tween(220), label = "switchBg")
    Text(
        label,
        color = if (selected) colors.primary else colors.textPrimary,
        fontSize = 13.sp,
        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(background).clickable(onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 7.dp),
    )
}
