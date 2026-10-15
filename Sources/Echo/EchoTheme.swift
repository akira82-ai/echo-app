import SwiftUI

enum EchoTheme {
    struct Palette {
        var windowBackground: Color
        let windowTint: Color
        let titleBarBackground: Color
        var border: Color
        var borderStrong: Color
        var textPrimary: Color
        var textSecondary: Color
        var textTertiary: Color
        var accent: Color
        var accentSoft: Color
        let green: Color
        let greenSoft: Color
        let yellow: Color
        let yellowSoft: Color
        let purple: Color
        let purpleSoft: Color
        let red: Color
        let redSoft: Color
        let chipBackground: Color
        let chipText: Color
        let rowBackground: Color
        let thumbnailBackground: Color
        let footerBackground: Color
        let keycapBackground: Color
        let keycapText: Color
        let controlBackground: Color
        let controlBorder: Color
        let achievementLockedBackground: Color
        let achievementLockedIconBackground: Color
    }

    /// Fixed panel colors from the approved compact HTML; settings retain their existing palette.
    static func panelPalette(for scheme: ColorScheme) -> Palette {
        var result = palette(for: scheme)
        func rgb(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
        }
        let dark = scheme == .dark
        result.windowBackground = rgb(dark ? 0x292d31 : 0xf6f7f7)
        result.textPrimary = rgb(dark ? 0xe4e7e8 : 0x303a41)
        result.textSecondary = rgb(dark ? 0xc1ccd3 : 0x516471)
        result.textTertiary = rgb(dark ? 0x88949c : 0x76848e)
        result.accent = rgb(dark ? 0xabcce4 : 0x638aaa)
        result.accentSoft = rgb(dark ? 0x8db6d5 : 0x547e9f).opacity(dark ? 0.17 : 0.106)
        result.border = (dark ? Color.white : Color.black).opacity(0.045)
        result.borderStrong = (dark ? Color.white : Color.black).opacity(dark ? 0.13 : 0.07)
        return result
    }

