package com.oshinobu.app.ui

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Отчётливый короткий "клик" вибромотором — на реакцию (свою и собеседника
 * в открытом чате). Системный эффект, а не самодельные 40 мс средней силы:
 * те почти не чувствовались.
 */
fun Context.reactionHaptic() {
    val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        getSystemService(VibratorManager::class.java).defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
    }
    if (!vibrator.hasVibrator()) return
    when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK))
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> vibrator.vibrate(VibrationEffect.createOneShot(30, 255))
        else -> @Suppress("DEPRECATION") vibrator.vibrate(30)
    }
}
