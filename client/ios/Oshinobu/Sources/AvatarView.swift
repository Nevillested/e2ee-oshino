import SwiftUI

/// Круглый аватар собеседника (логин — для совместимости вызовов; без фото — силуэт, как на Android).
struct AvatarView: View {
    let accountId: String?
    let login: String
    let size: CGFloat

    var body: some View { PeerAvatar(accountId: accountId, size: size) }
}
