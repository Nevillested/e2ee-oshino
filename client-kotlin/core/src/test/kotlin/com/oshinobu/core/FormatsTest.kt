package com.oshinobu.core

import com.oshinobu.core.format.formatChatTime
import com.oshinobu.core.format.formatFileSize
import com.oshinobu.core.format.formatPresence
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.test.Test
import kotlin.test.assertEquals

class FormatsTest {
    private val zone = ZoneId.of("Asia/Tokyo")
    private fun ms(y: Int, mo: Int, d: Int, h: Int, mi: Int) = ZonedDateTime.of(y, mo, d, h, mi, 0, 0, zone).toInstant().toEpochMilli()
    private val now = ms(2026, 10, 9, 15, 30)
    private val tr: (String) -> String = { it.substringAfterLast('.') }

    @Test
    fun `время чата`() {
        assertEquals("", formatChatTime(0, now, zone))
        assertEquals("09:05", formatChatTime(ms(2026, 10, 9, 9, 5), now, zone))
        assertEquals("08.10", formatChatTime(ms(2026, 10, 8, 23, 59), now, zone))
    }

    @Test
    fun `присутствие`() {
        assertEquals("typing", formatPresence(true, true, null, tr, now, zone))
        assertEquals("online", formatPresence(false, true, null, tr, now, zone))
        assertEquals("", formatPresence(false, false, null, tr, now, zone))
        assertEquals("justNow", formatPresence(false, false, now - 30_000, tr, now, zone))
        assertEquals("12 minutesAgoSuffix", formatPresence(false, false, now - 12 * 60_000, tr, now, zone))
        assertEquals("10:00", formatPresence(false, false, ms(2026, 10, 9, 10, 0), tr, now, zone))
        assertEquals("yesterdayAt 22:15", formatPresence(false, false, ms(2026, 10, 8, 22, 15), tr, now, zone))
        assertEquals("01.09.2026 07:00", formatPresence(false, false, ms(2026, 9, 1, 7, 0), tr, now, zone))
    }

    @Test
    fun `размер файла`() {
        assertEquals("512 bytes", formatFileSize(512, tr))
        assertEquals("1.5 kb", formatFileSize(1536, tr))
        assertEquals("20.0 mb", formatFileSize(20L * 1024 * 1024, tr))
        assertEquals("1.25 gb", formatFileSize(1342177280, tr))
    }
}
