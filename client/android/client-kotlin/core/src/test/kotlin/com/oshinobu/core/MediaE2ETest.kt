package com.oshinobu.core

import com.oshinobu.core.service.DownloadSpec
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.PendingSendJob
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.runBlocking
import java.util.UUID
import kotlin.random.Random
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Сквозная проверка файлов: отправка через очередь файлов → сервер → скачивание и расшифровка у получателя. */
class MediaE2ETest {
    private val net = TestNetwork()

    @AfterTest
    fun tearDown() = net.close()

    /** Пузырь файла в своей истории + задание в очередь — так, как это делает экран чата. */
    private suspend fun TestNetwork.Device.sendFile(to: TestNetwork.Device, name: String, bytes: ByteArray): String {
        val id = UUID.randomUUID().toString()
        val file = tempFile(name, bytes)
        chats.addMessage(
            to.login,
            StoredMessage(id, "", true, net.clock, isMedia = true, isFile = true, fileSize = bytes.size.toLong(), fileName = name, status = MessageStatus.SENDING),
        )
        retrier.enqueue(
            PendingSendJob.Media(
                id, PendingSendJob.QUEUED, to.login, to.deviceId, to.accountId,
                PendingSendJob.FileItem(id, file.path, bytes.size.toLong(), name, isFile = true, isVideo = false, isSpoiler = false),
            ),
        )
        return id
    }

    private suspend fun TestNetwork.Device.download(from: TestNetwork.Device, messageId: String): ByteArray {
        val msg = chats.getMessages(from.login).first { it.messageId == messageId }
        return downloads.ensureDownloaded(DownloadSpec.of(msg, from.login, msg.fileName ?: "")!!).readBytes()
    }

    @Test
    fun `небольшой файл — целиком, скачивание и подтверждение получения`() = runBlocking {
        val alice = net.device("alice")
        val bob = net.device("bob")
        val bytes = Random(1).nextBytes(150_000)
        val id = alice.sendFile(bob, "отчёт.pdf", bytes)

        net.eventually("Боб получил файл") { bob.chats.getMessages("alice").any { it.messageId == id } }
        net.eventually("у Алисы файл 'sent'") { alice.chats.getMessages("bob").single().status == MessageStatus.SENT }
        val received = bob.chats.getMessages("alice").single()
        assertTrue(received.isMedia && received.isFile && !received.chunked)
        assertEquals("отчёт.pdf", received.fileName)
        assertEquals("", received.text, "у медиа нет фиктивного текста")

        assertContentEquals(bytes, bob.download(alice, id))
        net.eventually("сервер узнал, что получатель забрал файл") { received.mediaId in net.receivedConfirmations }
        // свой файл у Алисы сразу лежит в кэше — скачивать обратно не нужно
        assertContentEquals(bytes, alice.media.cacheFile(received.mediaId!!).readBytes())
        // на сервере только шифротекст
        assertTrue(!net.mediaBlobs.getValue(received.mediaId!!).contentEquals(bytes))
    }

    @Test
    fun `большой файл — частями, с повтором упавшей части`() = runBlocking {
        val alice = net.device("alice")
        val bob = net.device("bob")
        val bytes = Random(2).nextBytes(21 * 1024 * 1024)
        net.failNextParts.set(1) // первая попытка одной из частей падает
        val id = alice.sendFile(bob, "видео.mp4", bytes)

        net.eventually("Боб получил большой файл") { bob.chats.getMessages("alice").any { it.messageId == id } }
        val received = bob.chats.getMessages("alice").single()
        assertTrue(received.chunked)
        assertContentEquals(bytes, bob.download(alice, id))
        assertTrue(alice.chunkedSessions.get(id) == null, "сессия докачки убрана")
        assertTrue(!alice.uploader.encryptedTempFile(id).exists(), "зашифрованная копия удалена")
    }

    @Test
    fun `группа файлов с подписью — одним конвертом`() = runBlocking {
        val alice = net.device("alice")
        val bob = net.device("bob")
        val groupId = UUID.randomUUID().toString()
        val textId = UUID.randomUUID().toString()
        val photos = List(2) { Random(10 + it).nextBytes(40_000) }
        val items = photos.mapIndexed { i, b ->
            val mid = UUID.randomUUID().toString()
            alice.chats.addMessage(
                bob.login,
                StoredMessage(mid, "", true, net.clock, isMedia = true, fileName = "p$i.jpg", groupId = groupId, status = MessageStatus.SENDING),
            )
            PendingSendJob.FileItem(mid, alice.tempFile("p$i.jpg", b).path, b.size.toLong(), "p$i.jpg", isFile = false, isVideo = false, isSpoiler = i == 1)
        }
        alice.chats.addMessage(bob.login, StoredMessage(textId, "смотри!", true, net.clock, groupId = groupId, status = MessageStatus.SENDING))
        alice.retrier.enqueue(
            PendingSendJob.MediaGroup(groupId, PendingSendJob.QUEUED, bob.login, bob.deviceId, bob.accountId, "смотри!", textId, items),
        )

        net.eventually("группа у Боба") { bob.chats.getMessages("alice").size == 3 }
        val got = bob.chats.getMessages("alice")
        assertTrue(got.all { it.groupId == groupId })
        assertEquals("смотри!", got.first { it.messageId == textId }.text)
        assertTrue(got.first { it.messageId == items[1].messageId }.isSpoiler)
        net.eventually("у Алисы вся группа 'sent' по ack одного конверта") {
            alice.chats.getMessages("bob").all { it.status == MessageStatus.SENT }
        }
        items.forEachIndexed { i, item -> assertContentEquals(photos[i], bob.download(alice, item.messageId)) }
    }
}