    static func palette(for colorScheme: ColorScheme) -> Palette {
        switch colorScheme {
        case .dark:
            return Palette(
                windowBackground: Color(red: 30.0 / 255.0, green: 33.0 / 255.0, blue: 42.0 / 255.0).opacity(0.92),
                windowTint: Color(red: 30.0 / 255.0, green: 33.0 / 255.0, blue: 42.0 / 255.0).opacity(0.22),
                titleBarBackground: Color.black.opacity(0.25),
                border: Color.white.opacity(0.08),
                borderStrong: Color.white.opacity(0.16),
                textPrimary: Color(red: 232.0 / 255.0, green: 234.0 / 255.0, blue: 240.0 / 255.0),
                textSecondary: Color(red: 154.0 / 255.0, green: 163.0 / 255.0, blue: 178.0 / 255.0),
                textTertiary: Color(red: 107.0 / 255.0, green: 115.0 / 255.0, blue: 133.0 / 255.0),
                accent: Color(red: 74.0 / 255.0, green: 168.0 / 255.0, blue: 255.0 / 255.0),
                accentSoft: Color(red: 74.0 / 255.0, green: 168.0 / 255.0, blue: 255.0 / 255.0).opacity(0.14),
                green: Color(red: 52.0 / 255.0, green: 211.0 / 255.0, blue: 153.0 / 255.0),
                greenSoft: Color(red: 52.0 / 255.0, green: 211.0 / 255.0, blue: 153.0 / 255.0).opacity(0.14),
                yellow: Color(red: 251.0 / 255.0, green: 191.0 / 255.0, blue: 36.0 / 255.0),
                yellowSoft: Color(red: 251.0 / 255.0, green: 191.0 / 255.0, blue: 36.0 / 255.0).opacity(0.14),
                purple: Color(red: 167.0 / 255.0, green: 139.0 / 255.0, blue: 250.0 / 255.0),
                purpleSoft: Color(red: 167.0 / 255.0, green: 139.0 / 255.0, blue: 250.0 / 255.0).opacity(0.14),
                red: Color(red: 248.0 / 255.0, green: 113.0 / 255.0, blue: 113.0 / 255.0),
                redSoft: Color(red: 248.0 / 255.0, green: 113.0 / 255.0, blue: 113.0 / 255.0).opacity(0.14),
                chipBackground: Color.black.opacity(0.3),
                chipText: Color(red: 107.0 / 255.0, green: 115.0 / 255.0, blue: 133.0 / 255.0),
                rowBackground: Color.black.opacity(0.2),
                thumbnailBackground: Color(red: 42.0 / 255.0, green: 47.0 / 255.0, blue: 61.0 / 255.0),
                footerBackground: Color.black.opacity(0.15),
                keycapBackground: Color(red: 28.0 / 255.0, green: 32.0 / 255.0, blue: 42.0 / 255.0),
                keycapText: Color(red: 154.0 / 255.0, green: 163.0 / 255.0, blue: 178.0 / 255.0),
                controlBackground: Color.black.opacity(0.2),
                controlBorder: Color.white.opacity(0.08),
                achievementLockedBackground: Color.black.opacity(0.08),
                achievementLockedIconBackground: Color.white.opacity(0.04)
            )
        default:
            return Palette(
                windowBackground: Color(red: 252.0 / 255.0, green: 252.0 / 255.0, blue: 253.0 / 255.0).opacity(0.96),
                windowTint: Color.white.opacity(0.5),
                titleBarBackground: Color(red: 247.0 / 255.0, green: 249.0 / 255.0, blue: 252.0 / 255.0),
                border: Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.08),
                borderStrong: Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.14),
                textPrimary: Color(red: 31.0 / 255.0, green: 41.0 / 255.0, blue: 55.0 / 255.0),
                textSecondary: Color(red: 75.0 / 255.0, green: 85.0 / 255.0, blue: 99.0 / 255.0),
                textTertiary: Color(red: 107.0 / 255.0, green: 114.0 / 255.0, blue: 128.0 / 255.0),
                accent: Color(red: 59.0 / 255.0, green: 130.0 / 255.0, blue: 246.0 / 255.0),
                accentSoft: Color(red: 59.0 / 255.0, green: 130.0 / 255.0, blue: 246.0 / 255.0).opacity(0.10),
                green: Color(red: 5.0 / 255.0, green: 150.0 / 255.0, blue: 105.0 / 255.0),
                greenSoft: Color(red: 5.0 / 255.0, green: 150.0 / 255.0, blue: 105.0 / 255.0).opacity(0.12),
                yellow: Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0),
                yellowSoft: Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0).opacity(0.10),
                purple: Color(red: 139.0 / 255.0, green: 92.0 / 255.0, blue: 246.0 / 255.0),
                purpleSoft: Color(red: 139.0 / 255.0, green: 92.0 / 255.0, blue: 246.0 / 255.0).opacity(0.10),
                red: Color(red: 239.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0),
                redSoft: Color(red: 239.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0).opacity(0.10),
                chipBackground: Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.06),
                chipText: Color(red: 107.0 / 255.0, green: 114.0 / 255.0, blue: 128.0 / 255.0),
                rowBackground: Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.035),
                thumbnailBackground: Color(red: 238.0 / 255.0, green: 241.0 / 255.0, blue: 246.0 / 255.0),
                footerBackground: Color(red: 247.0 / 255.0, green: 248.0 / 255.0, blue: 250.0 / 255.0).opacity(0.92),
                keycapBackground: Color(red: 230.0 / 255.0, green: 233.0 / 255.0, blue: 238.0 / 255.0),
                keycapText: Color(red: 47.0 / 255.0, green: 54.0 / 255.0, blue: 66.0 / 255.0),
                controlBackground: Color.white.opacity(0.78),
                controlBorder: Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.08),
                achievementLockedBackground: Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.018),
                achievementLockedIconBackground: Color.white.opacity(0.04)
            )
        }
    }
}
