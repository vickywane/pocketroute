import SwiftUI

/// "Train stopped?" — where you are, where you're going, what happened.
struct CaptureView: View {
    let graph: NetworkGraph
    @Environment(RerouteSession.self) private var session
    @Environment(StationLocator.self) private var locator
    @Environment(Connectivity.self) private var connectivity
    @State private var picker: StationPickerView.Mode?
    @State private var showingOfflineInfo = false
    @State private var askDestinationNext = false
    @AppStorage(Preference.stepFree) private var stepFree = false

    var body: some View {
        VStack(spacing: 0) {
            TopNavHeader(title: "Re-route", leading: { MenuButton() }, trailing: {
                ConnectivityButton(isOnline: connectivity.isOnline) { showingOfflineInfo = true }
            })
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Train stopped?")
                        Text("Let’s find another way.")
                    }
                    .font(Typography.title1).tracking(Typography.title1Tracking).foregroundStyle(Theme.ink)

                    VStack(spacing: 0) {
                        stationRow(label: "I’m at", id: session.originId, placeholder: "Choose your station", icon: "location.fill",
                                   hint: originHint) { picker = .origin }
                        InsetDivider(leading: 72)
                        stationRow(label: "Going to", id: session.destinationId, placeholder: "Choose where you’re going", icon: "flag.fill",
                                   hint: nil) { picker = .destination }
                        InsetDivider(leading: 72)
                        lineRow
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

                    Text("What happened?").font(Typography.headline).foregroundStyle(Theme.ink)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(Situation.allCases) { situationChip($0) } }
                    }

                    // The way forward once both stations are known.
                    if session.canSearch {
                        PrimaryButton(title: "Show routes") {
                            session.tab = 0
                            session.openAssistant(graph: graph, stepFree: stepFree, walking: true)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            }
        }
        // Choosing "I'm at" moves straight on to "Going to" when that's still empty.
        .sheet(item: $picker, onDismiss: {
            if askDestinationNext { askDestinationNext = false; picker = .destination }
        }) { mode in
            StationPickerView(graph: graph, mode: mode) { picked in
                askDestinationNext = picked == .origin && session.destinationId == nil
            }
        }
        .sheet(isPresented: $showingOfflineInfo) { OfflineInfoSheet(graph: graph) }
    }

    private var originHint: String? {
        guard let originId = session.originId else { return locator.message }
        if !session.originConfirmed, locator.suggestion?.id == originId { return "Nearest station to your location · tap to change" }
        return nil
    }

    private func stationRow(label: String, id: String?, placeholder: String, icon: String, hint: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                IconCircle(systemName: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Typography.subhead).foregroundStyle(Theme.secondary)
                    Text(id.flatMap { graph.stations[$0]?.name } ?? placeholder)
                        .font(Typography.headline)
                        .foregroundStyle(id == nil ? Theme.secondary : Theme.ink)
                    if let hint { Text(hint).font(Typography.footnote).foregroundStyle(Theme.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            .padding(16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var lineRow: some View {
        @Bindable var session = session
        let lines = session.originId.flatMap { graph.stations[$0]?.lineIds } ?? []
        return Menu {
            Picker("I was on", selection: $session.onLine) {
                Text("Not on a train").tag(String?.none)
                ForEach(lines, id: \.self) { Text("\(graph.lineName($0)) line").tag(Optional($0)) }
            }
        } label: {
            HStack(spacing: 16) {
                IconCircle(systemName: "tram.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("I was on").font(Typography.subhead).foregroundStyle(Theme.secondary)
                    if let onLine = session.onLine {
                        LineTag(lineId: onLine, name: graph.lineName(onLine))
                    } else {
                        Text(lines.isEmpty ? "Choose your station first" : "Not on a train")
                            .font(Typography.body).foregroundStyle(Theme.ink)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.secondary)
            }
            .padding(16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lines.isEmpty)
    }

    private func situationChip(_ situation: Situation) -> some View {
        let selected = session.situations.contains(situation)
        return Button {
            if selected { session.situations.remove(situation) } else { session.situations.insert(situation) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark" : situation.icon)
                Text(situation.rawValue).font(Typography.callout).fixedSize()
            }
            .foregroundStyle(selected ? Theme.accentText : Theme.ink)
            .frame(height: 52).padding(.horizontal, 16)
            .background(selected ? Theme.accentSubtle : Theme.surface, in: Capsule())
            // strokeBorder draws inside the shape, so the scroll view can't clip it.
            .overlay(Capsule().strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
