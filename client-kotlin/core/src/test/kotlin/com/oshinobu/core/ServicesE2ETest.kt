package com.oshinobu.core

import com.oshinobu.core.net.ConnectionStatus
import com.oshinobu.core.net.IncomingEnvelope
import com.oshinobu.core.protocol.InnerMessage
import com.oshinobu.core.storage.MessageStatus
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Сквозная проверка обмена сообщениями между двумя клиентами (стенд — [TestNetwork]). */
class ServicesE2ETest {
    private val net = TestNetwork()

    @AfterTest
    fun tearDown() = net.close()

    @Test
    fun `переписка, служебные сообщения, дубли и удаление у обоих`() = runBlocking {
        val alice = net.device("alice")
        val bob = net.device("bob")

        // первое сообщение: X3DH с одноразовым ключом Боба
        val m1 = alice.sendText(bob, "Привет, Боб!")
        net.eventually("Боб получил m1") { bob.chats.getMessages("alice").any { it.messageId == m1.messageId } }
        net.eventually("у Алисы m1 стало 'sent' по ack") {
            alice.chats.getMessages("bob").first { it.messageId == m1.messageId }.status == MessageStatus.SENT
        }
        assertEquals("Привет, Боб!", bob.chats.getMessages("alice").single().text)
        assertEquals(1, bob.chats.getKnownPeers().single().unreadCount)
        assertEquals(1, bob.host.sounds.get())
        // одноразовый ключ, использованный в X3DH, удалён у Боба локально
        assertEquals(4, bob.keys.loadIdentity()!!.oneTimePrekeys.size)

        // ответ — смена эпохи ratchet
        val r1 = bob.sendText(alice, "Привет, Алиса")
        net.eventually("Алиса получила ответ") { alice.chats.getMessages("bob").any { it.messageId == r1.messageId } }

        // служебные: реакция, квитанция, правка — без звука
        val soundsBefore = alice.host.sounds.get()
        bob.messenger.sendControl(alice.deviceId, InnerMessage.reaction(m1.messageId, "❤️"))
        bob.messenger.sendControl(alice.deviceId, InnerMessage.readReceipt(listOf(m1.messageId)))
        alice.messenger.sendControl(bob.deviceId, InnerMessage.edit(m1.messageId, "Привет, Боб! (изм.)"))
        net.eventually("реакция и прочтение у Алисы") {
            alice.chats.getMessages("bob").first { it.messageId == m1.messageId }.let { it.peerReaction == "❤️" && it.status == MessageStatus.READ }
        }
        net.eventually("правка у Боба") { bob.chats.getMessages("alice").first().edited }
        assertEquals(soundsBefore, alice.host.sounds.get())

        // сервер передоставляет уже подтверждённое (потерялся наш ack) — дубля нет, сессия жива
        val alreadyHandled = net.relay.delivered.last { it.first == bob.deviceId }.second
        val countBefore = bob.chats.getMessages("alice").size
        bob.transport.messagesFlow.tryEmit(IncomingEnvelope(alreadyHandled.envelope, "srv-dup"))
        delay(300)
        assertEquals(countBefore, bob.chats.getMessages("alice").size)
        val m2 = alice.sendText(bob, "после дубля")
        net.eventually("сессия после дубля работает") { bob.chats.getMessages("alice").any { it.messageId == m2.messageId } }

        // удаление у обоих
        alice.messenger.sendControl(bob.deviceId, InnerMessage.delete(listOf(m2.messageId)))
        net.eventually("m2 удалено у Боба") { bob.chats.getMessages("alice").none { it.messageId == m2.messageId } }
    }

    @Test
    fun `офлайн-получатель, потеря сессии и самолечение`() = runBlocking {
        val alice = net.device("alice")
        val bob = net.device("bob")
        alice.sendText(bob, "раз")
        net.eventually("Боб получил первое") { bob.chats.getMessages("alice").size == 1 }

        // Боб офлайн: сообщения ждут на сервере и приходят на реконнекте
        bob.transport.statusFlow.value = ConnectionStatus.RECONNECTING
        val offline = alice.sendText(bob, "пока ты был офлайн")
        delay(200)
        assertTrue(bob.chats.getMessages("alice").none { it.messageId == offline.messageId })
        bob.transport.statusFlow.value = ConnectionStatus.CONNECTED
        net.relay.flush(bob.deviceId)
        net.eventually("досылка на реконнекте") { bob.chats.getMessages("alice").any { it.messageId == offline.messageId } }

        // Боб ответил — Алиса перестаёт прикладывать X3DH-поля к сообщениям
        val reply = bob.sendText(alice, "ответ")
        net.eventually("Алиса получила ответ") { alice.chats.getMessages("bob").any { it.messageId == reply.messageId } }
        assertTrue(alice.sessions.pendingInit(bob.deviceId) == null)

        // Боб потерял сессию
        bob.sessions.clear(alice.deviceId)
        val lost = alice.sendText(bob, "это не расшифровать")
        delay(300)
        assertTrue(bob.chats.getMessages("alice").none { it.messageId == lost.messageId })
        // через 2 минуты Боб сдаётся: ack + заглушка "не удалось дешифровать"
        net.clock += 3 * 60_000
        net.relay.flush(bob.deviceId)
        net.eventually("заглушка у Боба") { bob.chats.getMessages("alice").any { it.isUndecryptable } }
        net.relay.flush(bob.deviceId)
        delay(300)
        assertEquals(1, bob.chats.getMessages("alice").count { it.isUndecryptable }, "повтор не плодит заглушки")

        // самолечение: сброс сессии → следующее сообщение поднимает свежий X3DH
        bob.router.resetSessionWith(alice.deviceId, "test")
        net.eventually("Алиса стёрла сессию по session_reset") { alice.sessions.get(bob.deviceId) == null }
        val healed = alice.sendText(bob, "снова на связи")
        net.eventually("после сброса всё расшифровывается") { bob.chats.getMessages("alice").any { it.messageId == healed.messageId } }
    }

    @Test
    fun `первое сообщение потерялось — сессия поднимается по следующему`() = runBlocking {
        val alice = net.device("alice")
        val bob = net.device("bob")
        bob.transport.statusFlow.value = ConnectionStatus.RECONNECTING
        val lost = alice.sendText(bob, "первое — потеряется")
        net.eventually("первое на сервере") { net.relay.pending.values.any { it.first == bob.deviceId } }
        net.relay.pending.clear() // сервер его потерял (как несохраняемый сигнал звонка)
        val second = alice.sendText(bob, "второе")
        bob.transport.statusFlow.value = ConnectionStatus.CONNECTED
        net.relay.flush(bob.deviceId)
        net.eventually("второе расшифровано без первого") { bob.chats.getMessages("alice").any { it.messageId == second.messageId } }
        assertTrue(bob.chats.getMessages("alice").none { it.messageId == lost.messageId })
    }
}
