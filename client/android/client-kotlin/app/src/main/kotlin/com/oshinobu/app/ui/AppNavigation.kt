package com.oshinobu.app.ui

import android.Manifest
import android.net.Uri
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.ExperimentalSharedTransitionApi
import androidx.compose.animation.SharedTransitionLayout
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.dialog
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.auth.LoginScreen
import com.oshinobu.app.ui.auth.RecoveryChooseScreen
import com.oshinobu.app.ui.auth.RecoveryCodeScreen
import com.oshinobu.app.ui.auth.RecoveryNoEmailScreen
import com.oshinobu.app.ui.auth.RecoveryPurpose
import com.oshinobu.app.ui.auth.RecoveryRequestScreen
import com.oshinobu.app.ui.auth.RegisterScreen
import com.oshinobu.app.ui.auth.ResetTotpScreen
import com.oshinobu.app.ui.auth.SetNewPasswordScreen
import com.oshinobu.app.ui.auth.VerifyTotpScreen
import com.oshinobu.app.ui.auth.WelcomeScreen
import com.oshinobu.app.ui.call.CallScreen
import com.oshinobu.app.ui.call.IncomingCallScreen
import com.oshinobu.app.ui.chat.ChatScreen
import com.oshinobu.app.ui.chat.ForwardScreen
import com.oshinobu.app.ui.chat.MediaViewerScreen
import com.oshinobu.app.ui.chat.PeerProfileScreen
import com.oshinobu.app.ui.home.ChatTarget
import com.oshinobu.app.ui.home.HomeScreen
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.OshinobuCore
import com.oshinobu.core.service.CallPeer
import com.oshinobu.core.service.CallState
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Маршруты приложения. Аргументы — в пути, строки кодируются [Uri.encode]. */
object Routes {
    const val SPLASH = "splash"
    const val WELCOME = "welcome"
    const val LOGIN = "login"
    const val REGISTER = "register"
    const val VERIFY_TOTP = "verify-totp/{login}/{url}"
    const val RECOVERY_CHOOSE = "recovery/{purpose}"
    const val RECOVERY_REQUEST = "recovery/{purpose}/request"
    const val RECOVERY_NO_EMAIL = "recovery/{purpose}/no-email"
    const val RECOVERY_CODE = "recovery/{purpose}/code/{login}"
    const val RECOVERY_RESET = "recovery/{purpose}/reset/{login}/{code}"
    const val HOME = "home"
    const val CHAT = "chat/{login}?accountId={accountId}&deviceId={deviceId}&forward={forward}"
    const val TRANSFERS = "transfers"
    const val FORWARD = "forward"
    const val MEDIA = "media/{login}/{messageId}"
    const val PEER_PROFILE = "peer/{accountId}/{login}"
    const val CALL = "call"
    const val INCOMING_CALL = "incoming-call"

    /** Приложение открыли ради звонка — сразу его экран, без заставки и списка чатов. */
    const val CALL_LAUNCH = "call-launch"

    /** Экраны звонка: появляются сразу, без выезда, и свайпом назад не закрываются. */
    val CALL_ROUTES = setOf(CALL, INCOMING_CALL, CALL_LAUNCH)

    /** [forward] — открыть чат с пересылаемыми сообщениями (буфер пересылки — в [AppNavigation]). */
    fun chat(t: ChatTarget, forward: Boolean = false) =
        "chat/${Uri.encode(t.login)}?accountId=${Uri.encode(t.accountId)}&deviceId=${Uri.encode(t.deviceId)}&forward=$forward"
    fun media(login: String, messageId: String) = "media/${Uri.encode(login)}/${Uri.encode(messageId)}"
    fun peerProfile(accountId: String, login: String) = "peer/${Uri.encode(accountId)}/${Uri.encode(login)}"
    fun verifyTotp(login: String, url: String) = "verify-totp/${Uri.encode(login)}/${Uri.encode(url)}"
    fun recovery(p: RecoveryPurpose) = "recovery/${p.name}"
    fun recoveryRequest(p: RecoveryPurpose) = "recovery/${p.name}/request"
    fun recoveryNoEmail(p: RecoveryPurpose) = "recovery/${p.name}/no-email"
    fun recoveryCode(p: RecoveryPurpose, login: String) = "recovery/${p.name}/code/${Uri.encode(login)}"
    fun recoveryReset(p: RecoveryPurpose, login: String, code: String) = "recovery/${p.name}/reset/${Uri.encode(login)}/${Uri.encode(code)}"
}

