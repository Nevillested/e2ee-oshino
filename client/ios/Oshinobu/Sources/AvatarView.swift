import OshinobuCore
import SwiftUI

/// Круглый аватар: фото с сервера (кэш), пока нет — первая буква логина.
struct AvatarView: View {
    @EnvironmentObject private var model: AppModel
    let accountId: String?
    let login: String
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                model.theme.primary.opacity(0.25)
                Text(login.prefix(1).uppercased()).font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(model.theme.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: accountId) { await load() }
    }

    private func load() async {
        guard let accountId else { return }
        await show(accountId)
        for await changed in model.core.avatars.changes.stream() where changed == accountId { await show(accountId) }
    }

    private func show(_ accountId: String) async {
        let data = await model.core.avatars.get(accountId)
        let side = size * 3
        image = await Task.detached { data.flatMap(UIImage.init(data:))?.preparingThumbnail(of: CGSize(width: side, height: side)) }.value
    }
}
