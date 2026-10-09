package com.oshinobu.core

import com.oshinobu.core.storage.MessageStatus
import kotlinx.coroutines.runBlocking
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Действия внутри чата ([com.oshinobu.core.service.ChatService]) между двумя клиентами на стенде. */
class ChatServiceTest {
    private val net = TestNetwork()

    @AfterTest
    fun tearDown() = net.close()

    @Test
    fun `текст с ответом, правка, реакция, закреп, удаление у обоих, прочтение`() = runBlocking {
        val alice = net.device("alice")
        val bob = net.device("bob")
        val toBob = alice.peerOf(bob)
        val toAlice = bob.peerOf(alice)

        alice.chatService.sendText(toBob, "первое")
        net.eventually("Боб получил") { bob.chats.getMessages("alice").size == 1 }
        val first = bob.chats.getMessages("alice").single()

        // ответ с превью оригинала
        bob.chatService.sendText(toAlice, "ответ", replyTo = first)
        net.eventually("ответ у Алисы") { alice.chats.getMessages("bob").any { it.replyToMessageId == first.messageId } }
        assertEquals("первое", alice.chats.getMessages("bob").first { it.replyToMessageId != null }.replyToPreview)

        alice.chatService.editText(toBob, first.messageId, "первое (изм.)")
        bob.chatService.react(toAlice, first.messageId, "🔥")
        bob.chatService.setPinned(toAlice, first.messageId, pinned = true)
        net.eventually("правка у Боба") { bob.chats.getMessages("alice").first { it.messageId == first.messageId }.text == "первое (изм.)" }
        net.eventually("реакция у Алисы") { alice.chats.getMessages("bob").first { it.messageId == first.messageId }.peerReaction == "🔥" }
        net.eventually("закреп у Алисы") { alice.chats.getKnownPeers().single().pinnedMessageId == first.messageId }

        // прочтение: Боб отмечает, у Алисы — 'read', у Боба флаг по ack
        bob.chatService.sendReadReceipts(toAlice, bob.chats.getMessages("alice"))
        net.eventually("прочитано у Алисы") { alice.chats.getMessages("bob").first { it.messageId == first.messageId }.status == MessageStatus.READ }
        net.eventually("флаг квитанции у Боба") { bob.chats.getMessages("alice").first { it.messageId == first.messageId }.readReceiptSent }

        // удаление закреплённого у обоих — и закреп снимается у обоих
        alice.chatService.deleteMessages(toBob, listOf(first.messageId), forPeer = true, pinnedId = first.messageId)
        assertTrue(alice.chats.getMessages("bob").none { it.messageId == first.messageId })
        assertEquals(null, alice.chats.getKnownPeers().single().pinnedMessageId)
        net.eventually("удалено у Боба") { bob.chats.getMessages("alice").none { it.messageId == first.messageId } }
        net.eventually("закреп снят у Боба") { bob.chats.getKnownPeers().single().pinnedMessageId == null }
    }

    @Test
    fun `альбом с подписью и голосовое`() = runBlocking {
        val alice = net.device("alice")
        val bob = net.device("bob")
        val photos = List(2) { i -> com.oshinobu.core.service.OutgoingFile(alice.tempFile("p$i.jpg", ByteArray(5_000) { (it * i).toByte() }), isFile = false, isVideo = false) }
        alice.chatService.sendMedia(alice.peerOf(bob), photos, "подпись") { null }
        net.eventually("альбом у Боба") { bob.chats.getMessages("alice").size == 3 }
        assertEquals(1, bob.chats.getMessages("alice").map { it.groupId }.distinct().size)

        val voice = alice.tempFile("rec.m4a", ByteArray(3_000) { 1 })
        alice.chatService.sendRecorded(alice.peerOf(bob), voice, durationMs = 2_500, videoNote = false) { null }
        net.eventually("голосовое у Боба") { bob.chats.getMessages("alice").any { it.isVoice && it.durationMs == 2_500L } }
        assertTrue(!voice.exists(), "запись перенесена в постоянную папку")
    }
}
