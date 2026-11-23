import SwiftUI

/// Root: owns the app's long-lived state and wires the location suggestion
/// to the loaded map.
struct JourneyHomeView: View {
    @State private var store = DatasetStore()
    @State private var locator = StationLocator()
    @State private var voice = VoiceCapture()
    @State private var connectivity = Connectivity()
    @State private var session = RerouteSession()
    @AppStorage(Preference.onboardingComplete) private var onboardingComplete = false
    @AppStorage(Preference.keepMapUpdated) private var keepMapUpdated = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !onboardingComplete {
                OnboardingView()
            } else if let graph = store.graph {
                MainView(graph: graph)
            } else if store.didLoad {
                ContentUnavailableView("No Tube map", systemImage: "map",
                                       description: Text("Connect to the internet once to download the map."))
            } else {
                ProgressView("Loading saved map…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .environment(store)
        .environment(locator)
        .environment(voice)
        .environment(connectivity)
        .environment(session)
        .task {
            await store.loadLocal()
            locator.graph = store.graph
            guard onboardingComplete else { return }
            locator.locate(prompt: false)
            if keepMapUpdated { await store.refresh() }
        }
        // The suggestion is matched against whichever map is loaded, so a
        // finished download re-checks the passenger's location.
        .onChange(of: store.graph?.version) { _, _ in
            locator.graph = store.graph
            if let graph = store.graph { session.validate(against: graph) }
        }
        .onChange(of: locator.suggestion?.id) { _, id in session.applySuggestion(id) }
        .onChange(of: onboardingComplete) { _, complete in
            if complete { session.applySuggestion(locator.suggestion?.id) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && onboardingComplete { locator.locate(prompt: false) }
        }
    }
}

enum VoiceTarget: String, Identifiable {
    case followUp
    var id: String { rawValue }
}

private struct MainView: View {
    let graph: NetworkGraph
    @Environment(RerouteSession.self) private var session
    @Environment(VoiceCapture.self) private var voice
    @AppStorage(Preference.stepFree) private var stepFree = false
    @State private var voiceTarget: VoiceTarget?
    /// Hide the tab bar while typing so it doesn't ride up over the field.
    @State private var keyboardUp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How much of the drawer is showing while a finger is dragging it.
    @State private var drawerDrag: CGFloat?
    private let drawerWidth: CGFloat = 316
    private var drawerVisible: CGFloat { drawerDrag ?? (session.showingMenu ? drawerWidth : 0) }
    private var drawerProgress: Double { Double(drawerVisible / drawerWidth) }
    /// Every tab shows the tab bar and allows the drawer; step-by-step guidance doesn't.
    private var showsTabBar: Bool { session.tab != 0 || session.screen != .guidance || session.selectedPlan == nil }
    private var drawerAvailable: Bool { showsTabBar }

    var body: some View {
        Group {
            switch (session.tab, session.screen) {
            case (1, _): HistoryView(graph: graph)
            case (2, _): SettingsView(graph: graph)
            case (_, .guidance) where session.selectedPlan != nil: GuidanceView(graph: graph)
            case (_, .conversation): ConversationView(graph: graph, voiceTarget: $voiceTarget)
            default: CaptureView(graph: graph)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !keyboardUp && showsTabBar { tabBar }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        // Native-style navigation drawer: swipe in from the left edge or tap ☰;
        // it follows the finger, and swiping left or tapping outside closes it.
        .simultaneousGesture(edgeSwipe, including: drawerAvailable ? .all : .subviews)
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                Color.black.opacity(0.35 * drawerProgress).ignoresSafeArea()
                    .onTapGesture { setMenu(false) }
                    .accessibilityLabel("Close menu")
                    .accessibilityAddTraits(.isButton)
                SideMenu(shadowOpacity: 0.18 * drawerProgress) { setMenu(false) }
                    .offset(x: drawerVisible - drawerWidth)
            }
            .gesture(closeSwipe)
            .allowsHitTesting(drawerVisible > 0)
            .accessibilityHidden(drawerVisible == 0)
        }
        .sheet(item: $voiceTarget, onDismiss: { voice.cancel() }) { _ in
            VoiceSheet { transcript in
                Task { await session.followUp(transcript, graph: graph, dictated: true) }
            }
        }
    }

    private func setMenu(_ open: Bool) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9)) {
            session.showingMenu = open
            drawerDrag = nil
        }
    }

    /// Drag that starts at the left edge pulls the drawer out.
    private var edgeSwipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !session.showingMenu, value.startLocation.x < 24, value.translation.width > 0 else { return }
                drawerDrag = min(value.translation.width, drawerWidth)
            }
            .onEnded { value in
                guard drawerDrag != nil else { return }
                setMenu(value.predictedEndTranslation.width > drawerWidth / 2)
            }
    }

    /// Drag left on the open drawer (or the dimmed area) pushes it away.
    private var closeSwipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard session.showingMenu else { return }
                drawerDrag = max(0, drawerWidth + min(0, value.translation.width))
            }
            .onEnded { value in
                guard drawerDrag != nil else { return }
                setMenu(value.predictedEndTranslation.width > -drawerWidth / 3)
            }
    }

    /// Fixed bottom tab bar: Re-route · Ask AI · History · Settings. Ask AI opens
    /// the route conversation, searching first when the form is complete.
    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Re-route", "arrow.triangle.turn.up.right.diamond", selected: session.tab == 0 && session.screen == .capture) {
                session.tab = 0
                session.screen = .capture
            }
            tabButton("Ask AI", "sparkles", selected: session.tab == 0 && session.screen == .conversation) {
                session.tab = 0
                session.openAssistant(graph: graph, stepFree: stepFree, walking: true)
            }
            tabButton("History", "clock.arrow.circlepath", selected: session.tab == 1) { session.tab = 1 }
            tabButton("Settings", "slider.horizontal.3", selected: session.tab == 2) { session.tab = 2 }
        }
        .padding(.horizontal, 8).padding(.top, 4)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Theme.line.frame(height: 0.5) }
    }

    private func tabButton(_ title: String, _ icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Active tab is shown by colour alone.
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 19, weight: selected ? .semibold : .regular)).frame(height: 24)
                Text(title).font(Typography.tabLabel).lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.accentText : Theme.secondary)
            .frame(maxWidth: .infinity).frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
