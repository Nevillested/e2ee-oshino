import Foundation
import XCTest
@testable import OshinobuCore

/// Стенограмма переписки, снятая с первой версии клиента (та же, что у Android —
/// ProtocolVectorsTest): iOS обязан расшифровывать её шаг за шагом и давать
/// побайтно то же состояние ratchet. Упал тест — iOS и Android друг друга не поймут.
final class ProtocolVectorsTests: XCTestCase {
    private func transcript() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "protocol_transcript", withExtension: "json", subdirectory: "Resources"))
        return try JSONValue.parse(Data(contentsOf: url))
    }

    private func withoutSendingKeys(_ s: JSONValue) -> JSONValue {
        guard var o = s.object else { return s }
        o["sending_ratchet_private"] = nil
        o["sending_ratchet_public"] = nil
        return .object(o)
    }

    func testTranscriptDecryptsStepByStep() throws {
        let t = try transcript()
        let bobStore = (t["bob_store"]?.object ?? [:]).compactMapValues { $0.primitiveContent }
        let me = try XCTUnwrap(try StoredIdentity.fromStore(bobStore))

        for (i, step) in (t["steps"]?.array ?? []).enumerated() {
            let env = try XCTUnwrap(step["envelope"]?.object)
            let before = step["state_before"].flatMap { $0.isNull ? nil : $0 }

            var state: RatchetState
            if let before {
                state = try RatchetState.fromJSON(before)
                XCTAssertEqual(state.toJSON(), before, "шаг \(i): JSON состояния")
            } else {
                state = try XCTUnwrap(try PeerCipher.startIncomingSession(envelope: env, me: me)).0
            }

            if step["expect"]?.string == "already_processed" {
                XCTAssertThrowsError(try state.nextReceivingKey(envelope: env), "шаг \(i): ожидался дубль") { error in
                    guard case RatchetError.alreadyProcessed = error else { return XCTFail("шаг \(i): \(error)") }
                }
                continue
            }

            let got = try InnerMessage.decode(try decryptMessage(messageKey: try state.nextReceivingKey(envelope: env), envelope: env))
            let want = try InnerMessage.decode(try XCTUnwrap(step["inner"]?.string))
            XCTAssertEqual(got, want, "шаг \(i): текст")

            let wantAfter = try XCTUnwrap(step["state_after"])
            if before == nil {
                XCTAssertEqual(withoutSendingKeys(state.toJSON()), withoutSendingKeys(wantAfter), "шаг \(i): состояние после X3DH")
            } else {
                XCTAssertEqual(state.toJSON(), wantAfter, "шаг \(i): состояние")
            }
        }

        for v in t["media"]?.array ?? [] {
            func f(_ n: String) throws -> Data { try unb64(try XCTUnwrap(v[n]?.string)) }
            XCTAssertEqual(try MediaCipher.decrypt(key: f("key"), nonce: f("nonce"), mac: f("mac"), ciphertext: f("ciphertext")), try f("plain"))
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (n, v) in (t["streaming"]?.array ?? []).enumerated() {
            let enc = tmp.appendingPathComponent("s\(n).enc")
            let out = tmp.appendingPathComponent("s\(n).out")
            try unb64(try XCTUnwrap(v["file"]?.string)).write(to: enc)
            try StreamingFileCipher.decryptFile(input: enc, output: out, key: try unb64(try XCTUnwrap(v["key"]?.string)))
            XCTAssertEqual(try Data(contentsOf: out), try unb64(try XCTUnwrap(v["plain"]?.string)), "streaming \(n)")
        }
    }

    /// Своя переписка Алиса ↔ Боб: X3DH, смена эпох, дубль.
    func testOwnConversationRoundTrip() throws {
        let bob = try StoredIdentity.generate(deviceId: "bob-device", oneTimePrekeyCount: 2)
        let aliceId = try StoredIdentity.generate(deviceId: "alice-device")
        var (alice, initHeader) = try PeerCipher.startOutgoingSession(bundle: try bob.bundle(), myDeviceId: "alice-device", myIdentityDh: aliceId.identityDh)

        let m1 = InnerMessage.text("Привет из Swift! 🚀")
        let e1 = try PeerCipher.seal(&alice, inner: m1, myDeviceId: "alice-device", initHeader: initHeader)
        var (bobState, x3dh) = try XCTUnwrap(try PeerCipher.startIncomingSession(envelope: e1, me: bob))
        XCTAssertNotNil(x3dh.consumedOneTimePrekey)
        XCTAssertEqual(try PeerCipher.open(&bobState, envelope: e1), m1)

        let r1 = InnerMessage.text("ответ", replyTo: m1.messageId, replyPreview: "Привет")
        let f1 = try PeerCipher.seal(&bobState, inner: r1, myDeviceId: "bob-device")
        XCTAssertEqual(try PeerCipher.open(&alice, envelope: f1), r1)

        // дубль уже расшифрованного — alreadyProcessed, состояние не трогаем
        var copy = alice
        XCTAssertThrowsError(try PeerCipher.open(&copy, envelope: f1))

        // подмена заголовка ломает AAD
        var tampered = try PeerCipher.seal(&alice, inner: InnerMessage.text("x"), myDeviceId: "alice-device")
        tampered["sender_device_id"] = .string("mallory")
        XCTAssertThrowsError(try PeerCipher.open(&bobState, envelope: tampered))
    }

    func testAadFormat() {
        let aad = buildAad(["sender_device_id": "d", "ratchet_pubkey": "r", "message_number": .int(5), "used_one_time_prekey": .null])
        XCTAssertEqual(String(decoding: aad, as: UTF8.self),
                       "sender_device_id=d|ratchet_pubkey=r|message_number=5|ephemeral_pubkey=null|sender_identity_dh_pubkey=null|used_one_time_prekey=null")
    }
}
