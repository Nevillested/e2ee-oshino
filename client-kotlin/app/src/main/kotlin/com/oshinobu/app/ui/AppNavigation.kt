package com.oshinobu.app.ui

import android.Manifest
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.dialog
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
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
import com.oshinobu.core.service.CallPeer
import com.oshinobu.core.service.CallState
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch

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

@Composable
fun AppNavigation(callScreenRequests: SharedFlow<Unit>) {
    val nav = rememberNavController()
    val core = LocalContext.current.app.core
    val scope = rememberCoroutineScope()
    fun current() = nav.currentBackStackEntry?.destination?.route
    // звонки: входящий — экран входящего; принятый из уведомления / раскрытый из окошка — экран звонка
    LaunchedEffect(Unit) {
        core.calls.incomingCalls.collect { if (current() != Routes.INCOMING_CALL) nav.navigate(Routes.INCOMING_CALL) }
    }
    LaunchedEffect(Unit) {
        merge(core.calls.openCallScreen, callScreenRequests).collect {
            if (core.calls.state.value != CallState.IDLE && current() != Routes.CALL) {
                nav.navigate(Routes.CALL) { popUpTo(Routes.INCOMING_CALL) { inclusive = true } }
            }
        }
    }
    val openCall = { if (current() != Routes.CALL) nav.navigate(Routes.CALL) }
    val withMic = rememberWithPermission(Manifest.permission.RECORD_AUDIO)
    // что пересылаем: живёт от выбора "Переслать" до открытия чата-получателя
    var forwardDraft by remember { mutableStateOf<List<String>>(emptyList()) }
    val str = listOf(navArgument("login") { type = NavType.StringType }, navArgument("url") { type = NavType.StringType })
    NavHost(nav, startDestination = Routes.SPLASH) {
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
            PeerProfileScreen(e.arguments!!.getString("accountId")!!, e.arguments!!.getString("login")!!, onBack = { nav.popBackStack() })
        }
        dialog(Routes.TRANSFERS) { TransfersPanel() }
        composable(Routes.CALL) { CallScreen(onClose = { nav.popBackStack(Routes.CALL, inclusive = true) }) }
        composable(Routes.INCOMING_CALL) {
            IncomingCallScreen(
                onAccepted = { nav.navigate(Routes.CALL) { popUpTo(Routes.INCOMING_CALL) { inclusive = true } } },
                onClose = { nav.popBackStack(Routes.INCOMING_CALL, inclusive = true) },
            )
        }
    }
}

/**
 * Решение при запуске: нет сессии/устройства → приветствие; сервер говорит,
 * что сессия больше не действует (вошли с другого устройства) → чистим всё
 * и на приветствие; иначе (в т.ч. нет сети) → главный экран.
 */
@Composable
private fun SplashScreen(onSignedOut: () -> Unit, onSignedIn: () -> Unit) {
    val core = LocalContext.current.app.core
    LaunchedEffect(Unit) {
        val token = core.session.token
        if (token == null || core.keys.deviceId() == null) {
            onSignedOut()
            return@LaunchedEffect
        }
        if (core.api.checkSession(token) == false) {
            core.signOutLocally()
            onSignedOut()
            return@LaunchedEffect
        }
        core.startSession()
        onSignedIn()
    }
    FullScreenLoading()
}
