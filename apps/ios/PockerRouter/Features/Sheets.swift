import SwiftUI

/// Records a short on-device dictation. Swiping it away discards the recording.
struct VoiceSheet: View {
    let onDone: (String) -> Void
    @Environment(VoiceCapture.self) private var voice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(voice.isRecording ? "Listening…" : "Voice input", systemImage: voice.isRecording ? "waveform" : "mic")
                    .font(Typography.calloutStrong).foregroundStyle(Theme.ink)
                Spacer()
            }
            Text(displayText)
                .font(Typography.callout).lineSpacing(3)
                .foregroundStyle(voice.errorMessage != nil && voice.transcript.isEmpty ? Theme.dangerText : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .topLeading).frame(minHeight: 54, alignment: .topLeading)
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array([8.0, 14, 22, 30, 18, 34, 26, 16, 28, 36, 20, 12, 24, 30, 14, 8].enumerated()), id: \.offset) { _, height in
                    Capsule().fill(Theme.accent.opacity(voice.isRecording ? 0.9 : 0.35)).frame(width: 3, height: height)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 38)
            .accessibilityHidden(true)
            Label("Speech is turned into text on this iPhone. Nothing leaves your phone.", systemImage: "lock")
                .font(Typography.footnote).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Text("Cancel").font(Typography.calloutStrong).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 48).background(Theme.neutralSubtle, in: RoundedRectangle(cornerRadius: 10))
                }
                Button {
                    voice.finish()
                    let text = voice.transcript
                    dismiss()
                    if !text.isEmpty { onDone(text) }
                } label: {
                    Text("Done").font(Typography.calloutStrong).foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 48).background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(voice.transcript.isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
        .background(Theme.canvas.ignoresSafeArea())
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(22)
        .task { await voice.begin() }
    }

    private var displayText: String {
        if !voice.transcript.isEmpty { return voice.transcript }
        if let error = voice.errorMessage { return error }
        return voice.isRecording ? "Say what happened on your journey…" : "Starting…"
    }
}

