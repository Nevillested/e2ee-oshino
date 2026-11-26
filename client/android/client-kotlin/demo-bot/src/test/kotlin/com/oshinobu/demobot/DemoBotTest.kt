package com.oshinobu.demobot

import kotlinx.coroutines.runBlocking
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class DemoBotTest {
    // RFC 6238, приложение B: секрет "12345678901234567890" (SHA1), последние 6 цифр
    private val rfcSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    @Test
    fun totpMatchesRfc6238Vectors() {
        assertEquals("287082", Totp.code(rfcSecret, 59))
        assertEquals("081804", Totp.code(rfcSecret, 1111111109))
        assertEquals("050471", Totp.code(rfcSecret, 1111111111))
        assertEquals("005924", Totp.code(rfcSecret, 1234567890))
    }

    @Test
    fun secretIsTakenFromOtpauthUrl() {
        assertEquals(rfcSecret, Totp.secretFromUrl("otpauth://totp/Oshinobu:demo?secret=$rfcSecret&issuer=Oshinobu"))
    }

    @Test
    fun fileStoresSurviveRestart() = runBlocking {
        val dir = Files.createTempDirectory("demo-bot").toFile()
        FileSecureStore(dir.resolve("secure.json")).write("ratchet:dev", "state")
        FilePrefs(dir.resolve("prefs.json")).apply {
            setString("auth_token", "t")
            setStringList("handled", listOf("a", "b"))
            setLong("n", 5)
        }
        assertEquals("state", FileSecureStore(dir.resolve("secure.json")).read("ratchet:dev"))
        val prefs = FilePrefs(dir.resolve("prefs.json"))
        assertEquals("t", prefs.getString("auth_token"))
        assertEquals(listOf("a", "b"), prefs.getStringList("handled"))
        assertEquals(5L, prefs.getLong("n"))
        prefs.remove("auth_token")
        assertNull(FilePrefs(dir.resolve("prefs.json")).getString("auth_token"))
    }
}
