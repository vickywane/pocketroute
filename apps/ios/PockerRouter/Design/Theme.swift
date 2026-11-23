import SwiftUI
import UIKit

/// Type scale, matching the Figma "PocketRoute/…" text styles (SF Pro).
/// One headline per screen; station names stand out by weight, not size.
enum Typography {
    static let title1 = Font.system(size: 24, weight: .semibold)     // screen headlines, page titles, journey minutes
    static let title1Tracking: CGFloat = -0.3
    static let title2 = Font.system(size: 20, weight: .semibold)     // menu and sheet titles, guidance instruction
    static let headline = Font.system(size: 17, weight: .semibold)   // station names, section heads, buttons, nav titles
    static let body = Font.system(size: 16)                          // running text, messages
    static let callout = Font.system(size: 15, weight: .medium)      // chips, list row titles
    static let calloutStrong = Font.system(size: 15, weight: .semibold)
    static let subhead = Font.system(size: 13)                       // field labels, supporting details
    static let subheadMedium = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 13, weight: .semibold)    // line tags, small emphasis
    static let footnote = Font.system(size: 12)                      // hints and source notes
    static let tabLabel = Font.system(size: 12, weight: .semibold)   // tab bar
}

/// Semantic colours from `opendesigner/tokens/semantic.color.{light,dark}.tokens.json`.
/// Views use these roles, never raw RGB values, so light and dark mode both work.
enum Theme {
    static let canvas = dynamic(light: 0xF1F4FA, dark: 0x141518)          // surface.sunken
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x22252B)         // surface.raised
    static let ink = dynamic(light: 0x222428, dark: 0xE6E9EE)             // text.primary
    static let secondary = dynamic(light: 0x505765, dark: 0xA3ABBB)       // text.secondary
    static let accent = dynamic(light: 0x0E5E58, dark: 0x4B9089)          // bg.accent.bold
    static let accentText = dynamic(light: 0x0D4B46, dark: 0x78B7B0)      // text.accent
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x141518)        // text.on-accent
    static let accentSubtle = dynamic(light: 0xE2EEEC, dark: 0x1E2928)    // bg.accent.subtle
    static let neutralSubtle = dynamic(light: 0xE8ECF3, dark: 0x32363F)   // bg.neutral.subtle
    static let line = dynamic(light: 0xD5DBE6, dark: 0x3A3F49)            // border.separator
    static let warningText = dynamic(light: 0x845D03, dark: 0xF8D191)     // text.warning
    static let warningSubtle = dynamic(light: 0xF3EADD, dark: 0x2D261B)   // bg.warning.subtle
    static let successText = dynamic(light: 0x1D6333, dark: 0x7EBA8A)     // text.success
    static let successSubtle = dynamic(light: 0xE1EFE3, dark: 0x1F2A21)   // bg.success.subtle
    static let dangerText = dynamic(light: 0x8D4039, dark: 0xE6988F)      // text.danger
    static let infoText = dynamic(light: 0x005C8A, dark: 0x70B3E1)        // text.info
    static let infoSubtle = dynamic(light: 0xDFEDF8, dark: 0x1C2932)      // bg.info.subtle
    static let inverse = dynamic(light: 0x222428, dark: 0xE6E9EE)         // bg.inverse
    static let onInverse = dynamic(light: 0xFFFFFF, dark: 0x141518)       // text.inverse

    /// Official TfL line colours (fixed in both modes, white text on top).
    static func lineColor(_ lineId: String?) -> Color {
        switch lineId {
        case "bakerloo": hex(0xB36305)
        case "central": hex(0xE32017)
        case "circle": hex(0xFFD300)
        case "district": hex(0x00782A)
        case "hammersmith-city": hex(0xF3A9BB)
        case "jubilee": hex(0xA0A5A9)
        case "metropolitan": hex(0x9B0056)
        case "northern": hex(0x000000)
        case "piccadilly": hex(0x003688)
        case "victoria": hex(0x0098D4)
        case "waterloo-city": hex(0x95CDBA)
        default: accent
        }
    }

    /// Lines whose brand colour needs dark text for contrast.
    static func lineTextColor(_ lineId: String?) -> Color {
        switch lineId {
        case "circle", "hammersmith-city", "jubilee", "waterloo-city": hex(0x000000)
        case nil: onAccent
        default: .white
        }
    }

    private static func hex(_ value: UInt32) -> Color { Color(uiColor: uiColor(value)) }

    private static func uiColor(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let lightColor = uiColor(light), darkColor = uiColor(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }
}
