import OshinobuCore
import SwiftUI

/// Профиль собеседника (нажатие на шапку чата) — как PeerProfileScreen на Android: крупный аватар
/// (нажатие — посмотреть), логин, имя, «о себе» и день рождения, если собеседник их показывает.
struct PeerProfileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.navBack) private var navBack
    let accountId: String
    let login: String
    @State private var loaded = false
    @State private var profile: PeerProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IconButtonM(.arrowBack) { navBack() }.padding(4)
            ScrollView {
                VStack(spacing: 0) {
                    SharedPeerAvatar(accountId: accountId, size: 128, role: .target)
                        .onTapGesture {
                            Task {
                                guard let data = await model.core.avatars.get(accountId), let image = UIImage(data: data) else { return }
                                model.popups.show(dim: false) { PhotoViewer(image: image) { model.popups.dismiss() } }
                            }
                        }
                    Gap(24)
                    if !loaded {
                        AppLoadingIndicator(size: 64)
                    } else {
                        VStack(spacing: 2) {
                            ProfileRow(icon: .oBadge, title: tr("profile_login"), value: login)
                            ProfileRow(icon: .oBadge, title: tr("profile_displayName"), value: profile?.displayName ?? login)
                            if let status = profile?.status, !status.isEmpty { ProfileRow(icon: .oChatBubbleOutline, title: tr("profile_status"), value: status) }
                            if let birthday = profile?.birthday, !birthday.isEmpty { ProfileRow(icon: .oCake, title: tr("profile_birthday"), value: birthday) }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(model.theme.background.ignoresSafeArea())
        .task(id: accountId) {
            // профиль обновляется и пока экран открыт (изменил «о себе», сняли блокировку)
            let profiles = model.core.peerProfiles
            profile = await profiles.get(accountId, login: login)
            loaded = true
            for await changed in profiles.changes.stream() where changed == accountId { profile = await profiles.get(accountId, login: login) }
        }
    }
}
