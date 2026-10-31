import SwiftUI

/// Темы — те же пять, что на Android (ui/theme/Theme.kt), с теми же цветами и id в настройках.
struct AppTheme: Identifiable, Equatable {
    let id: String
    let titleKey: LocalizedStringKey
    let primary: Color
    let onPrimary: Color
    let background: Color
    let surface: Color
    let textPrimary: Color
    let textMuted: Color
    let chatBackground: Color
    let bubbleMine: Color
    let onBubbleMine: Color
    let sentTick: Color
    let isDark: Bool

    static func == (a: AppTheme, b: AppTheme) -> Bool { a.id == b.id }

    static let navy = AppTheme(
        id: "dark", titleKey: "theme_navy", primary: Color(hex: 0x2AABEE), onPrimary: .white, background: Color(hex: 0x17212B),
        surface: Color(hex: 0x242F3D), textPrimary: .white, textMuted: Color(hex: 0x8E99A4), chatBackground: Color(hex: 0x17212B),
        bubbleMine: Color(hex: 0x2AABEE), onBubbleMine: .white, sentTick: Color(hex: 0x40C4FF), isDark: true
    )

    static let white = AppTheme(
        id: "light", titleKey: "theme_white", primary: Color(hex: 0x2AABEE), onPrimary: .white, background: Color(hex: 0xEEF2F7),
        surface: .white, textPrimary: Color(hex: 0x17212B), textMuted: Color(hex: 0x6B7A88), chatBackground: Color(hex: 0xDCE6EF),
        bubbleMine: Color(hex: 0x2AABEE), onBubbleMine: .white, sentTick: Color(hex: 0xD6F1FF), isDark: false
    )

    static let black = AppTheme(
        id: "black", titleKey: "theme_black", primary: Color(hex: 0x0A84FF), onPrimary: .white, background: .black,
        surface: Color(hex: 0x1C1C1E), textPrimary: .white, textMuted: Color(hex: 0x8E8E93), chatBackground: .black,
        bubbleMine: Color(hex: 0x0A84FF), onBubbleMine: .white, sentTick: Color(hex: 0xB8DAFF), isDark: true
    )

    static let yellow = AppTheme(
        id: "yellow", titleKey: "theme_yellow", primary: Color(hex: 0xFFD60A), onPrimary: Color(hex: 0x141414), background: Color(hex: 0x0E0E0C),
        surface: Color(hex: 0x1F1E1A), textPrimary: Color(hex: 0xF5F2E7), textMuted: Color(hex: 0xA6A28E), chatBackground: Color(hex: 0x0A0A08),
        bubbleMine: Color(hex: 0xFFD60A), onBubbleMine: Color(hex: 0x141414), sentTick: Color(hex: 0x6B5A00), isDark: true
    )

    static let green = AppTheme(
        id: "green", titleKey: "theme_green", primary: Color(hex: 0x3DDC97), onPrimary: Color(hex: 0x062A1C), background: Color(hex: 0x0F1D18),
        surface: Color(hex: 0x1A2E26), textPrimary: Color(hex: 0xE7F5EE), textMuted: Color(hex: 0x8DB3A3), chatBackground: Color(hex: 0x0B1712),
        bubbleMine: Color(hex: 0x1E7A54), onBubbleMine: .white, sentTick: Color(hex: 0x9EF0C8), isDark: true
    )

    static let all: [AppTheme] = [black, white, yellow, navy, green]

    static func byId(_ id: String) -> AppTheme { all.first { $0.id == id } ?? navy }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
