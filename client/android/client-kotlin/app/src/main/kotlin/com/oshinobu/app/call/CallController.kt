package com.oshinobu.app.call

import android.content.Context
import com.oshinobu.core.OshinobuCore
import com.oshinobu.core.service.CallState
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/**
 * Android-сторона звонка по состоянию [com.oshinobu.core.service.CallManager]:
 * рингтон входящего, гудки исходящего, звук разговора, уведомление "идёт
 * разговор", громкая связь при первом видео собеседника, флаги для
 * картинки-в-картинке; диагностика: состояние телефона в журнал на каждый
 * звонок, проблемы звонка — отчётом в feedback (kind=call_problem).
 */
class CallController(private val context: Context, private val core: OshinobuCore) {
    private companion object {
        /** За это время экран входящего обязан появиться, иначе — отчёт. */
        const val INCOMING_SCREEN_CHECK_MS = 8_000L
    }

    val audio = CallAudio(context)

    @Volatile
    private var incomingShownFor: String? = null
    private var incomingCheck: Job? = null

    /** Экран входящего звонка на экране (для проверки «экран не появился»). */
    fun markIncomingScreenShown() {
        incomingShownFor = core.calls.callId
    }

    /** Проблема звонка — отчёт в feedback с состоянием телефона. */
    fun reportProblem(what: String) = core.crashReporter.reportCallProblem("$what\n${CallDiagnostics.snapshot(context)}")

    private val _pipAllowed = MutableStateFlow(false)

    /** Идёт звонок и собеседник показывает видео — сворачивать в картинку-в-картинке. */
    val pipAllowed: StateFlow<Boolean> = _pipAllowed.asStateFlow()

    fun start() {
        val calls = core.calls
        core.scope.launch { calls.problems.collect(::reportProblem) }
        core.scope.launch {
            calls.state.collect { state ->
                if (state == CallState.INCOMING_RINGING) CallRingService.start(context, calls.callId, calls.peer.value?.deviceId)
                else CallRingService.stop(context)
                when (state) {
                    CallState.INCOMING_RINGING -> watchIncomingScreen()
                    CallState.OUTGOING_RINGING -> core.logger.log("Call outgoing: ${CallDiagnostics.snapshot(context)}")
                    else -> incomingCheck?.cancel()
                }

                when (state) {
                    CallState.IDLE, CallState.INCOMING_RINGING -> audio.stopRingback()
                    CallState.OUTGOING_RINGING -> {
                        audio.start()
                        audio.startRingback()
                    }
                    CallState.CONNECTED -> {
                        audio.stopRingback()
                        audio.start()
                    }
                }
                audio.setConnected(state == CallState.CONNECTED)

                if (state == CallState.CONNECTED) OngoingCallService.start(context, peerName())
                else OngoingCallService.stop(context)
                if (state == CallState.IDLE) audio.stop()
            }
        }
        core.scope.launch {
            // собеседник впервые включил камеру — на громкую связь (у уха видео не смотрят)
            calls.remoteVideoEnabled.collect { if (it) audio.ensureSpeaker() }
        }
        core.scope.launch {
            combine(calls.state, calls.remoteVideoEnabled) { s, video -> s == CallState.CONNECTED && video }
                .distinctUntilChanged().collect { _pipAllowed.value = it }
        }
    }

    /**
     * Входящий звонит: состояние телефона — в журнал; экран входящего не
     * появился за [INCOMING_SCREEN_CHECK_MS] — отчёт, с тем путём, которым он
     * должен был появиться (решается в момент звонка, пока состояние то же).
     */
    private fun watchIncomingScreen() {
        val callId = core.calls.callId
        val expected = CallDiagnostics.expectedIncomingPath(context)
        core.logger.log("Call incoming callId=$callId expected=$expected ${CallDiagnostics.snapshot(context)}")
        incomingCheck?.cancel()
        incomingCheck = core.scope.launch {
            delay(INCOMING_SCREEN_CHECK_MS)
            val calls = core.calls
            if (calls.state.value == CallState.INCOMING_RINGING && calls.callId == callId && incomingShownFor != callId) {
                reportProblem("incoming call screen not shown within ${INCOMING_SCREEN_CHECK_MS / 1000}s, expected path: $expected (callId=$callId)")
            }
        }
    }

    /** Имя собеседника для уведомления: отображаемое из профиля, иначе логин. */
    private suspend fun peerName(): String? {
        val peer = core.calls.peer.value ?: return null
        val login = peer.login ?: return null
        val accountId = peer.accountId ?: return login
        return core.peerProfiles.get(accountId, login)?.displayName ?: login
    }
}
