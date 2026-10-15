package com.oshinobu.app.ui.chat

import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.util.LruCache
import android.view.WindowManager
import android.widget.ImageView
import android.widget.Toast
import androidx.annotation.RequiresApi
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.aspectRatio
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
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
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
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.GZIPInputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Стикер в переписке — без пузыря; бо́льшая сторона — такая доля ширины экрана. */
private const val StickerScreenFraction = 0.45f

/**
 * Расшифрованные в память стикеры: картинки (по объёму) и анимации — чтобы
 * прокрутка ленты и панели не декодировала одно и то же заново.
 */
private object StickerMemory {
    private val bitmaps = object : LruCache<String, ImageBitmap>(32 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }
    private val animations = LruCache<String, LottieComposition>(48)

    /** Пропорции (ширина / высота) — переживают вытеснение картинки из памяти: рамка в ленте не прыгает. */
    private val aspects = ConcurrentHashMap<String, Float>()

    fun bitmap(file: File): ImageBitmap? = bitmaps.get(file.path)

    fun aspect(file: File): Float? = aspects[file.path]

    fun rememberAspect(file: File, width: Int, height: Int) {
        if (width > 0 && height > 0) aspects[file.path] = width.toFloat() / height
    }

    private val animatedWebp = ConcurrentHashMap<String, Boolean>()

    fun isAnimatedWebp(file: File): Boolean? = animatedWebp[file.path]

    /**
     * Анимированный ли WebP (видеостикер — сервер перекодирует в него WEBM):
     * заголовок VP8X с флагом анимации; заодно — пропорции холста.
     */
    fun probeWebp(file: File): Boolean {
        animatedWebp[file.path]?.let { return it }
        val h = ByteArray(30)
        val n = runCatching { file.inputStream().use { it.read(h) } }.getOrDefault(0)
        val animated = n >= 30 && String(h, 0, 4, Charsets.US_ASCII) == "RIFF" &&
            String(h, 8, 8, Charsets.US_ASCII) == "WEBPVP8X" && (h[20].toInt() and 0x02) != 0
        if (animated) {
            fun u24(at: Int) = (h[at].toInt() and 0xFF) or ((h[at + 1].toInt() and 0xFF) shl 8) or ((h[at + 2].toInt() and 0xFF) shl 16)
            rememberAspect(file, u24(24) + 1, u24(27) + 1)
        }
        animatedWebp[file.path] = animated
        return animated
    }

    fun animation(file: File): LottieComposition? = animations.get(file.path)

    fun loadBitmap(file: File): ImageBitmap? =
        BitmapFactory.decodeFile(file.path)?.asImageBitmap()?.also {
            bitmaps.put(file.path, it)
            rememberAspect(file, it.width, it.height)
        }

    /** TGS — Lottie JSON в gzip. */
    fun loadAnimation(file: File): LottieComposition? =
        LottieCompositionFactory.fromJsonInputStreamSync(GZIPInputStream(file.inputStream().buffered()), "sticker:${file.name}")
            .value?.also {
                animations.put(file.path, it)
                rememberAspect(file, it.bounds.width(), it.bounds.height())
            }
}

/** Файл стикера: картинка или (TGS) бесконечная анимация. [onAspect] — пропорции, когда стали известны. */
@Composable
fun StickerFileView(file: File, animated: Boolean, modifier: Modifier = Modifier, onAspect: ((Float) -> Unit)? = null) {
    if (animated) {
        var composition by remember(file.path) { mutableStateOf(StickerMemory.animation(file)) }
        LaunchedEffect(file.path) {
            if (composition == null) composition = withContext(Dispatchers.IO) { runCatching { StickerMemory.loadAnimation(file) }.getOrNull() }
            StickerMemory.aspect(file)?.let { onAspect?.invoke(it) }
        }
        val progress by animateLottieCompositionAsState(composition, iterations = LottieConstants.IterateForever)
        LottieAnimation(composition, { progress }, modifier)
    } else {
        // видеостикер (анимированный WebP) играет только с Android 9; раньше — первый кадр картинкой
        var animatedWebp by remember(file.path) { mutableStateOf(StickerMemory.isAnimatedWebp(file)) }
        LaunchedEffect(file.path) {
            if (animatedWebp == null) animatedWebp = withContext(Dispatchers.IO) { StickerMemory.probeWebp(file) }
        }
        when {
            animatedWebp == null -> Box(modifier)
            animatedWebp == true && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> {
                LaunchedEffect(file.path) { StickerMemory.aspect(file)?.let { onAspect?.invoke(it) } }
                AnimatedWebpView(file, modifier)
            }
            else -> StaticStickerView(file, modifier, onAspect)
        }
    }
}

