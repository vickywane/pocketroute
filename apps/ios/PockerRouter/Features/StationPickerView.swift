import CoreLocation
import SwiftUI

/// "Where are you?" / "Where are you going?" over every station in the loaded map.
struct StationPickerView: View {
    enum Mode: String, Identifiable {
        case origin, destination
        var id: String { rawValue }
    }

    let graph: NetworkGraph
    let mode: Mode
    /// Called after a station is chosen, so the caller can move on (e.g. ask "Going to" next).
    var onPick: (Mode) -> Void = { _ in }
    @Environment(RerouteSession.self) private var session
    @Environment(StationLocator.self) private var locator
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var pending: String?
    @State private var browseAll = false

    var body: some View {
        VStack(spacing: 12) {
            Text(mode == .origin ? "Where are you?" : "Where are you going?")
                .font(Typography.headline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search stations", text: $search).font(Typography.body)
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Theme.neutralSubtle, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(sectionTitle).font(Typography.footnote).foregroundStyle(Theme.secondary)
                    LazyVStack(spacing: 0) {
                        ForEach(visibleStations) { station in row(station) }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    if search.isEmpty && !browseAll {
                        Button { browseAll = true } label: {
                            Text("Browse all \(graph.stationCount) stations  ›").font(Typography.subheadMedium)
                                .foregroundStyle(Theme.accentText)
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Theme.canvas.ignoresSafeArea())
        // Half-screen, single-select: tap a station to choose it; tap outside or drag down to close.
        .presentationDetents([.fraction(0.7)])
        .presentationDragIndicator(.visible)
        .onAppear {
            pending = mode == .origin ? session.originId : session.destinationId
            if mode == .origin { locator.locate(prompt: true) }
        }
    }

    /// Stations along the passenger's line, or the nearest ones to the last fix.
    private var curated: [NetworkGraph.Station] {
        if mode == .origin, let line = session.onLine, let around = pending ?? session.originId {
            let order = graph.lineOrder(line: line, around: around)
            if let index = order.firstIndex(where: { $0.id == around }) {
                return Array(order[max(index - 4, 0)...min(index + 4, order.count - 1)])
            }
        }
        if let fix = locator.lastFix {
            return graph.stations.values.sorted { fix.distance(from: $0.location) < fix.distance(from: $1.location) }.prefix(8).map { $0 }
        }
        return []
    }

    private var visibleStations: [NetworkGraph.Station] {
        if !search.isEmpty {
            return graph.sortedStations.filter { $0.name.localizedStandardContains(search) }
        }
        if browseAll || curated.isEmpty { return graph.sortedStations }
        // Keep a station chosen through search visible after search closes.
        if let pending, let station = graph.stations[pending], !curated.contains(station) { return [station] + curated }
        return curated
    }

    private var sectionTitle: String {
        if !search.isEmpty || browseAll || curated.isEmpty { return "Stations" }
        if mode == .origin, let line = session.onLine { return "On your line · \(graph.lineName(line)) line" }
        return "Near your last known location"
    }

    private func row(_ station: NetworkGraph.Station) -> some View {
        let isSelected = station.id == pending
        return Button { choose(station.id) } label: {
            HStack(spacing: 12) {
                Circle().fill(isSelected ? Theme.accent : Theme.surface).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(isSelected ? Theme.accent : Theme.secondary, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name).foregroundStyle(Theme.ink)
                    if let subtitle = subtitle(station) {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark").foregroundStyle(Theme.accentText) }
            }
            .padding(.horizontal, 12).frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choose(_ id: String) {
        pending = id
        if mode == .origin { session.setOrigin(id, confirmed: true) } else { session.destinationId = id }
        dismiss()
        onPick(mode)
    }

    private func subtitle(_ station: NetworkGraph.Station) -> String? {
        if station.id == locator.suggestion?.id {
            return locator.fixAgeDescription.map { "Nearest to your \($0)" } ?? "Nearest to your location"
        }
        guard station.lineIds.count > 1 else { return nil }
        let names = station.lineIds.filter { $0 != session.onLine }.map(graph.lineName)
        if session.onLine == nil { return "\(names.joined(separator: ", ")) lines" }
        return names.count == 1 ? "Change for the \(names[0]) line" : "Change for \(names.joined(separator: ", ")) lines"
    }
}
