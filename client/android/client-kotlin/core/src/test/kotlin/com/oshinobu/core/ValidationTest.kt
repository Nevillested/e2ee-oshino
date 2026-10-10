package com.oshinobu.core

import com.oshinobu.core.auth.totpSecret
import com.oshinobu.core.auth.validateLogin
import com.oshinobu.core.auth.validatePassword
import kotlin.test.Test
import kotlin.test.assertEquals

class ValidationTest {
    @Test
    fun `логин — латиница и цифры 3-32`() {
        assertEquals(null, validateLogin("alice42"))
        assertEquals("login.invalid", validateLogin("al"))
        assertEquals("login.invalid", validateLogin("аlice")) // кириллическая «а»
        assertEquals("login.invalid", validateLogin("a".repeat(33)))
    }

    @Test
    fun `пароль — по шагам, как во Flutter`() {
        assertEquals("password.tooShort", validatePassword("Ab1!"))
        assertEquals("password.needUpper", validatePassword("abcdef1!"))
        assertEquals("password.needLower", validatePassword("ABCDEF1!"))
        assertEquals("password.needDigit", validatePassword("Abcdefg!"))
        assertEquals("password.needSpecial", validatePassword("Abcdef12"))
        assertEquals(null, validatePassword("Abcdef1!"))
    }

    @Test
    fun `секрет из otpauth`() {
        assertEquals("JBSWY3DPEHPK3PXP", totpSecret("otpauth://totp/Oshinobu:alice?secret=JBSWY3DPEHPK3PXP&issuer=Oshinobu"))
    }
}