@Composable
private fun StaticStickerView(file: File, modifier: Modifier, onAspect: ((Float) -> Unit)?) {
    var bitmap by remember(file.path) { mutableStateOf(StickerMemory.bitmap(file)) }
    LaunchedEffect(file.path) {
        if (bitmap == null) bitmap = withContext(Dispatchers.IO) { runCatching { StickerMemory.loadBitmap(file) }.getOrNull() }
        StickerMemory.aspect(file)?.let { onAspect?.invoke(it) }
    }
    val b = bitmap
    if (b != null) Image(b, null, modifier, contentScale = ContentScale.Fit) else Box(modifier)
}

/**
 * Анимированный WebP — AnimatedImageDrawable (кадры декодирует сам, по
 * ходу; бесконечный повтор задан в файле). Свой на каждый показ: один
 * drawable в двух местах сразу не анимируется.
 */
@RequiresApi(Build.VERSION_CODES.P)
@Composable
private fun AnimatedWebpView(file: File, modifier: Modifier) {
    var drawable by remember(file.path) { mutableStateOf<Drawable?>(null) }
    LaunchedEffect(file.path) {
        drawable = withContext(Dispatchers.IO) { runCatching { ImageDecoder.decodeDrawable(ImageDecoder.createSource(file)) }.getOrNull() }
    }
    val d = drawable
    if (d == null) {
        Box(modifier)
        return
    }
    DisposableEffect(d) {
        (d as? AnimatedImageDrawable)?.start()
        onDispose { (d as? AnimatedImageDrawable)?.stop() }
    }
    AndroidView(
        factory = { context -> ImageView(context).apply { scaleType = ImageView.ScaleType.FIT_CENTER } },
        update = { view -> if (view.drawable !== d) view.setImageDrawable(d) },
        modifier = modifier,
    )
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
 * Размер: бо́льшая сторона — 45% ширины экрана, рамка — по пропорциям
 * картинки (пока они неизвестны — квадрат).
 */
@Composable
fun StickerById(stickerId: String, modifier: Modifier = Modifier) {
    val colors = LocalAppColors.current
    val stickers = LocalContext.current.app.core.stickers
    val version = rememberStickerFilesVersion()
    var state by remember(stickerId) {
        mutableStateOf<StickerFile?>(stickers.cachedFile(stickerId)?.let { StickerFile.Ready(it, it.extension == "tgs") })
    }
    var aspect by remember(stickerId) { mutableStateOf((state as? StickerFile.Ready)?.file?.let(StickerMemory::aspect)) }
    val side = LocalConfiguration.current.screenWidthDp.dp * StickerScreenFraction
    val a = aspect
    val width = if (a != null && a < 1f) side * a else side
    val height = if (a != null && a > 1f) side / a else side
    LaunchedEffect(stickerId, version) {
        var attempt = 0
        while (true) {
            val result = stickers.resolve(stickerId)
            state = result
            if (result !is StickerFile.Unavailable) break
            delay(RetryDelaysMs[minOf(attempt++, RetryDelaysMs.lastIndex)])
        }
    }
    Box(modifier.size(width, height), contentAlignment = Alignment.Center) {
        when (val s = state) {
            is StickerFile.Ready -> StickerFileView(s.file, s.animated, Modifier.fillMaxSize(), onAspect = { aspect = it })
            StickerFile.PackDeleted -> Text(
                stringResource(R.string.sticker_packDeleted),
                color = colors.textMuted, fontSize = 12.sp, fontStyle = FontStyle.Italic, textAlign = TextAlign.Center,
                modifier = Modifier.background(colors.surface, BubbleShape).padding(horizontal = 12.dp, vertical = 10.dp),
            )
            else -> Icon(
                Icons.Outlined.Image, null, tint = colors.textMuted.copy(alpha = 0.5f),
                modifier = Modifier.fillMaxSize().background(colors.surface.copy(alpha = 0.6f), RoundedCornerShape(20.dp)).padding(minOf(width, height) / 3),
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
        // не скачалось (нет сети, сбой сервера) — пробуем ещё, реже и реже
        var attempt = 0
        while (file?.exists() != true) {
            file = stickers.file(sticker)
            if (file != null) break
            delay(RetryDelaysMs[minOf(attempt++, RetryDelaysMs.lastIndex)])
        }
    }
    val f = file
    if (f != null) StickerFileView(f, sticker.animated, modifier) else Box(modifier)
}

private enum class Touch { TAP, CANCEL }

/**
 * Тап — [onTap]; долгое нажатие — увеличенное превью, пока палец держится:
 * [onPreviewAt] получает, где палец (координаты этой ячейки), при каждом
 * сдвиге — так превью переключается на стикер под пальцем; отпустили — null,
 * превью пропадает, ничего не отправляется. Сдвиг пальца до долгого
 * нажатия — прокрутка сетки, не тап.
 */
private fun Modifier.stickerTouch(key: Any, onTap: () -> Unit, onPreviewAt: (Offset?) -> Unit): Modifier = pointerInput(key) {
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
                onPreviewAt(down.position)
                try {
                    while (true) {
                        val ev = awaitPointerEvent()
                        ev.changes.forEach { it.consume() } // сетка под превью не прокручивается
                        val ch = ev.changes.firstOrNull { it.id == down.id } ?: break
                        if (!ch.pressed) break
                        onPreviewAt(ch.position)
                    }
                } finally {
                    onPreviewAt(null)
                }
            }
        }
    }
}

