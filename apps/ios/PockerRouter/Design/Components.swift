import SwiftUI

struct IconCircle: View {
    let systemName: String
    var size: CGFloat = 40
    var tint: Color = Theme.accentText
    var background: Color = Theme.accentSubtle

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(background, in: Circle())
            .accessibilityHidden(true)
    }
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var prominent = true
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(Typography.headline)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.accentText)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(prominent ? Theme.accent : Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct LineTag: View {
    let lineId: String?
    let name: String

    var body: some View {
        Text(name)
            .font(Typography.caption)
            .foregroundStyle(Theme.lineTextColor(lineId))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.lineColor(lineId), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Online/offline state plus the saved map date.
/// Mobile top nav header: centered title, 44pt leading and trailing slots,
/// hairline underneath.
struct TopNavHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            leading.frame(width: 44, height: 44)
            Spacer(minLength: 4)
            Text(title).font(Typography.headline).foregroundStyle(Theme.ink).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 0.5) }
    }
}

extension TopNavHeader where Leading == Color {
    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, leading: { Color.clear }, trailing: trailing)
    }
}

extension TopNavHeader where Trailing == Color {
    init(title: String, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, leading: leading, trailing: { Color.clear })
    }
}

/// ☰ button that opens the side menu. Used in the Re-route header and next
/// to the Saved and Settings titles.
struct MenuButton: View {
    @Environment(RerouteSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9)) { session.showingMenu = true }
        } label: {
            Image(systemName: "line.3.horizontal").font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.ink).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open menu")
    }
}

/// Round wifi / wifi-off button on the right of the Re-route header. Opens
/// the sheet that explains what works offline.
struct ConnectivityButton: View {
    let isOnline: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOnline ? "wifi" : "wifi.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isOnline ? Theme.successText : Theme.warningText)
                .frame(width: 44, height: 44)
                .background(Theme.canvas, in: Circle())
                .overlay(Circle().stroke(Theme.accent, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOnline ? "Online. Show details" : "You’re offline. Show details")
    }
}

enum MapDate {
    static func savedText(_ date: Date?) -> String {
        guard let date else { return "Tube map saved" }
        return "Tube map from \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    static func bytes(_ count: Int?) -> String {
        guard let count else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

struct Bubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 50) }
            Text(text)
                .font(Typography.body).lineSpacing(3)
                .foregroundStyle(isUser ? Theme.onAccent : Theme.ink)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(isUser ? Theme.accent : Theme.neutralSubtle, in: RoundedRectangle(cornerRadius: 16))
            if !isUser { Spacer(minLength: 0) }
        }
    }
}

struct AssistantBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            IconCircle(systemName: "sparkles", size: 24).font(.system(size: 12))
            Bubble(text: text, isUser: false)
        }
    }
}

/// Typing dots while the assistant reads a message.
struct ThinkingBubble: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            IconCircle(systemName: "sparkles", size: 24).font(.system(size: 12))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading that against the saved map…").font(Typography.callout).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Theme.neutralSubtle, in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working out a reply")
    }
}

/// What the assistant took from a message, so a wrong reading is easy to spot.
struct UnderstoodRow: View {
    let tags: [String]
    let by: UnderstoodBy?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !tags.isEmpty {
                FlowTags(tags: tags)
            }
            if let by {
                Label(tags.isEmpty ? "\(by.rawValue) · nothing to change" : by.rawValue,
                      systemImage: by == .onDevice ? "sparkles" : "text.magnifyingglass")
                    .font(Typography.footnote).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

private struct FlowTags: View {
    let tags: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(tags, id: \.self, content: tag) }
            VStack(alignment: .trailing, spacing: 6) { ForEach(tags, id: \.self, content: tag) }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(Typography.subheadMedium).foregroundStyle(Theme.accentText)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accentSubtle, in: Capsule())
    }
}

struct RouteCard: View {
    let plan: RoutePlan
    let graph: NetworkGraph

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(RouteText.title(plan, graph: graph)).font(Typography.headline).foregroundStyle(Theme.ink)
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(plan.minutes)").font(Typography.title1).foregroundStyle(Theme.ink)
                    Text("min").font(Typography.subhead).foregroundStyle(Theme.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 8)
            }
            HStack(spacing: 6) {
                if plan.isWalkOnly {
                    LineTag(lineId: nil, name: "Walk")
                } else {
                    ForEach(Array(plan.rideLegs.enumerated()), id: \.offset) { _, leg in
                        LineTag(lineId: leg.lineId, name: graph.lineName(leg.lineId ?? ""))
                    }
                }
                if let badge = plan.badge {
                    Text(badge.rawValue).font(Typography.caption).foregroundStyle(Theme.successText)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.successSubtle, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            Text(RouteText.detail(plan, graph: graph)).font(Typography.subhead).foregroundStyle(Theme.secondary)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(plan.badge == .fastest ? Theme.accent : Theme.line, lineWidth: plan.badge == .fastest ? 2 : 1))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Starts step-by-step guidance")
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typography.caption).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) { content }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            IconCircle(systemName: icon).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.callout).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(Typography.footnote).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            accessory
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 56)
    }
}

struct InsetDivider: View {
    var leading: CGFloat = 64
    var body: some View { Divider().overlay(Theme.line).padding(.leading, leading) }
}

/// User preferences shared across screens.
enum Preference {
    static let onboardingComplete = "pocketroute.onboarding.complete"
    static let keepMapUpdated = "pocketroute.prefs.keepMapUpdated"
    static let stepFree = "pocketroute.prefs.stepFree"
}