private fun NavHostController.startOver(route: String) = navigate(route) { popUpTo(0) { inclusive = true } }

/** Вернуться к экрану входа, убрав из стека всё, что было после приветствия. */
private fun NavHostController.backToLogin() = navigate(Routes.LOGIN) { popUpTo(Routes.WELCOME) }

/**
 * [launchedForCall] — приложение открыто ради звонка (входящий поверх
 * блокировки, "ответить" в уведомлении, "идёт разговор"): стартуем сразу с
 * экрана звонка ([Routes.CALL_LAUNCH]); [autoAccept] — звонок уже принят
 * кнопкой в уведомлении, экран входящего не нужен.
 */
@OptIn(ExperimentalSharedTransitionApi::class)
@Composable
fun AppNavigation(callScreenRequests: SharedFlow<Unit>, launchedForCall: Boolean = false, autoAccept: Boolean = false) {
    val nav = rememberNavController()
    val core = LocalContext.current.app.core
    val scope = rememberCoroutineScope()
    fun current() = nav.currentBackStackEntry?.destination?.route
    // звонки: входящий — экран входящего; принятый из уведомления / раскрытый из окошка — экран звонка
    // (пока приложение поднимается ради звонка, на нужный экран ведёт сам CALL_LAUNCH)
    LaunchedEffect(Unit) {
        core.calls.incomingCalls.collect {
            if (current() != Routes.INCOMING_CALL && current() != Routes.CALL_LAUNCH) nav.navigate(Routes.INCOMING_CALL)
        }
    }
    LaunchedEffect(Unit) {
        merge(core.calls.openCallScreen, callScreenRequests).collect {
            if (core.calls.state.value != CallState.IDLE && current() != Routes.CALL && current() != Routes.CALL_LAUNCH) {
                nav.navigate(Routes.CALL) { popUpTo(Routes.INCOMING_CALL) { inclusive = true } }
            }
        }
    }

    /** Закрыть экран звонка; открыли приложение ради звонка — под ним ничего нет, дальше обычный запуск. */
    fun leaveCall(route: String) {
        if (nav.previousBackStackEntry == null) nav.startOver(Routes.SPLASH) else nav.popBackStack(route, inclusive = true)
    }
    val openCall = { if (current() != Routes.CALL) nav.navigate(Routes.CALL) }
    val withMic = rememberWithPermission(Manifest.permission.RECORD_AUDIO)
    // что пересылаем: живёт от выбора "Переслать" до открытия чата-получателя
    var forwardDraft by remember { mutableStateOf<List<String>>(emptyList()) }
    val str = listOf(navArgument("login") { type = NavType.StringType }, navArgument("url") { type = NavType.StringType })
    val dispatcher = checkNotNull(LocalOnBackPressedDispatcherOwner.current).onBackPressedDispatcher
    // со звонка свайпом не уходят — только кнопками экрана
    val swipeBack = remember(dispatcher, nav) {
        SwipeBackController(dispatcher) {
            nav.previousBackStackEntry != null && nav.currentBackStackEntry?.destination?.route !in Routes.CALL_ROUTES
        }
    }
    // слой общих элементов: аватар перелетает между шапкой чата и профилем
    SharedTransitionLayout {
    CompositionLocalProvider(LocalSwipeBack provides swipeBack, LocalSharedTransitionScope provides this) {
    // как во Flutter: новый экран выезжает справа поверх неподвижного,
    // при возврате уезжает вправо (за пальцем — при свайпе назад);
    // профиль собеседника — проявляется с увеличением (Material "shared axis
    // scaled", как HeroZoomPageRoute во Flutter); экраны звонка — сразу
    NavHost(
        nav,
        startDestination = if (launchedForCall) Routes.CALL_LAUNCH else Routes.SPLASH,
        modifier = Modifier.swipeBack(swipeBack),
        enterTransition = {
            when (targetState.destination.route) {
                in Routes.CALL_ROUTES -> EnterTransition.None
                Routes.PEER_PROFILE -> fadeIn(tween(PROFILE_OPEN_MS)) + scaleIn(tween(PROFILE_OPEN_MS), initialScale = 0.8f)
                else -> slideInHorizontally(tween(450, easing = EaseInOut)) { it }
            }
        },
        exitTransition = {
            if (targetState.destination.route == Routes.PEER_PROFILE) {
                fadeOut(tween(PROFILE_OPEN_MS)) + scaleOut(tween(PROFILE_OPEN_MS), targetScale = 1.1f)
            } else {
                ExitTransition.KeepUntilTransitionsFinished
            }
        },
        popEnterTransition = {
            if (initialState.destination.route == Routes.PEER_PROFILE) {
                fadeIn(tween(PROFILE_CLOSE_MS)) + scaleIn(tween(PROFILE_CLOSE_MS), initialScale = 1.1f)
            } else {
                EnterTransition.None
            }
        },
        popExitTransition = {
            when (initialState.destination.route) {
                in Routes.CALL_ROUTES -> ExitTransition.None
                Routes.PEER_PROFILE -> fadeOut(tween(PROFILE_CLOSE_MS)) + scaleOut(tween(PROFILE_CLOSE_MS), targetScale = 0.8f)
                else -> slideOutHorizontally(tween(340, easing = EaseInOut)) { it }
            }
        },
    ) {
        composable(Routes.CALL_LAUNCH) {
            CallLaunchScreen(
                autoAccept = autoAccept,
                onIncoming = { nav.navigate(Routes.INCOMING_CALL) { popUpTo(Routes.CALL_LAUNCH) { inclusive = true } } },
                onInCall = { nav.navigate(Routes.CALL) { popUpTo(Routes.CALL_LAUNCH) { inclusive = true } } },
                onNoCall = { nav.startOver(Routes.SPLASH) },
                onSignedOut = { nav.startOver(Routes.WELCOME) },
            )
        }
        composable(Routes.SPLASH) {
            SplashScreen(
                onSignedOut = { nav.startOver(Routes.WELCOME) },
                onSignedIn = { nav.startOver(Routes.HOME) },
            )
        }
        composable(Routes.WELCOME) {
            WelcomeScreen(onLogin = { nav.navigate(Routes.LOGIN) }, onRegister = { nav.navigate(Routes.REGISTER) })
        }
        composable(Routes.LOGIN) {
            LoginScreen(
                onBack = { nav.popBackStack() },
                onLoggedIn = { nav.startOver(Routes.HOME) },
                onRecover = { nav.navigate(Routes.recovery(it)) },
            )
        }
        composable(Routes.REGISTER) {
            RegisterScreen(onBack = { nav.popBackStack() }, onRegistered = { login, url -> nav.navigate(Routes.verifyTotp(login, url)) })
        }
        composable(Routes.VERIFY_TOTP, str) { e ->
            VerifyTotpScreen(
                login = e.arguments!!.getString("login")!!,
                totpUrl = e.arguments!!.getString("url")!!,
                onBack = { nav.popBackStack() },
                onVerified = { nav.backToLogin() },
            )
        }
        composable(Routes.RECOVERY_CHOOSE) { e ->
            val purpose = RecoveryPurpose.valueOf(e.arguments!!.getString("purpose")!!)
            RecoveryChooseScreen(
                purpose,
                onBack = { nav.popBackStack() },
                onHasEmail = { nav.navigate(Routes.recoveryRequest(purpose)) },
                onNoEmail = { nav.navigate(Routes.recoveryNoEmail(purpose)) },
            )
        }
        composable(Routes.RECOVERY_REQUEST) { e ->
            val purpose = RecoveryPurpose.valueOf(e.arguments!!.getString("purpose")!!)
            RecoveryRequestScreen(purpose, onBack = { nav.popBackStack() }, onCodeSent = { nav.navigate(Routes.recoveryCode(purpose, it)) })
        }
        composable(Routes.RECOVERY_NO_EMAIL) { e ->
            RecoveryNoEmailScreen(RecoveryPurpose.valueOf(e.arguments!!.getString("purpose")!!), onBack = { nav.popBackStack() })
        }
        composable(Routes.RECOVERY_CODE) { e ->
            val purpose = RecoveryPurpose.valueOf(e.arguments!!.getString("purpose")!!)
            val login = e.arguments!!.getString("login")!!
            RecoveryCodeScreen(login, onBack = { nav.popBackStack() }, onVerified = { nav.navigate(Routes.recoveryReset(purpose, login, it)) })
        }
        composable(Routes.RECOVERY_RESET) { e ->
            val purpose = RecoveryPurpose.valueOf(e.arguments!!.getString("purpose")!!)
            val login = e.arguments!!.getString("login")!!
            val code = e.arguments!!.getString("code")!!
            when (purpose) {
                RecoveryPurpose.PASSWORD -> SetNewPasswordScreen(login, code, onBack = { nav.popBackStack() }, onDone = { nav.backToLogin() })
                RecoveryPurpose.TOTP -> ResetTotpScreen(login, code, onBack = { nav.popBackStack() }, onVerified = { nav.backToLogin() })
            }
        }
        composable(Routes.HOME) {
            HomeScreen(
                onSignedOut = { nav.startOver(Routes.WELCOME) },
                onOpenChat = { nav.navigate(Routes.chat(it)) },
                onOpenTransfers = { nav.navigate(Routes.TRANSFERS) },
                onOpenCall = openCall,
            )
        }
        composable(
            Routes.CHAT,
            listOf(
                navArgument("login") { type = NavType.StringType },
                navArgument("accountId") { type = NavType.StringType; defaultValue = "" },
                navArgument("deviceId") { type = NavType.StringType; defaultValue = "" },
                navArgument("forward") { type = NavType.BoolType; defaultValue = false },
            ),
        ) { e ->
            val args = e.arguments!!
            val target = ChatTarget(args.getString("login")!!, args.getString("accountId")!!, args.getString("deviceId")!!)
            val forwarded = remember { if (args.getBoolean("forward")) forwardDraft.also { forwardDraft = emptyList() } else emptyList() }
            CompositionLocalProvider(LocalNavAnimatedScope provides this) {
            ChatScreen(
                target = target,
                forwardedTexts = forwarded,
                onBack = { nav.popBackStack() },
                onOpenTransfers = { nav.navigate(Routes.TRANSFERS) },
                onOpenProfile = { accountId, login -> nav.navigate(Routes.peerProfile(accountId, login)) },
                onForward = { texts ->
                    forwardDraft = texts
                    nav.navigate(Routes.FORWARD)
                },
                onOpenMedia = { login, messageId -> nav.navigate(Routes.media(login, messageId)) },
                onStartCall = { peer ->
                    if (peer.deviceId.isNotEmpty()) {
                        withMic {
                            scope.launch { core.calls.startCall(CallPeer(peer.deviceId, peer.login, peer.accountId)) }
                            nav.navigate(Routes.CALL)
                        }
                    }
                },
                onOpenCall = openCall,
            )
            }
        }
        composable(Routes.FORWARD) {
            ForwardScreen(
                onBack = {
                    forwardDraft = emptyList()
                    nav.popBackStack()
                },
                onPick = { target -> nav.navigate(Routes.chat(target, forward = true)) { popUpTo(Routes.FORWARD) { inclusive = true } } },
            )
        }
        composable(Routes.MEDIA) { e ->
            MediaViewerScreen(e.arguments!!.getString("login")!!, e.arguments!!.getString("messageId")!!, onBack = { nav.popBackStack() })
        }
        composable(Routes.PEER_PROFILE) { e ->
            CompositionLocalProvider(LocalNavAnimatedScope provides this) {
                PeerProfileScreen(e.arguments!!.getString("accountId")!!, e.arguments!!.getString("login")!!, onBack = { nav.popBackStack() })
            }
        }
        dialog(Routes.TRANSFERS) { TransfersPanel() }
        composable(Routes.CALL) { CallScreen(onClose = { leaveCall(Routes.CALL) }) }
        composable(Routes.INCOMING_CALL) {
            IncomingCallScreen(
                onAccepted = { nav.navigate(Routes.CALL) { popUpTo(Routes.INCOMING_CALL) { inclusive = true } } },
                onClose = { leaveCall(Routes.INCOMING_CALL) },
            )
        }
    }
    }
    }
}

