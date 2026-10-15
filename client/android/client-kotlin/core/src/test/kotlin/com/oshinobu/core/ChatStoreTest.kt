package com.oshinobu.core

import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.InMemorySecureStore
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ChatStoreTest {
    private fun summary(chats: ChatStore, login: String) = runBlocking { chats.getKnownPeers().single { it.peerLogin == login } }

    @Test
    fun `правка последнего сообщения меняет превью в списке чатов, правка старого — нет`() = runBlocking {
        val chats = ChatStore(InMemorySecureStore())
        chats.addMessage("bob", StoredMessage("m1", "первое", true, 1000))
        chats.addMessage("bob", StoredMessage("m2", "второе", true, 2000))

        chats.editMessageText("bob", "m1", "первое исправлено")
        assertEquals("второе", summary(chats, "bob").lastMessage)

        chats.editMessageText("bob", "m2", "второе исправлено")
        assertEquals("второе исправлено", summary(chats, "bob").lastMessage)
    }

    @Test
    fun `удаление закреплённого снимает закреп, удаление другого — нет`() = runBlocking {
        val chats = ChatStore(InMemorySecureStore())
        chats.addMessage("bob", StoredMessage("m1", "закреп", false, 1000))
        chats.addMessage("bob", StoredMessage("m2", "просто", false, 2000))
        chats.setPinned("bob", "m1")

        chats.deleteMessages("bob", listOf("m2"))
        assertEquals("m1", summary(chats, "bob").pinnedMessageId)

        chats.deleteMessages("bob", listOf("m1"))
        assertNull(summary(chats, "bob").pinnedMessageId)
    }
}
