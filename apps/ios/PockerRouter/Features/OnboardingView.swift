import SwiftUI

struct OnboardingView: View {
    @Environment(DatasetStore.self) private var store
    @Environment(StationLocator.self) private var locator
    @Environment(Connectivity.self) private var connectivity
    @AppStorage(Preference.onboardingComplete) private var onboardingComplete = false
    @AppStorage(Preference.keepMapUpdated) private var keepMapUpdated = true
    @State private var step = 0
    @State private var downloading = false
    @State private var downloadFailed = false
    @State private var accountIntent: String?
    @State private var showingCityPicker = false

    var body: some View {
        Group {
            if step == 0 { welcome } else { setup }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .sheet(item: Binding(get: { accountIntent.map(IdentifiedString.init) }, set: { accountIntent = $0?.value })) { AccountSheet(intent: $0.value) }
        .sheet(isPresented: $showingCityPicker) { CityPickerSheet() }
        // When permission is granted on step 3, the fix arrives later; move on once asked.
        .onChange(of: locator.authorization) { _, _ in if step == 3 { step = 4 } }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        IconCircle(systemName: "point.topleft.down.to.point.bottomright.curvepath", size: 64, tint: Theme.onAccent, background: Theme.accent)
                            .font(.system(size: 28, weight: .semibold))
                        Text("When your travel plan breaks, find another way.")
                            .font(Typography.title1).tracking(Typography.title1Tracking).foregroundStyle(Theme.ink)
                        Text("Works deep underground with no signal. Your Tube map and voice input live on this iPhone.")
                            .font(Typography.body).lineSpacing(3).foregroundStyle(Theme.secondary)
                    }
                    VStack(spacing: 16) {
                        feature("map", title: "Saved Tube map", detail: "Every station, line and branch")
                        feature("list.number", title: "Step-by-step guidance", detail: "One instruction at a time, with a re-route button")
                        feature("mic", title: "Voice that works offline", detail: "Speak instead of typing on a busy train")
                    }
                }
                .padding(24).padding(.top, 24)
            }
            VStack(spacing: 12) {
                PrimaryButton(title: "Start as a guest") { step = 1 }
                PrimaryButton(title: "Create an account", prominent: false) { accountIntent = "Create your account" }
                HStack(spacing: 4) {
                    Text("Already have an account?").foregroundStyle(Theme.secondary)
                    Button("Sign in") { accountIntent = "Sign in" }.fontWeight(.semibold).foregroundStyle(Theme.accentText)
                }
                .font(Typography.body).frame(maxWidth: .infinity).padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 28)
        }
    }

    // MARK: - Setup steps

    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if step < 4 { progress } else {
                        Text("Set-up complete").font(Typography.caption).foregroundStyle(Theme.secondary)
                    }
                    switch step {
                    case 1: mapStep
                    case 2: voiceStep
                    case 3: locationStep
                    default: readyStep
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 24)
            }
            VStack(spacing: 8) {
                PrimaryButton(title: primaryTitle, enabled: !downloading, action: advance)
                if step < 4 {
                    Button(secondaryTitle) {
                        downloadFailed = false
                        step += 1
                    }
                    .font(Typography.callout).foregroundStyle(Theme.accentText).frame(maxWidth: .infinity, minHeight: 48)
                    .disabled(downloading)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
            .background(Theme.canvas)
        }
    }

    private var primaryTitle: String {
        switch step {
        case 1: downloading ? "Saving the Tube map…" : downloadFailed ? "Try again" : "Download latest map"
        case 2: "Continue"
        case 3: "Allow location"
        default: "Start using PocketRoute"
        }
    }

    private var secondaryTitle: String {
        switch step {
        case 1: "Use the map that came with the app"
        default: "Not now"
        }
    }

    private func advance() {
        switch step {
        case 1:
            downloading = true
            Task {
                let result = await store.refresh()
                downloading = false
                downloadFailed = result == .failed
                if !downloadFailed { step = 2 }
            }
        case 2: step = 3
        case 3:
            if locator.authorization == .notDetermined {
                locator.locate(prompt: true)
            } else {
                locator.locate(prompt: false)
                step = 4
            }
        default:
            onboardingComplete = true
        }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            Text("\(step) of 3").font(Typography.caption).foregroundStyle(Theme.secondary)
            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { index in Capsule().fill(index <= step ? Theme.accent : Theme.line).frame(height: 6) }
            }
            .accessibilityHidden(true)
            IconCircle(systemName: connectivity.isOnline ? "wifi" : "wifi.slash",
                       tint: connectivity.isOnline ? Theme.successText : Theme.warningText,
                       background: connectivity.isOnline ? Theme.successSubtle : Theme.warningSubtle)
                .accessibilityLabel(connectivity.isOnline ? "Online" : "Offline")
        }
    }

    private var mapStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(downloading ? "Saving the Tube map…" : downloadFailed ? "Download didn’t finish" : "Save the Tube map to this iPhone")
                .font(Typography.title1).tracking(Typography.title1Tracking).foregroundStyle(Theme.ink)
            Text(downloadFailed ? (store.lastError ?? "Couldn’t download the map.") + " The map that came with the app still works offline."
                 : "PocketRoute uses a map stored on your phone to find another way when you lose signal.")
                .font(Typography.body).lineSpacing(3).foregroundStyle(Theme.secondary)
            Button { showingCityPicker = true } label: {
                HStack(spacing: 12) {
                    IconCircle(systemName: "globe.europe.africa.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("City").font(Typography.subhead).foregroundStyle(Theme.secondary)
                        Text(store.selectedTitle).font(Typography.headline).foregroundStyle(Theme.ink)
                    }
                    Spacer()
                    Image(systemName: "chevron.down").foregroundStyle(Theme.secondary)
                }
                .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            VStack(spacing: 0) {
                row("tram.fill", title: "Every station, line and branch", detail: "\(store.graph?.stationCount ?? 0) stations · \(MapDate.bytes(store.sizeBytes))")
                InsetDivider(leading: 64)
                row("arrow.left.arrow.right", title: "Interchanges", detail: "Where you can change between lines")
                InsetDivider(leading: 64)
                Toggle(isOn: $keepMapUpdated) {
                    HStack(spacing: 12) {
                        IconCircle(systemName: "arrow.clockwise")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keep it up to date").font(Typography.headline).foregroundStyle(Theme.ink)
                            Text("Checks for a newer map when you open the app online").font(Typography.subhead).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                .tint(Theme.accent).padding(12).frame(minHeight: 70)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            if downloading { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Tell it what happened").font(Typography.title1).tracking(Typography.title1Tracking).foregroundStyle(Theme.ink)
            Text("Tap what happened, or say it. Voice is recognised on this iPhone, even when you’re offline.")
                .font(Typography.body).lineSpacing(3).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) {
                row("hand.tap", title: "One-tap situations", detail: "Train held, terminating, line closed, missed stop")
                InsetDivider(leading: 64)
                row("mic", title: "Voice input", detail: "Speech is recognised on this iPhone")
                InsetDivider(leading: 64)
                row("sparkles", title: "AI understanding", detail: "Not in this version yet. Quick replies work instead.")
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            IconCircle(systemName: "location.fill", size: 56).font(.system(size: 24))
            Text("Remember the last station you passed").font(Typography.title1).tracking(Typography.title1Tracking).foregroundStyle(Theme.ink)
            Text("GPS doesn’t work underground. With permission, PocketRoute remembers where your phone last had a fix and suggests the nearest station on your saved map.")
                .font(Typography.body).lineSpacing(3).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) {
                row("lock.fill", title: "Stays on this iPhone")
                InsetDivider(leading: 64)
                row("clock", title: "Only while the app is open")
                InsetDivider(leading: 64)
                row("flag.fill", title: "You can always pick your station by hand")
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            IconCircle(systemName: "checkmark", size: 56, tint: Theme.onAccent, background: Theme.accent).font(.system(size: 24, weight: .bold))
            Text("You’re ready for the Tube").font(Typography.title1).tracking(Typography.title1Tracking).foregroundStyle(Theme.ink)
            Text("Your map is on this iPhone. Re-routing works without a signal.").font(Typography.body).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) {
                row("map", title: "London Tube map",
                    detail: "\(store.isBundled ? "Came with the app" : "Downloaded") · \(store.graph?.stationCount ?? 0) stations · \(store.savedDate?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                InsetDivider(leading: 64)
                row("mic", title: "Voice input", detail: "On this iPhone")
                InsetDivider(leading: 64)
                row("location", title: "Nearest station", detail: locationDetail)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var locationDetail: String {
        if let suggestion = locator.suggestion { return "Near \(suggestion.name)" }
        return locator.isAuthorized ? "On · finding your nearest station" : "Off · you can pick it by hand"
    }

    private func row(_ icon: String, title: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            IconCircle(systemName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typography.headline).foregroundStyle(Theme.ink)
                if let detail { Text(detail).font(Typography.subhead).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 4)
        }
        .padding(12).frame(minHeight: 64)
    }

    private func feature(_ icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 16) {
            IconCircle(systemName: icon, size: 48).font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.headline).foregroundStyle(Theme.ink)
                Text(detail).font(Typography.subhead).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
