package com.oshinobu.app.call

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import com.oshinobu.app.R
import com.oshinobu.core.service.Logger
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Куда идёт звук разговора. */
enum class AudioRoute { EARPIECE, SPEAKER, WIRED_HEADSET, BLUETOOTH }

/**
 * Звук звонка: режим связи, выбор выхода, гудки
 * исходящего, датчик приближения у уха.
 *  - нет Bluetooth: громкая связь вкл/выкл; иначе — проводные наушники,
 *    если подключены, или динамик у уха;
 *  - есть Bluetooth: по умолчанию он, остальные выходы — выбором из списка;
 *  - датчик приближения гасит экран ТОЛЬКО в разговоре через динамик у уха (чтобы
 *    не нажать щекой); громкая связь, наушники, гудки, конец звонка — экран не
 *    трогает никогда;
 *  - гудки исходящего — явно в тот же выход, что и разговор.
 *
 * Вызывается с разных потоков (состояние звонка — из ядра, смена устройств — с
 * главного, кнопки — из интерфейса), поэтому всё под одной блокировкой: раньше
 * два потока могли одновременно взять блокировку экрана по датчику, а отпускалась
 * одна — экран продолжал гаснуть у лица и после звонка.
 */
class CallAudio(private val context: Context, private val log: Logger) {
    private val am = context.getSystemService(AudioManager::class.java)
    private val handler = Handler(Looper.getMainLooper())

    private val _routes = MutableStateFlow<List<AudioRoute>>(emptyList())
    private val _route = MutableStateFlow(AudioRoute.EARPIECE)

    /** Доступные выходы (список показывается, когда есть Bluetooth). */
    val routes: StateFlow<List<AudioRoute>> = _routes.asStateFlow()

    /** Текущий выход. */
    val route: StateFlow<AudioRoute> = _route.asStateFlow()

