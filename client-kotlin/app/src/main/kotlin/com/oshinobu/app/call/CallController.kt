package com.oshinobu.app.call

import android.content.Context
import com.oshinobu.core.OshinobuCore
import com.oshinobu.core.service.CallState
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
 * картинки-в-картинке.
 */
class CallController(private val context: Context, private val core: OshinobuCore) {
    val audio = CallAudio(context)

    private val _pipAllowed = MutableStateFlow(false)

    /** Идёт звонок и собеседник показывает видео — сворачивать в картинку-в-картинке. */
    val pipAllowed: StateFlow<Boolean> = _pipAllowed.asStateFlow()

    fun start() {
        val calls = core.calls
        core.scope.launch {
            calls.state.collect { state ->
                if (state == CallState.INCOMING_RINGING) CallRingService.start(context, calls.callId, calls.peer.value?.deviceId)
                else CallRingService.stop(context)

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

    /** Имя собеседника для уведомления: отображаемое из профиля, иначе логин. */
    private suspend fun peerName(): String? {
        val peer = core.calls.peer.value ?: return null
        val login = peer.login ?: return null
        val accountId = peer.accountId ?: return login
        return core.peerProfiles.get(accountId, login)?.displayName ?: login
    }
}
