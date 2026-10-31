import Foundation

/// Собеседник чата для действий: логин, аккаунт и (последнее известное) устройство.
public struct ChatPeer: Sendable, Equatable {
    public let login: String
    public let accountId: String?
    public let deviceId: String?

    public init(_ chat: ChatSummary) {
        login = chat.peerLogin
        accountId = chat.lastKnownAccountId
        deviceId = chat.lastKnownDeviceId
    }
}

/**
 * Действия с сообщениями (как core/service/ChatService.kt): сначала локально —
 * экран обновляется сразу, — потом служебное сообщение собеседнику через
 * надёжную очередь.
 */
public final class ChatService: @unchecked Sendable {
    private let chats: ChatStore
    private let messenger: PeerMessenger
    private let router: MessageRouter
    private let cleanup: MessageCleanup

    public init(chats: ChatStore, messenger: PeerMessenger, router: MessageRouter, cleanup: MessageCleanup) {
        self.chats = chats
        self.messenger = messenger
        self.router = router
        self.cleanup = cleanup
    }

    /// Реакция (nil — снять); у одного сообщения одна своя реакция.
    public func react(_ peer: ChatPeer, messageId: String, emoji: String?) async {
        chats.setReaction(peer.login, messageId, isMine: true, emoji: emoji)
        if let d = peer.deviceId { await messenger.sendControl(to: d, .reaction(target: messageId, emoji: emoji)) }
    }

    public func edit(_ peer: ChatPeer, messageId: String, newText: String) async {
        chats.editMessageText(peer.login, messageId, newText)
        if let d = peer.deviceId { await messenger.sendControl(to: d, .edit(target: messageId, newText: newText)) }
    }

    /// Удалить у себя; [forBoth] — и у собеседника.
    public func delete(_ peer: ChatPeer, messageIds: [String], forBoth: Bool) async {
        let set = Set(messageIds)
        let removed = chats.messages(peer.login).filter { set.contains($0.messageId) }
        chats.deleteMessages(peer.login, messageIds)
        cleanup.purgeAll(removed)
        if forBoth, let d = peer.deviceId { await messenger.sendControl(to: d, .delete(targets: messageIds)) }
    }

    /// Закрепить (nil — открепить) — у обоих.
    public func pin(_ peer: ChatPeer, messageId: String?) async {
        let previous = chats.peer(peer.login)?.pinnedMessageId
        chats.setPinned(peer.login, messageId: messageId)
        guard let d = peer.deviceId, let target = messageId ?? previous else { return }
        await messenger.sendControl(to: d, .pin(target: target, pinned: messageId != nil))
    }

    /// Переслать текст в другой чат — новым сообщением, зашифрованным для нового получателя.
    public func forwardText(_ text: String, to target: ChatPeer) async throws {
        guard let d = target.deviceId else { return }
        let inner = InnerMessage.text(text)
        var m = StoredMessage(messageId: inner.messageId, text: text, isMine: true, timestamp: inner.sentAt)
        m.status = MessageStatus.sending
        chats.addMessage(target.login, m, accountId: target.accountId)
        try await messenger.send(to: d, inner, peerLogin: target.login)
    }

    /// "Сбросить шифрование" из меню чата.
    public func resetSession(_ peer: ChatPeer) async {
        if let d = peer.deviceId { await router.resetSessionWith(d, reason: "manual (chat menu)") }
    }

    /// Очистить историю / удалить чат; [forPeer] — и у собеседника (заодно сброс сессии).
    public func clearOrDelete(_ peer: ChatPeer, deleteChat: Bool, forPeer: Bool) async {
        if forPeer, let d = peer.deviceId {
            await router.resetSessionWith(d, reason: deleteChat ? "delete chat (both sides)" : "clear history (both sides)")
            await messenger.sendControl(to: d, deleteChat ? .deleteChat() : .clearChat())
        }
        let all = chats.messages(peer.login)
        if deleteChat { chats.removeChat(peer.login) } else { chats.clearHistory(peer.login) }
        cleanup.purgeAll(all)
    }
}