/** Профиль собеседника: открытие и закрытие (как у HeroZoomPageRoute во Flutter-клиенте). */
private const val PROFILE_OPEN_MS = 350
private const val PROFILE_CLOSE_MS = 300

/**
 * Решение при запуске: нет сессии/устройства → приветствие; сервер говорит,
 * что сессия больше не действует (вошли с другого устройства) → чистим всё
 * и на приветствие; иначе (в т.ч. нет сети) → главный экран.
 */
@Composable
private fun SplashScreen(onSignedOut: () -> Unit, onSignedIn: () -> Unit) {
    val core = LocalContext.current.app.core
    LaunchedEffect(Unit) { if (resumeSession(core)) onSignedIn() else onSignedOut() }
    FullScreenLoading()
}

/** Поднять сохранённую сессию; false — входа нет (или сервер его больше не признаёт — всё стёрто). */
private suspend fun resumeSession(core: OshinobuCore): Boolean {
    val token = core.session.token
    if (token == null || core.keys.deviceId() == null) return false
    if (core.api.checkSession(token) == false) {
        core.signOutLocally()
        return false
    }
    core.startSession()
    return true
}

/**
 * Приложение открыто ради звонка: пока поднимается сессия и приходит сам
 * звонок (offer — по WebSocket после подключения), — экран "входящий
 * звонок", затем сразу нужный экран звонка. Звонка так и не дождались
 * (отменили, пока поднимались) — обычный запуск.
 */
@Composable
private fun CallLaunchScreen(autoAccept: Boolean, onIncoming: () -> Unit, onInCall: () -> Unit, onNoCall: () -> Unit, onSignedOut: () -> Unit) {
    val core = LocalContext.current.app.core
    val colors = LocalAppColors.current
    LaunchedEffect(Unit) {
        if (!resumeSession(core)) {
            onSignedOut()
            return@LaunchedEffect
        }
        when (withTimeoutOrNull(CALL_LAUNCH_WAIT_MS) { core.calls.state.first { it != CallState.IDLE } }) {
            null -> onNoCall()
            CallState.INCOMING_RINGING -> if (autoAccept) onInCall() else onIncoming()
            else -> onInCall()
        }
    }
    Column(
        Modifier.fillMaxSize().background(colors.background).systemBarsPadding(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(stringResource(R.string.call_incoming), color = colors.textMuted)
        Spacer(Modifier.height(16.dp))
        AppLoadingIndicator(size = 32.dp, color = colors.primary)
    }
}

/** Сколько ждать звонок, открыв приложение ради него (подключение + доставка offer). */
private const val CALL_LAUNCH_WAIT_MS = 20_000L
