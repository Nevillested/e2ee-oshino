import Foundation
import XCTest
@testable import OshinobuCore

/// Хранилище переписки: дубли и «надгробия» (как ChatStoreTest на Android).
final class ChatStoreTests: XCTestCase {
    private func store() -> ChatStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dirs = AppDirs(documents: root.appendingPathComponent("d"), support: root.appendingPathComponent("s"), temp: root.appendingPathComponent("t"))
        return ChatStore(dirs: dirs, now: { 1_000 })
    }

    func testDuplicateAndTombstone() {
        let chats = store()
        let m = StoredMessage(messageId: "m1", text: "привет", isMine: false, timestamp: 10)
        chats.addMessage("bob", m, incrementUnread: true)
        chats.addMessage("bob", m, incrementUnread: true) // повторная доставка
        XCTAssertEqual(chats.messages("bob").count, 1)
        XCTAssertEqual(chats.peer("bob")?.unreadCount, 1)

        // 'delete' обогнал само сообщение — оно не должно вернуться
        chats.deleteMessages("bob", ["m2"])
        chats.addMessage("bob", StoredMessage(messageId: "m2", text: "x", isMine: false, timestamp: 11))
        XCTAssertNil(chats.messages("bob").first { $0.messageId == "m2" })
    }

    func testEditUpdatesPreviewAndDeleteUnpins() {
        let chats = store()
        chats.addMessage("bob", StoredMessage(messageId: "m1", text: "старое", isMine: true, timestamp: 10))
        chats.setPinned("bob", messageId: "m1")
        chats.editMessageText("bob", "m1", "новое")
        XCTAssertEqual(chats.peer("bob")?.lastMessage, "новое")
        chats.deleteMessages("bob", ["m1"])
        XCTAssertNil(chats.peer("bob")?.pinnedMessageId)
    }

    func testPersistsAcrossInstances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dirs = AppDirs(documents: root.appendingPathComponent("d"), support: root.appendingPathComponent("s"), temp: root.appendingPathComponent("t"))
        ChatStore(dirs: dirs).addMessage("bob", StoredMessage(messageId: "m1", text: "hi", isMine: true, timestamp: 1))
        XCTAssertEqual(ChatStore(dirs: dirs).messages("bob").map(\.messageId), ["m1"])
    }
}
