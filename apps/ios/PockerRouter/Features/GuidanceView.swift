import SwiftUI

/// One large instruction at a time, built from the chosen plan's legs.
struct GuidanceView: View {
    let graph: NetworkGraph
    @Environment(RerouteSession.self) private var session
    @AppStorage(Preference.stepFree) private var stepFree = false

    var body: some View {
        if let plan = session.selectedPlan, !plan.legs.isEmpty {
            content(plan)
        }
    }

    private func content(_ plan: RoutePlan) -> some View {
        let index = min(session.stepIndex, plan.legs.count - 1)
        let leg = plan.legs[index]
        let isLast = index == plan.legs.count - 1
        let destination = graph.stations[plan.legs.last?.stops.last ?? ""]?.name ?? ""
        let remaining = plan.minutes - Int(plan.legs[..<index].reduce(0) { $0 + $1.minutes }.rounded())

        return VStack(spacing: 0) {
            HStack {
                Button("Close") { session.screen = .conversation }
                Spacer()
                Text("To \(destination)").font(Typography.caption).foregroundStyle(Theme.ink)
                Spacer()
                Button("Ask") { session.screen = .conversation }
            }
            .font(Typography.subhead).foregroundStyle(Theme.accentText).padding(.horizontal, 20).frame(height: 52)

            HStack {
                Text("Step \(index + 1) of \(plan.legs.count)").font(Typography.caption).foregroundStyle(Theme.ink)
                Spacer()
                Text("About \(max(remaining, 1)) min to go").font(Typography.footnote).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 12)
            HStack(spacing: 6) {
                ForEach(0..<plan.legs.count, id: \.self) { step in
                    Capsule().fill(step <= index ? Theme.accent : Theme.line).frame(height: 4)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14) {
                IconCircle(systemName: leg.lineId == nil ? "figure.walk" : (index == 0 ? "tram.fill" : "arrow.left.arrow.right"),
                           tint: Theme.lineTextColor(leg.lineId), background: Theme.lineColor(leg.lineId))
                    .font(.system(size: 19, weight: .semibold))
                Text(instruction(leg, index: index, plan: plan))
                    .font(Typography.title2).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                Text(RouteText.legDetail(leg, graph: graph)).font(Typography.body).foregroundStyle(Theme.secondary)
                if leg.lineId != nil, leg.stops.count > 2 {
                    Text("Calls at \(leg.stops.dropFirst().dropLast().compactMap { graph.stations[$0]?.name }.joined(separator: ", "))")
                        .font(Typography.subhead).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20).padding(.top, 24)

            if !isLast {
                let next = plan.legs[index + 1]
                HStack(spacing: 10) {
                    Text("\(index + 2)").font(Typography.caption).foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28).background(Theme.canvas, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next: \(instruction(next, index: index + 1, plan: plan))").font(Typography.subheadMedium).foregroundStyle(Theme.ink)
                        Text(RouteText.legDetail(next, graph: graph)).font(Typography.footnote).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20).padding(.top, 14)
            }

            Spacer(minLength: 12)
            VStack(spacing: 6) {
                PrimaryButton(title: primaryTitle(leg, isLast: isLast)) {
                    if isLast { session.finishJourney() } else { session.stepIndex = index + 1 }
                }
                Button {
                    session.rerouteFromCurrentStep(graph: graph, stepFree: stepFree, walking: true)
                } label: {
                    Label("Something’s wrong — find another way", systemImage: "arrow.clockwise")
                        .font(Typography.subheadMedium).foregroundStyle(Theme.dangerText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .background(Theme.canvas)
    }

    private func instruction(_ leg: RouteLeg, index: Int, plan: RoutePlan) -> String {
        RouteText.instruction(for: leg, index: index, in: plan, onLine: session.request?.onLine,
                              trainStuck: session.request?.trainStuck ?? false, graph: graph)
    }

    private func primaryTitle(_ leg: RouteLeg, isLast: Bool) -> String {
        if isLast { return "Arrived · Finish" }
        if let line = leg.lineId { return "I’m off at \(graph.stations[leg.stops.last ?? ""]?.name ?? graph.lineName(line))" }
        return "I’m there"
    }
}