    private var active = false
    private var speakerOn = false
    private var picked: AudioRoute? = null
    private var connected = false
    private var ringback: MediaPlayer? = null
    private var proximity: PowerManager.WakeLock? = null

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = refresh()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = refresh()
    }

    val hasBluetooth: Boolean get() = AudioRoute.BLUETOOTH in _routes.value

    /** Начало звонка: режим связи, разговорный динамик. */
    @Synchronized
    fun start() {
        if (active) return
        active = true
        speakerOn = false
        picked = null
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        am.registerAudioDeviceCallback(deviceCallback, handler)
        refresh()
    }

    @Synchronized
    fun stop() {
        if (!active) return
        active = false
        connected = false
        stopRingback()
        am.unregisterAudioDeviceCallback(deviceCallback)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = false
            @Suppress("DEPRECATION")
            if (am.isBluetoothScoOn) am.stopBluetoothSco()
        }
        am.mode = AudioManager.MODE_NORMAL
        _routes.value = emptyList()
        _route.value = AudioRoute.EARPIECE
        updateProximity()
    }

    /** Звонок соединён/нет — от этого зависит гашение экрана у уха. */
    @Synchronized
    fun setConnected(value: Boolean) {
        connected = value
        updateProximity()
    }

    /** Кнопка "громкая связь" (без Bluetooth). */
    @Synchronized
    fun toggleSpeaker() {
        if (hasBluetooth) return
        speakerOn = !speakerOn
        apply()
    }

    /** Включить громкую связь, если она ещё не включена (первое видео собеседника). */
    @Synchronized
    fun ensureSpeaker() {
        if (hasBluetooth || speakerOn) return
        speakerOn = true
        apply()
    }

    /** Выбор из списка выходов (при Bluetooth). */
    @Synchronized
    fun select(route: AudioRoute) {
        picked = route
        speakerOn = route == AudioRoute.SPEAKER
        apply()
    }

    @Synchronized
    private fun refresh() {
        if (!active) return
        val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val routes = buildList {
            if (outs.any { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }) add(AudioRoute.EARPIECE)
            add(AudioRoute.SPEAKER)
            if (outs.any { it.type in WIRED_TYPES }) add(AudioRoute.WIRED_HEADSET)
            if (outs.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }) add(AudioRoute.BLUETOOTH)
        }
        _routes.value = routes
        apply()
    }

    private fun apply() {
        if (!active) return
        val target = if (!hasBluetooth) {
            picked = null
            when {
                speakerOn -> AudioRoute.SPEAKER
                AudioRoute.WIRED_HEADSET in _routes.value -> AudioRoute.WIRED_HEADSET
                else -> AudioRoute.EARPIECE
            }
        } else {
            (picked ?: AudioRoute.BLUETOOTH).takeIf { it in _routes.value } ?: AudioRoute.BLUETOOTH
        }
        if (target != _route.value) log.log("CallAudio route ${_route.value} -> $target")
        route(target)
        _route.value = target
        speakerOn = target == AudioRoute.SPEAKER
        ringback?.let { pointAt(it, target) }
        updateProximity()
    }

    /** Встроенный выход для [target] (у Bluetooth и наушников — первый подходящий). */
    private fun outputFor(target: AudioRoute): AudioDeviceInfo? =
        am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.type in typesOf(target) }

    /**
     * Гудки — в тот же выход, что и разговор. Плеер гудков — отдельный поток, и
     * выбор выхода для разговора (setCommunicationDevice) Android на него
     * распространяет не всегда: с громкой связью гудки шли громко в динамик у уха.
     */
    private fun pointAt(player: MediaPlayer, target: AudioRoute) {
        // до Android 9 выбора выхода у плеера нет — там гудки идут по isSpeakerphoneOn вместе с разговором
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return
        val device = outputFor(target)
        if (device == null || !player.setPreferredDevice(device)) log.log("CallAudio ringback: no preferred device for $target")
    }

    private fun route(target: AudioRoute) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val types = typesOf(target)
            val device = am.availableCommunicationDevices.firstOrNull { it.type in types }
            if (device == null || !am.setCommunicationDevice(device)) log.log("CallAudio setCommunicationDevice($target) failed, device=${device?.type}")
        } else {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = target == AudioRoute.SPEAKER
            @Suppress("DEPRECATION")
            if (target == AudioRoute.BLUETOOTH) {
                am.startBluetoothSco()
                am.isBluetoothScoOn = true
            } else if (am.isBluetoothScoOn) {
                am.isBluetoothScoOn = false
                am.stopBluetoothSco()
            }
        }
    }

    /**
     * Экран гаснет у уха — только в разговоре через динамик у уха. Всё остальное
     * (громкая связь, наушники, гудки, конец звонка) — блокировка снимается сразу,
     * не дожидаясь, пока датчик освободится: с флагом «ждать» экран оставался
     * погашенным, если датчик был чем-то закрыт (рука, чехол), и после звонка.
     */
    private fun updateProximity() {
        val shouldHold = active && connected && _route.value == AudioRoute.EARPIECE
        val pm = context.getSystemService(PowerManager::class.java)
        if (shouldHold && proximity == null && pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
            proximity = pm.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "oshinobu:call_proximity").apply {
                // не по счётчику: одна блокировка — одно «отпустить», лишний захват ничего не оставит висеть
                setReferenceCounted(false)
                acquire(4 * 60 * 60_000L)
            }
            log.log("CallAudio proximity on")
        } else if (!shouldHold && proximity != null) {
            // сразу, без «дождаться, пока датчик освободится» — вне разговора у уха экран
            // не должен гаснуть ни на миг
            proximity?.let { if (it.isHeld) it.release() }
            proximity = null
            log.log("CallAudio proximity off (route=${_route.value}, active=$active connected=$connected)")
        }
    }

    /** Гудки исходящего — в выбранный выход разговора. */
    @Synchronized
    fun startRingback() {
        if (ringback != null) return
        ringback = MediaPlayer().apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            val afd = context.resources.openRawResourceFd(R.raw.ringback)
            setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            afd.close()
            isLooping = true
            pointAt(this, _route.value)
            setOnPreparedListener { it.start() }
            prepareAsync()
        }
    }

    @Synchronized
    fun stopRingback() {
        ringback?.release()
        ringback = null
    }

    private companion object {
        val WIRED_TYPES = setOf(AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET)

        fun typesOf(target: AudioRoute): Set<Int> = when (target) {
            AudioRoute.EARPIECE -> setOf(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)
            AudioRoute.SPEAKER -> setOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
            AudioRoute.WIRED_HEADSET -> WIRED_TYPES
            AudioRoute.BLUETOOTH -> setOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET)
        }
    }
}