/// What works offline right now, based on real app state.
struct OfflineInfoSheet: View {
    let graph: NetworkGraph
    @Environment(Connectivity.self) private var connectivity
    @Environment(StationLocator.self) private var locator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconCircle(systemName: connectivity.isOnline ? "wifi" : "wifi.slash", size: 42,
                           tint: connectivity.isOnline ? Theme.successText : Theme.warningText,
                           background: connectivity.isOnline ? Theme.successSubtle : Theme.warningSubtle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connectivity.isOnline ? "You’re online" : "You’re offline").font(Typography.headline).foregroundStyle(Theme.ink)
                    Text(locator.suggestion.map { "Last known station · \($0.name)" } ?? "No recent location").font(Typography.footnote).foregroundStyle(Theme.secondary)
                }
            }
            Text("Re-routing never needs a signal. Here’s what works on this iPhone:").font(Typography.subhead).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) {
                feature("Re-routing", detail: "\(graph.stationCount) stations saved · map from \(graph.generatedAt?.formatted(date: .abbreviated, time: .omitted) ?? graph.version)", available: true)
                feature("Voice", detail: "Speech recognition on this iPhone, when supported", available: true)
                feature("AI understanding", detail: AssistantAvailability.current == .onDevice ? "Apple Intelligence on this iPhone, no signal needed"
                                                    : "Keywords and quick replies; \(AssistantAvailability.current.title.lowercased())",
                        available: AssistantAvailability.current == .onDevice)
                feature("Live service updates", detail: "Not available. Tell the app what’s wrong instead", available: false)
                feature("Account sync", detail: "Not connected in this version", available: false, last: true)
            }
            .background(Theme.neutralSubtle, in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 20)
        .background(Theme.canvas.ignoresSafeArea())
        .presentationDetents([.fraction(0.55)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(22)
    }

    private func feature(_ title: String, detail: String, available: Bool, last: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: available ? "checkmark" : "xmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(available ? Theme.successText : Theme.secondary)
                .frame(width: 18, height: 18)
                .background(available ? Theme.successSubtle : Theme.surface, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.caption).foregroundStyle(Theme.ink)
                Text(detail).font(Typography.footnote).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(minHeight: 46)
        .overlay(alignment: .bottom) { if !last { Theme.line.frame(height: 0.5) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(available ? "available" : "unavailable"). \(detail)")
    }
}

struct AccountSheet: View {
    let intent: String
    @Environment(\.dismiss) private var dismiss
    @State private var showingMessage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(intent).font(Typography.title1).tracking(Typography.title1Tracking).foregroundStyle(Theme.ink).padding(.top, 24)
            Text("Optional. Re-routing always works without an account.").font(Typography.body).foregroundStyle(Theme.secondary)
            PrimaryButton(title: "Continue with Apple", systemImage: "apple.logo") { showingMessage = true }
            PrimaryButton(title: "Continue with email", systemImage: "envelope", prominent: false) { showingMessage = true }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(Theme.canvas.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .alert("Accounts aren’t available yet", isPresented: $showingMessage) {
            Button("Got it", role: .cancel) { dismiss() }
        } message: {
            Text("Sign-in and backup aren’t connected in this version. Everything works as a guest.")
        }
    }
}

/// Real catalog entries from Hosting, plus cities that aren't published yet.
struct CityPickerSheet: View {
    @Environment(DatasetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let comingSoon = ["Paris · Métro", "New York · Subway"]

    var body: some View {
        VStack(spacing: 12) {
            Text("Choose your city").font(Typography.headline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.choices) { choice in
                        Button {
                            Task { await store.select(choice.id) }
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                IconCircle(systemName: "tram.fill")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(choice.title).font(Typography.headline).foregroundStyle(Theme.ink)
                                    if choice.id == store.selectedID, let graph = store.graph {
                                        Text("\(graph.stationCount) stations · \(MapDate.bytes(store.sizeBytes))").font(Typography.subhead).foregroundStyle(Theme.secondary)
                                    }
                                }
                                Spacer()
                                if choice.id == store.selectedID { Image(systemName: "checkmark").foregroundStyle(Theme.accentText) }
                            }
                            .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(comingSoon, id: \.self) { city in
                        HStack(spacing: 12) {
                            IconCircle(systemName: "tram.fill", tint: Theme.secondary, background: Theme.canvas)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(city).font(Typography.headline).foregroundStyle(Theme.ink)
                                Text("Coming soon").font(Typography.subheadMedium).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                        }
                        .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14)).opacity(0.55)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(city), coming soon")
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .presentationDetents([.fraction(0.5)])
        .presentationDragIndicator(.visible)
    }
}

/// Left side menu: the trip types PocketRoute supports. Only the Tube works
/// today; the rest are shown as coming soon and can't be selected.
struct SideMenu: View {
    var shadowOpacity: Double = 0.18
    let close: () -> Void
    @Environment(RerouteSession.self) private var session
    @Environment(DatasetStore.self) private var store

    private let comingSoon: [(title: String, icon: String)] = [
        ("For Trains", "lightrail"),
        ("For Water", "ferry"),
        ("For Camping", "tent"),
        ("For Hiking", "mountain.2"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Closed by tapping outside or the accessibility escape gesture.
            Text("PocketRoute").font(Typography.title2).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
                .frame(minHeight: 44)
                .padding(.bottom, 20)

            Button(action: openTube) {
                HStack(spacing: 12) {
                    IconCircle(systemName: "tram.fill", tint: Theme.onAccent, background: Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("For the Tube").font(Typography.headline).foregroundStyle(Theme.ink)
                        Text("\(cityName) · map saved").font(Typography.subhead).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isSelected)

            ForEach(comingSoon, id: \.title) { item in
                HStack(spacing: 12) {
                    IconCircle(systemName: item.icon, tint: Theme.secondary, background: Theme.neutralSubtle)
                    Text(item.title).font(Typography.body).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    Text("Coming soon").font(Typography.caption).foregroundStyle(Theme.secondary)
                }
                .padding(12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.title), coming soon")
                .accessibilityAddTraits(.isButton)
                .accessibilityRemoveTraits(.isSelected)
                .disabled(true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .frame(width: 316).frame(maxHeight: .infinity, alignment: .top)
        // Stays inside the safe area: never under the status bar or the home indicator.
        // Full height: the panel runs under the status bar and home indicator;
        // its content stays inside the safe area.
        .background {
            Rectangle().fill(Theme.canvas).shadow(color: .black.opacity(shadowOpacity), radius: 16, x: 4)
                .ignoresSafeArea()
        }
        .accessibilityAction(.escape, close)
    }

    /// "London, UK · London Underground" → "London".
    private var cityName: String {
        store.selectedTitle.split(separator: "·").first.map { String($0.split(separator: ",").first ?? $0) }?
            .trimmingCharacters(in: .whitespaces) ?? store.selectedTitle
    }

    private func openTube() {
        close()
        session.tab = 0
        session.screen = .capture
    }
}
