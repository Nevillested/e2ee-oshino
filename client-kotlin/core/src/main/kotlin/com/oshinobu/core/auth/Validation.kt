package com.oshinobu.core.auth

// Проверки ввода при регистрации и смене пароля — те же правила, что у
// сервера (auth.ValidateLogin / password_policy.go) и у Flutter-клиента.
// Возвращают ключ локализации ошибки или null.

private val LOGIN = Regex("^[A-Za-z0-9]{3,32}$")

/** Логин: только латиница и цифры, 3–32 символа (закрывает кириллические омоглифы). */
fun validateLogin(login: String): String? = if (LOGIN.matches(login)) null else "login.invalid"

/** Пароль: от 6 символов, заглавная, строчная, цифра и спецсимвол. */
fun validatePassword(password: String): String? = when {
    password.length < 6 -> "password.tooShort"
    password.none { it in 'A'..'Z' } -> "password.needUpper"
    password.none { it in 'a'..'z' } -> "password.needLower"
    password.none { it in '0'..'9' } -> "password.needDigit"
    password.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' } -> "password.needSpecial"
    else -> null
}

/** Секрет TOTP из otpauth://-ссылки (для ручного ввода в приложение-аутентификатор). */
fun totpSecret(otpauthUrl: String): String =
    otpauthUrl.substringAfter('?', "").split('&').firstOrNull { it.startsWith("secret=") }?.removePrefix("secret=") ?: ""
