import SwiftUI

/// Past re-routes, newest first. Tap one to open it again.
struct HistoryView: View {
    let graph: NetworkGraph
    @Environment(RerouteSession.self) private var session
    @AppStorage(Preference.stepFree) private var stepFree = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    MenuButton().padding(.leading, -10)
                    Text("History").font(Typography.title1).tracking(Typography.title1Tracking).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                if session.recents.isEmpty {
                    Text("No trips yet").font(Typography.body).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(session.recents.enumerated()), id: \.element.id) { index, recent in
                            if index > 0 { InsetDivider() }
                            recentRow(recent)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28)
        }
        .background(Theme.canvas)
    }

    private func recentRow(_ recent: RecentReroute) -> some View {
        let origin = graph.stations[recent.originId]?.name
        let destination = graph.stations[recent.destinationId]?.name
        return Button {
            session.reopen(recent, graph: graph, stepFree: stepFree, walking: true)
        } label: {
            HStack(spacing: 12) {
                IconCircle(systemName: "clock", size: 36, tint: Theme.secondary, background: Theme.neutralSubtle).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(origin ?? "Unknown station") → \(destination ?? "Unknown station")")
                        .font(Typography.subheadMedium).foregroundStyle(Theme.ink)
                    Text("\(recent.date.formatted(.relative(presentation: .named))) · \(recent.summary)")
                        .font(Typography.footnote).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 62).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(origin == nil || destination == nil)
    }
}
