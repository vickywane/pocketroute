import SwiftUI

/// Only real choices live here: account, which city's map, whether it updates
/// itself, step-free routing, which models read messages, and the TfL data credit.
struct SettingsView: View {
    let graph: NetworkGraph
    @Environment(DatasetStore.self) private var store
    @AppStorage(Preference.keepMapUpdated) private var keepMapUpdated = true
    @AppStorage(Preference.stepFree) private var stepFree = false
    @AppStorage(Preference.cloudAssist) private var cloudAssist = false
    @State private var accountIntent: String?
    @State private var showingCityPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    MenuButton().padding(.leading, -10)
                    Text("Settings").font(Typography.title1).tracking(Typography.title1Tracking).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }

                Button { accountIntent = "Sign in" } label: {
                    SettingsRow(icon: "person.crop.circle", title: "Sign in") { chevron }
                }
                .buttonStyle(.plain)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

                SettingsSection(title: "Map") {
                    Button { showingCityPicker = true } label: {
                        SettingsRow(icon: "map", title: "City", subtitle: citySubtitle) {
                            if store.isDownloading { ProgressView() } else { chevron }
                        }
                    }
                    .buttonStyle(.plain)
                    InsetDivider(leading: 64)
                    SettingsRow(icon: "arrow.clockwise", title: "Update map automatically") {
                        Toggle("Update map automatically", isOn: $keepMapUpdated).labelsHidden().tint(Theme.accent)
                    }
                }

                SettingsSection(title: "Routes") {
                    SettingsRow(icon: "figure.roll", title: "Step-free changes only") {
                        Toggle("Step-free changes only", isOn: $stepFree).labelsHidden().tint(Theme.accent)
                    }
                }

                SettingsSection(title: "Assistant") {
                    SettingsRow(icon: "iphone", title: "Apple Intelligence", subtitle: AssistantAvailability.current.title) { EmptyView() }
                    if CloudAssist.isConfigured {
                        InsetDivider(leading: 64)
                        SettingsRow(icon: "sparkles", title: "Use Gemini when online") {
                            Toggle("Use Gemini when online", isOn: $cloudAssist).labelsHidden().tint(Theme.accent)
                        }
                    }
                }

                SettingsSection(title: "About") {
                    SettingsRow(icon: "info.circle", title: "Map data & licences",
                                subtitle: "TfL Open Data · Open Government Licence v3.0") { EmptyView() }
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28)
        }
        .background(Theme.canvas)
        .sheet(item: Binding(get: { accountIntent.map(IdentifiedString.init) }, set: { accountIntent = $0?.value })) { AccountSheet(intent: $0.value) }
        .sheet(isPresented: $showingCityPicker) { CityPickerSheet() }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondary)
    }

    /// "London · saved 17 Nov", or the last update error.
    private var citySubtitle: String {
        if let error = store.lastError { return error }
        let city = store.selectedTitle.split(separator: ",").first.map(String.init) ?? store.selectedTitle
        let date = graph.generatedAt?.formatted(.dateTime.day().month(.abbreviated)) ?? graph.version
        return "\(city) · saved \(date)"
    }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}