/**
 * Увеличенный стикер поверх чата на время долгого нажатия: появляется
 * "пружиной" из маленького, при переключении на другой стикер — сменяется
 * с коротким "хлопком". [ownWindow] — из шита стикерпака: шит — своё окно и
 * обрезает всё по своим краям, поэтому превью — в отдельном окне на весь
 * экран (по центру экрана, а не шита); касаний оно не принимает — протяжку
 * по сетке ведёт шит.
 */
@Composable
fun StickerPreviewOverlay(sticker: StickerInfo?, ownWindow: Boolean = false) {
    var shown by remember { mutableStateOf<StickerInfo?>(null) }
    if (sticker != null) shown = sticker
    // старт — "невидимо": иначе первое появление не анимируется
    val visibility = remember { MutableTransitionState(false) }
    visibility.targetState = sticker != null
    val dim by animateFloatAsState(if (sticker != null) 0.45f else 0f, tween(180), label = "previewDim")
    if (!visibility.currentState && !visibility.targetState && dim == 0f) return
    if (ownWindow) {
        // затемнение — здесь, на всём шите (вместе с кнопками внизу): окно превью у части
        // телефонов не заходит в нижнюю часть экрана; в окне — только сам стикер
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = dim)))
        Popup(popupPositionProvider = CenteredInWindow, properties = PreviewWindowProperties) {
            StickerPreviewContent(shown, visibility, dim = 0f)
        }
    } else {
        StickerPreviewContent(shown, visibility, dim)
    }
}

/** Окно превью: по центру окна-хозяина (у шита — весь экран). */
private object CenteredInWindow : PopupPositionProvider {
    override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection, popupContentSize: IntSize) =
        IntOffset((windowSize.width - popupContentSize.width) / 2, (windowSize.height - popupContentSize.height) / 2)
}

/** Без фокуса и касаний (палец остаётся у сетки шита), без обрезки по экрану. */
private val PreviewWindowProperties = PopupProperties(
    flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
    dismissOnBackPress = false,
    dismissOnClickOutside = false,
    usePlatformDefaultWidth = false,
)

