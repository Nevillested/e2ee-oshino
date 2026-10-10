package com.oshinobu.app.ui

import android.content.Context
import androidx.annotation.StringRes
import com.oshinobu.app.R
import com.oshinobu.core.net.ApiException
import kotlinx.coroutines.TimeoutCancellationException
import java.io.IOException

/**
 * Ключи ошибок ядра (те же, что ключи локализации Flutter-клиента) → строки.
 * Явная таблица, а не поиск ресурса по имени: опечатку ловит компилятор.
 */
@StringRes
fun errorStringRes(key: String): Int? = when (key) {
    "error.birthdaySaveFailed" -> R.string.error_birthdaySaveFailed
    "error.blockFailed" -> R.string.error_blockFailed
    "error.cancelledByUser" -> R.string.error_cancelledByUser
    "error.changePasswordFailed" -> R.string.error_changePasswordFailed
    "error.deviceRegisterFailed" -> R.string.error_deviceRegisterFailed
    "error.displayNameSaveFailed" -> R.string.error_displayNameSaveFailed
    "error.downloadFailed" -> R.string.error_downloadFailed
    "error.emailSaveFailed" -> R.string.error_emailSaveFailed
    "error.emailTaken" -> R.string.error_emailTaken
    "error.emailVerifyRequestFailed" -> R.string.error_emailVerifyRequestFailed
    "error.inviteCodeInvalid" -> R.string.error_inviteCodeInvalid
    "error.languageSaveFailed" -> R.string.error_languageSaveFailed
    "error.loginReserved" -> R.string.error_loginReserved
    "error.loginTaken" -> R.string.error_loginTaken
    "error.muteFailed" -> R.string.error_muteFailed
    "error.noAccountId" -> R.string.error_noAccountId
    "error.peerKeysFailed" -> R.string.error_peerKeysFailed
    "error.peerOutOfKeys" -> R.string.error_peerOutOfKeys
    "error.prekeysFailed" -> R.string.error_prekeysFailed
    "error.privacySaveFailed" -> R.string.error_privacySaveFailed
    "error.recoveryNoEmailOnFile" -> R.string.error_recoveryNoEmailOnFile
    "error.recoveryRequestFailed" -> R.string.error_recoveryRequestFailed
    "error.recoveryUserNotFound" -> R.string.error_recoveryUserNotFound
    "error.recoveryWrongCode" -> R.string.error_recoveryWrongCode
    "error.registerFailed" -> R.string.error_registerFailed
    "error.reportFailed" -> R.string.error_reportFailed
    "error.statusSaveFailed" -> R.string.error_statusSaveFailed
    "error.tooManyLoginAttempts" -> R.string.error_tooManyLoginAttempts
    "error.uploadFailed" -> R.string.error_uploadFailed
    "error.userLookupFailed" -> R.string.error_userLookupFailed
    "error.userNotFound" -> R.string.error_userNotFound
    "error.wrongCredentials" -> R.string.error_wrongCredentials
    "error.wrongTotpCode" -> R.string.error_wrongTotpCode
    "login.invalid" -> R.string.login_invalid
    "password.tooShort" -> R.string.password_tooShort
    "password.needUpper" -> R.string.password_needUpper
    "password.needLower" -> R.string.password_needLower
    "password.needDigit" -> R.string.password_needDigit
    "password.needSpecial" -> R.string.password_needSpecial
    else -> null
}

/** Текст ошибки для пользователя: ключ ядра → строка; сбой сети → "нет связи". */
fun Context.errorText(error: Throwable): String {
    val key = (error as? ApiException)?.errorKey
    val res = key?.let(::errorStringRes)
    return when {
        res != null -> {
            val status = (error as ApiException).httpStatus
            // как во Flutter: к общим "не удалось …" дописывается код ответа
            if (status != null && key in WITH_STATUS) "${getString(res)} ($status)" else getString(res)
        }
        error is IOException || error is TimeoutCancellationException -> getString(R.string.error_network)
        else -> error.message ?: getString(R.string.error_network)
    }
}

/** Текст ошибки по ключу валидации (validateLogin/validatePassword). */
fun Context.errorText(key: String): String = errorStringRes(key)?.let(::getString) ?: key

private val WITH_STATUS = setOf("error.registerFailed", "error.reportFailed")

/**
 * Подписи по ключам локализации, которые формирует ядро (превью в списке
 * чатов, присутствие, размеры, этапы загрузки) — тоже явной таблицей.
 */
fun Context.translate(key: String): String {
    val res = when (key) {
        "media.voiceNote" -> R.string.media_voiceNote
        "media.videoNote" -> R.string.media_videoNote
        "media.photo" -> R.string.media_photo
        "media.video" -> R.string.media_video
        "media.file" -> R.string.media_file
        "chat.undecryptablePreview" -> R.string.chat_undecryptablePreview
        "chat.queued" -> R.string.chat_queued
        "chat.encrypting" -> R.string.chat_encrypting
        "chat.uploading" -> R.string.chat_uploading
        "call.answered" -> R.string.call_answered
        "call.missed" -> R.string.call_missed
        "call.noAnswer" -> R.string.call_noAnswer
        "call.noConnection" -> R.string.call_noConnection
        "call.securingConnection" -> R.string.call_securingConnection
        "call.enablingMic" -> R.string.call_enablingMic
        "call.buildingOffer" -> R.string.call_buildingOffer
        "call.buildingAnswer" -> R.string.call_buildingAnswer
        "call.ringing" -> R.string.call_ringing
        "call.connecting" -> R.string.call_connecting
        "call.declined" -> R.string.call_declined
        "call.busy" -> R.string.call_busy
        "presence.typing" -> R.string.presence_typing
        "presence.online" -> R.string.presence_online
        "presence.justNow" -> R.string.presence_justNow
        "presence.minutesAgoSuffix" -> R.string.presence_minutesAgoSuffix
        "presence.yesterdayAt" -> R.string.presence_yesterdayAt
        "unit.bytes" -> R.string.unit_bytes
        "unit.kb" -> R.string.unit_kb
        "unit.mb" -> R.string.unit_mb
        "unit.gb" -> R.string.unit_gb
        else -> return key
    }
    return getString(res)
}
