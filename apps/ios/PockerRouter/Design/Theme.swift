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

/// Semantic colours from `opendesigner/tokens/semantic.color.light.tokens.json`.
/// The app is light only; views use these roles, never raw RGB values.
enum Theme {
    static let canvas = hex(0xF1F4FA)          // surface.sunken
    static let surface = hex(0xFFFFFF)         // surface.raised
    static let ink = hex(0x222428)             // text.primary
    static let secondary = hex(0x505765)       // text.secondary
    static let accent = hex(0x0E5E58)          // bg.accent.bold
    static let accentText = hex(0x0D4B46)      // text.accent
    static let onAccent = hex(0xFFFFFF)        // text.on-accent
    static let accentSubtle = hex(0xE2EEEC)    // bg.accent.subtle
    static let neutralSubtle = hex(0xE8ECF3)   // bg.neutral.subtle
    static let line = hex(0xD5DBE6)            // border.separator
    static let warningText = hex(0x845D03)     // text.warning
    static let warningSubtle = hex(0xF3EADD)   // bg.warning.subtle
    static let successText = hex(0x1D6333)     // text.success
    static let successSubtle = hex(0xE1EFE3)   // bg.success.subtle
    static let dangerText = hex(0x8D4039)      // text.danger
    static let infoText = hex(0x005C8A)        // text.info
    static let infoSubtle = hex(0xDFEDF8)      // bg.info.subtle
    static let inverse = hex(0x222428)         // bg.inverse
    static let onInverse = hex(0xFFFFFF)       // text.inverse

    /// Official TfL line colours (white text on top).
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
}