@Composable
private fun StickerPreviewContent(shown: StickerInfo?, visibility: MutableTransitionState<Boolean>, dim: Float) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = dim)), contentAlignment = Alignment.Center) {
        AnimatedVisibility(
            visibleState = visibility,
            enter = scaleIn(spring(dampingRatio = 0.55f, stiffness = 420f), initialScale = 0.35f) + fadeIn(tween(120)),
            exit = scaleOut(tween(150), targetScale = 0.6f) + fadeOut(tween(150)),
        ) {
            AnimatedContent(
                targetState = shown,
                contentKey = { it?.id },
                transitionSpec = {
                    (scaleIn(spring(dampingRatio = 0.6f, stiffness = 600f), initialScale = 0.8f) + fadeIn(tween(110))) togetherWith
                        fadeOut(tween(80))
                },
                label = "previewSticker",
            ) { s -> s?.let { PanelSticker(it, Modifier.size(240.dp)) } }
        }
    }
}

/**
 * Сетка стикеров: тап — [onSend], долгое нажатие — превью; не отрывая
 * пальца, можно вести им по сетке — превью переключается на стикер под
 * пальцем (с лёгкой вибрацией на каждое переключение).
 */
@Composable
fun StickerGrid(
    items: List<StickerInfo>,
    onSend: ((StickerInfo) -> Unit)?,
    onPreview: (StickerInfo?) -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(8.dp),
) {
    val send by rememberUpdatedState(onSend)
    val haptics = LocalHapticFeedback.current
    val gridState = rememberLazyGridState()
    val gridCoords = remember { arrayOfNulls<LayoutCoordinates>(1) }
    // границы ячеек в координатах сетки — чтобы понять, над каким стикером палец
    val cellBounds = remember { HashMap<String, Rect>() }
    var previewed by remember { mutableStateOf<StickerInfo?>(null) }

    fun showPreview(next: StickerInfo?) {
        if (next?.id == previewed?.id) return
        if (next != null) {
            haptics.performHapticFeedback(if (previewed == null) HapticFeedbackType.LongPress else HapticFeedbackType.SegmentTick)
        }
        previewed = next
        onPreview(next)
    }

    fun stickerAt(point: Offset): StickerInfo? {
        val visible = gridState.layoutInfo.visibleItemsInfo.map { it.key }.toSet()
        val id = cellBounds.entries.firstOrNull { it.key in visible && it.value.contains(point) }?.key ?: return null
        return items.firstOrNull { it.id == id }
    }

    LazyVerticalGrid(
        GridCells.Fixed(5),
        modifier.onGloballyPositioned { gridCoords[0] = it },
        state = gridState,
        contentPadding = contentPadding,
    ) {
        items(items, key = { it.id }) { sticker ->
            val cell = remember { arrayOfNulls<LayoutCoordinates>(1) }
            PanelSticker(
                sticker,
                Modifier.aspectRatio(1f).padding(4.dp)
                    .onGloballyPositioned { c ->
                        cell[0] = c
                        gridCoords[0]?.let { g -> cellBounds[sticker.id] = g.localBoundingBoxOf(c) }
                    }
                    .stickerTouch(
                        sticker.id,
                        onTap = { send?.invoke(sticker) },
                        onPreviewAt = { local ->
                            if (local == null) {
                                showPreview(null)
                            } else {
                                val g = gridCoords[0]
                                val c = cell[0]
                                val point = if (g != null && c != null) g.localPositionOf(c, local) else null
                                // между ячейками (в отступах) — остаётся текущий
                                showPreview(point?.let(::stickerAt) ?: previewed ?: sticker)
                            }
                        },
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
 * Открытая вкладка — [stickersPage] (её помнит состояние клавиатуры), смена — [onPage].
 */
@Composable
fun EmojiPanel(
    height: Dp,
    onEmoji: (String) -> Unit,
    stickers: (@Composable (bottomPadding: Dp) -> Unit)? = null,
    stickersPage: Boolean = false,
    onPage: (stickers: Boolean) -> Unit = {},
) {
    val colors = LocalAppColors.current
    Box(Modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp)).background(colors.surface)) {
        if (stickers == null) {
            EmojiPicker(onEmoji)
            return@Box
        }
        // вкладка живёт в состоянии клавиатуры: панель открывается на последней
        val page = if (stickersPage) 1 else 0
        var stickersOpened by remember { mutableStateOf(stickersPage) }
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
                onPage(it == 1)
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
