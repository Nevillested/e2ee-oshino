package com.oshinobu.core

import com.oshinobu.core.net.ConnectionStatus
import com.oshinobu.core.service.CallPeer
import com.oshinobu.core.service.CallState
import com.oshinobu.core.service.IncomingCall
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Звонки между двумя клиентами через стенд [TestNetwork]: сигналы
 * зашифрованы настоящим ratchet (первый звонок поднимает X3DH), WebRTC —
 * фейковый автомат offer/answer ([FakeRtcEngine]).
 */
class CallManagerTest {
    private fun TestNetwork.Device.callPeer() = CallPeer(deviceId, login, accountId)

    private suspend fun TestNetwork.callAnswered(alice: TestNetwork.Device, bob: TestNetwork.Device) {
        val incoming = scope.async(start = CoroutineStart.UNDISPATCHED) { bob.calls.incomingCalls.first() }
        alice.calls.startCall(bob.callPeer())
        val call: IncomingCall = incoming.await()
        assertEquals(alice.deviceId, call.peer.deviceId)
        eventually("bob rings") { bob.calls.state.value == CallState.INCOMING_RINGING }
        bob.calls.acceptCall()
        eventually("both connected") {
            alice.calls.state.value == CallState.CONNECTED && bob.calls.state.value == CallState.CONNECTED
        }
    }

    @Test
    fun answeredCallConnectsExchangesIceAndLogsBothSides() = runBlocking {
        TestNetwork().use { net ->
            val alice = net.device("alice")
            val bob = net.device("bob")
            net.callAnswered(alice, bob)
            // кандидат пришёл, пока bob ещё звонил — применён после offer, не потерян
            net.eventually("bob got alice's candidate") { bob.rtc.last.remoteCandidates.contains("candidate-of-offer-1") }
            net.eventually("bob resolved caller") { bob.calls.peer.value?.login == "alice" }

            net.clock += 65_000
            alice.calls.hangUp()
            net.eventually("both idle") { alice.calls.state.value == CallState.IDLE && bob.calls.state.value == CallState.IDLE }
            assertTrue(alice.rtc.last.closed && bob.rtc.last.closed)

            val aliceLog = alice.chats.getMessages("bob").single { it.isCallLog }
            assertEquals("outgoing", aliceLog.callDirection)
            assertEquals("answered", aliceLog.callOutcome)
            assertEquals(65L, aliceLog.callDurationSeconds)
            val bobLog = bob.chats.getMessages("alice").single { it.isCallLog }
            assertEquals("incoming", bobLog.callDirection)
            assertEquals("answered", bobLog.callOutcome)
        }
    }

    @Test
    fun callerFromKnownChatIsNamedImmediately() = runBlocking {
        TestNetwork().use { net ->
            val alice = net.device("alice")
            val bob = net.device("bob")
            alice.sendText(bob, "привет")
            net.eventually("bob got alice's message") { bob.chats.getMessages("alice").isNotEmpty() }
            val incoming = net.scope.async(start = CoroutineStart.UNDISPATCHED) { bob.calls.incomingCalls.first() }
            alice.calls.startCall(bob.callPeer())
            // экран входящего строится по этому событию — имя должно быть в нём, а не прийти потом с сервера
            assertEquals("alice", incoming.await().peer.login)
        }
    }

    @Test
    fun declinedCallShowsReasonThenEnds() = runBlocking {
        TestNetwork().use { net ->
            val alice = net.device("alice")
            val bob = net.device("bob")
            val statuses = net.scope.async(start = CoroutineStart.UNDISPATCHED) {
                alice.calls.status.takeWhile { it != "call.declined" }.toList()
            }
            alice.calls.startCall(bob.callPeer())
            net.eventually("bob rings") { bob.calls.state.value == CallState.INCOMING_RINGING }
            bob.calls.declineCall()
            statuses.await()
            net.eventually("alice idle") { alice.calls.state.value == CallState.IDLE }
            assertEquals("no_answer", alice.chats.getMessages("bob").single { it.isCallLog }.callOutcome)
            assertEquals("missed", bob.chats.getMessages("alice").single { it.isCallLog }.callOutcome)
        }
    }

    @Test
    fun secondCallerGetsBusy() = runBlocking {
        TestNetwork().use { net ->
            val alice = net.device("alice")
            val bob = net.device("bob")
            val carol = net.device("carol")
            net.callAnswered(alice, bob)
            val reason = net.scope.async(start = CoroutineStart.UNDISPATCHED) { carol.calls.status.first { it == "call.busy" } }
            carol.calls.startCall(bob.callPeer())
            reason.await()
            net.eventually("carol idle") { carol.calls.state.value == CallState.IDLE }
            assertEquals(CallState.CONNECTED, bob.calls.state.value)
            assertEquals(alice.deviceId, bob.calls.peer.value?.deviceId)
        }
    }

    @Test
    fun turningVideoOnRenegotiatesAndTellsPeer() = runBlocking {
        TestNetwork().use { net ->
            val alice = net.device("alice")
            val bob = net.device("bob")
            net.callAnswered(alice, bob)
            alice.calls.toggleVideo()
            net.eventually("bob sees remote video") { bob.calls.remoteVideoEnabled.value }
            net.eventually("renegotiation answered") { alice.rtc.last.remoteDescriptions.size == 2 }
            assertTrue(bob.rtc.last.remoteDescriptions.contains("offer:offer-1"), "renegotiation offer reached bob")
            assertEquals(CallState.CONNECTED, alice.calls.state.value)
        }
    }

    @Test
    fun serverSideDeclineWithoutSenderEndsOutgoingCall() = runBlocking {
        TestNetwork().use { net ->
            val alice = net.device("alice")
            val bob = net.device("bob")
            alice.calls.startCall(bob.callPeer())
            net.eventually("bob rings") { bob.calls.state.value == CallState.INCOMING_RINGING }
            // как /calls/decline на сервере: незашифрованный "{}" без отправителя
            alice.transport.callSignalsFlow.emit(JsonObject(mapOf("type" to JsonPrimitive("call_reject"))))
            net.eventually("alice idle") { alice.calls.state.value == CallState.IDLE }
        }
    }

    @Test
    fun unavailablePeerGetsMissedCallMessage() = runBlocking {
        TestNetwork().use { net ->
            val alice = net.device("alice")
            val bob = net.device("bob")
            bob.transport.statusFlow.value = ConnectionStatus.RECONNECTING
            alice.calls.startCall(bob.callPeer())
            net.eventually("ringing") { alice.calls.state.value == CallState.OUTGOING_RINGING }
            alice.transport.callSignalsFlow.emit(JsonObject(mapOf("type" to JsonPrimitive("call_unavailable"))))
            net.eventually("alice idle") { alice.calls.state.value == CallState.IDLE }
            bob.transport.statusFlow.value = ConnectionStatus.CONNECTED
            net.relay.flush(bob.deviceId)
            net.eventually("bob sees missed call") {
                bob.chats.getMessages("alice").any { it.isCallLog && it.callOutcome == "missed" }
            }
        }
    }

    @Test
    fun offerNotSentEndsCallWithoutHistory() = runBlocking {
        TestNetwork().use { net ->
            val alice = net.device("alice")
            val bob = net.device("bob")
            alice.transport.statusFlow.value = ConnectionStatus.RECONNECTING
            val call = async { alice.calls.startCall(bob.callPeer()) }
            net.eventually("no connection shown") { alice.calls.status.value == "call.noConnection" }
            call.await()
            assertEquals(CallState.IDLE, alice.calls.state.value)
            assertTrue(alice.chats.getMessages("bob").none { it.isCallLog })
        }
    }
}
