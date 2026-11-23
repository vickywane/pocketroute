import Foundation
import Observation

enum Situation: String, CaseIterable, Identifiable, Codable {
    case held = "Train held"
    case terminating = "Terminating here"
    case lineClosed = "Line closed"
    case missedStop = "Missed my stop"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .held: "pause.circle"
        case .terminating: "stop.circle"
        case .lineClosed: "xmark.circle"
        case .missedStop: "arrow.right.to.line"
        }
    }
}

struct ThreadEntry: Identifiable, Equatable {
    let id = UUID()
    let userText: String
    var replyText: String
    var plans: [RoutePlan]
    let dictated: Bool
    /// What the assistant took from the message ("At Camden Town", "No Victoria line").
    var tags: [String] = []
    var understoodBy: UnderstoodBy?
    /// One-tap station answers to a question the assistant asked.
    var choices: [String] = []
    var asking: AskField?
    /// The reply is still being worked out.
    var isPending = false
}

struct RecentReroute: Codable, Identifiable, Equatable {
    var id: String { "\(originId)>\(destinationId)>\(date.timeIntervalSince1970)" }
    let originId: String
    let destinationId: String
    let summary: String
    let date: Date
}

enum Screen: Equatable {
    case capture, conversation, guidance
}

/// Conditions the passenger reported during this conversation.
struct TripConstraints: Equatable {
    var avoidLines: Set<String> = []
    var avoidSegments: Set<String> = []
    var avoidStations: Set<String> = []
    var stepFree = false
    var walking = true
    var fewerChanges = false
}

/// The passenger's current re-routing conversation and navigation state.
///
/// Every message (typed, spoken or tapped) goes the same way: an interpreter
/// reads it into a `ParsedTurn`, the `TurnPlanner` resolves names against the
/// downloaded map, and only then does the `RouteEngine` search. The model
/// never sees or writes a route.
@MainActor
@Observable
final class RerouteSession {
    var tab = 0
    var screen: Screen = .capture
    /// The left side menu (trip types) is open.
    var showingMenu = false

    private(set) var originId: String?
    var destinationId: String?
    /// The user picked "I'm at" themselves; don't overwrite it with GPS.
    private(set) var originConfirmed = false
    var onLine: String?
    var situations: Set<Situation> = []

    private(set) var thread: [ThreadEntry] = []
    private(set) var request: RerouteRequest?
    private(set) var constraints = TripConstraints()
    /// The assistant asked for a station and is waiting for the answer.
    private(set) var awaiting: AskField?
    var isThinking: Bool { thread.last?.isPending == true }
    var selectedPlan: RoutePlan?
    var stepIndex = 0

    private(set) var recents: [RecentReroute] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let interpreter: any TurnInterpreting
    @ObservationIgnored private var planners: (version: String, planner: TurnPlanner)?
    private static let recentsKey = "pocketroute.recentReroutes"

    init(defaults: UserDefaults = .standard, interpreter: any TurnInterpreting = HybridInterpreter()) {
        self.defaults = defaults
        self.interpreter = interpreter
        if let data = defaults.data(forKey: Self.recentsKey),
           let saved = try? JSONDecoder().decode([RecentReroute].self, from: data) {
            recents = saved
        }
    }

    var latestPlans: [RoutePlan] { thread.last(where: { !$0.plans.isEmpty })?.plans ?? [] }

    // MARK: - Stations

    func setOrigin(_ id: String?, confirmed: Bool) {
        originId = id
        if confirmed { originConfirmed = true }
        if let id, id == destinationId { destinationId = nil }
    }

    /// Use a location suggestion unless the passenger already chose a station.
    func applySuggestion(_ id: String?) {
        guard let id, !originConfirmed else { return }
        originId = id
        if destinationId == id { destinationId = nil }
    }

    /// Drop stations and lines that the newly loaded map doesn't have.
    func validate(against graph: NetworkGraph) {
        if let originId, graph.stations[originId] == nil { self.originId = nil; originConfirmed = false }
        if let destinationId, graph.stations[destinationId] == nil { self.destinationId = nil }
        if let onLine, !(originId.flatMap { graph.stations[$0]?.lineIds.contains(onLine) } ?? false) { self.onLine = nil }
    }

    var canSearch: Bool { originId != nil && destinationId != nil && originId != destinationId }

    // MARK: - Search from the form

    func startSearch(graph: NetworkGraph, stepFree: Bool, walking: Bool) {
        guard canSearch else { return }
        constraints = TripConstraints(stepFree: stepFree, walking: walking)
        awaiting = nil
        let plans = search(graph: graph)
        thread = [ThreadEntry(userText: openingMessage(graph: graph), replyText: routesReply(plans, graph: graph, notes: []),
                              plans: plans, dictated: false, understoodBy: .tap)]
        selectedPlan = nil
        screen = .conversation
    }

    /// The Ask AI tab. Searches with the form when it is complete and the
    /// conversation is empty or about a different trip; otherwise reopens the
    /// conversation as it was (an empty one waits for the passenger to type).
    func openAssistant(graph: NetworkGraph, stepFree: Bool, walking: Bool) {
        let sameTrip = request?.origin == originId && request?.destination == destinationId
        if canSearch && (thread.isEmpty || !sameTrip) {
            startSearch(graph: graph, stepFree: stepFree, walking: walking)
        } else {
            screen = .conversation
        }
    }

    // MARK: - Conversation

    /// "Held at Camden, need Warren Street": typed or spoken on the first
    /// screen. Starts a conversation that fills in the form and searches as
    /// soon as both stations are known.
    func describe(_ text: String, graph: NetworkGraph, dictated: Bool = false) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        constraints = TripConstraints(stepFree: defaults.bool(forKey: Preference.stepFree),
                                      walking: true)
        thread = []
        request = nil
        awaiting = nil
        selectedPlan = nil
        screen = .conversation
        await followUp(text, graph: graph, dictated: dictated)
    }

    /// A typed, spoken or quick-reply message in the conversation. Chips are
    /// read by keyword rules so a tap never waits for a model.
    func followUp(_ text: String, graph: NetworkGraph, dictated: Bool = false, isQuickReply: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }
        thread.append(ThreadEntry(userText: trimmed, replyText: "", plans: [], dictated: dictated, isPending: true))
        selectedPlan = nil
        screen = .conversation

        let planner = planner(for: graph)
        // A chip or a bare station name ("Camden Town") needs no model.
        let isJustAStation = if case .station = planner.matcher.match(trimmed) { true } else { false }
        let reader: any TurnInterpreting = isQuickReply || isJustAStation ? KeywordInterpreter() : interpreter
        let (turn, by) = await reader.interpret(trimmed, context: context(graph: graph), matcher: planner.matcher)
        let state = PlannerState(origin: originId, destination: destinationId, onLine: onLine, awaiting: awaiting,
                                 currentFirstLeg: latestPlans.first?.rideLegs.first)
        let planned = planner.plan(turn, state: state)
        apply(planned)
        respond(to: planned, understoodBy: isQuickReply ? .tap : by, graph: graph)
    }

    /// The passenger tapped one of the stations offered in a question.
    func choose(_ stationId: String, graph: NetworkGraph) {
        guard let field = awaiting, let name = graph.stations[stationId]?.name, !isThinking else { return }
        thread.append(ThreadEntry(userText: name, replyText: "", plans: [], dictated: false, isPending: true))
        if field == .origin { setOrigin(stationId, confirmed: true) } else { destinationId = stationId }
        awaiting = nil
        var planned = PlannedTurn()
        planned.tags = [field == .origin ? "At \(name)" : "To \(name)"]
        respond(to: planned, understoodBy: .tap, graph: graph, answeredQuestion: true)
    }

    /// The station picker was used to answer the assistant's question.
    func pickedFromList(graph: NetworkGraph) {
        guard let field = awaiting, let id = field == .origin ? originId : destinationId else { return }
        choose(id, graph: graph)
    }

    private func apply(_ planned: PlannedTurn) {
        if let origin = planned.origin { setOrigin(origin, confirmed: true) }
        if let destination = planned.destination, destination != originId { destinationId = destination }
        if let line = planned.onLine { onLine = line }
        if let situation = planned.situation { situations.insert(situation) }
        if planned.trainMoving { situations.subtract([.held, .terminating]) }
        constraints.avoidLines.formUnion(planned.avoidLines)
        constraints.avoidSegments.formUnion(planned.avoidSegments)
        constraints.avoidStations.formUnion(planned.avoidStations)
        if let stepFree = planned.stepFree { constraints.stepFree = stepFree }
        if let walking = planned.walking { constraints.walking = walking }
        if planned.fewerChanges { constraints.fewerChanges = true }
        if planned.origin != nil, awaiting == .origin { awaiting = nil }
        if planned.destination != nil, awaiting == .destination { awaiting = nil }
    }

    private func respond(to planned: PlannedTurn, understoodBy: UnderstoodBy, graph: NetworkGraph, answeredQuestion: Bool = false) {
        guard var entry = thread.popLast() else { return }
        entry.isPending = false
        entry.tags = planned.tags
        entry.understoodBy = understoodBy
        let problems = planned.problems.joined(separator: " ")

        if let question = planned.question {
            awaiting = question.field
            entry.replyText = [problems, question.prompt].filter { !$0.isEmpty }.joined(separator: " ")
            entry.choices = question.choices
            entry.asking = question.field
        } else if !canSearch {
            let field: AskField = originId == nil ? .origin : .destination
            awaiting = field
            let intro = [problems, planned.notes.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " ")
            entry.replyText = [intro, field == .origin ? "Which station are you at now?" : "Where are you trying to get to?"]
                .filter { !$0.isEmpty }.joined(separator: " ")
            entry.choices = defaultChoices(for: field, graph: graph)
            entry.asking = field
        } else if planned.changesTrip || request == nil || answeredQuestion {
            var plans = search(graph: graph)
            if plans.isEmpty, let firstHop = planned.firstHop {
                // The closure also cut the only way out of this station: keep the first hop.
                constraints.avoidSegments.remove(firstHop)
                plans = search(graph: graph)
            }
            entry.plans = plans
            let notes = planned.notes + (planned.asksForUnavailableInfo ? [Self.noLiveInfo] : [])
            entry.replyText = [problems, routesReply(plans, graph: graph, notes: notes)].filter { !$0.isEmpty }.joined(separator: " ")
        } else if planned.asksForUnavailableInfo {
            entry.replyText = Self.noLiveInfo + " Your routes haven’t changed."
        } else if !problems.isEmpty {
            entry.replyText = problems + " Your routes haven’t changed."
        } else {
            entry.replyText = "I didn’t catch a change to your trip, so your routes haven’t changed. Try a quick reply, or say something like “the Victoria line is closed” or “I’m at Euston now”."
        }
        thread.append(entry)
    }

    private static let noLiveInfo = "I can’t see live service, delays or platforms offline. If you know a line or station is closed, tell me and I’ll route around it."

    private func search(graph: NetworkGraph) -> [RoutePlan] {
        guard let originId, let destinationId, originId != destinationId else { request = nil; return [] }
        var request = RerouteRequest(origin: originId, destination: destinationId, onLine: onLine)
        request.trainStuck = situations.contains(.held) || situations.contains(.terminating)
        request.avoidLines = constraints.avoidLines
        if situations.contains(.lineClosed), let onLine { request.avoidLines.insert(onLine) }
        request.avoidSegments = constraints.avoidSegments
        request.avoidStations = constraints.avoidStations
        request.stepFreeOnly = constraints.stepFree
        request.includeWalking = constraints.walking
        self.request = request
        var plans = RouteEngine(graph: graph).options(for: request)
        if constraints.fewerChanges {
            plans.sort { ($0.isWalkOnly ? 1 : 0, $0.changes, $0.minutes) < ($1.isWalkOnly ? 1 : 0, $1.changes, $1.minutes) }
        }
        return plans
    }

    private func planner(for graph: NetworkGraph) -> TurnPlanner {
        if let planners, planners.version == graph.version { return planners.planner }
        let planner = TurnPlanner(graph: graph)
        planners = (graph.version, planner)
        return planner
    }

    private func context(graph: NetworkGraph) -> TurnContext {
        TurnContext(origin: originId.flatMap { graph.stations[$0]?.name },
                    destination: destinationId.flatMap { graph.stations[$0]?.name },
                    line: onLine.map(graph.lineName),
                    currentRoute: latestPlans.first.map { plan in
                        plan.legs.map { leg in
                            let stops = leg.stops.compactMap { graph.stations[$0]?.name }
                            return leg.lineId.map { "\(graph.lineName($0)) line \(stops.first ?? "") to \(stops.last ?? "")" }
                                ?? "walk to \(stops.last ?? "")"
                        }.joined(separator: ", then ")
                    })
    }

    private func defaultChoices(for field: AskField, graph: NetworkGraph) -> [String] {
        switch field {
        case .origin:
            var ids: [String] = []
            if let onLine, let destinationId { ids = graph.lineOrder(line: onLine, around: destinationId).map(\.id) }
            return Array(ids.filter { $0 != destinationId }.prefix(4))
        case .destination:
            var seen = Set<String>()
            return recents.map(\.destinationId).filter { $0 != originId && graph.stations[$0] != nil && seen.insert($0).inserted }.prefix(4).map { $0 }
        }
    }

    // MARK: - Guidance

    func start(_ plan: RoutePlan, graph: NetworkGraph) {
        selectedPlan = plan
        stepIndex = 0
        screen = .guidance
        guard let request else { return }
        let entry = RecentReroute(originId: request.origin, destinationId: request.destination,
                                  summary: RouteText.summary(plan, graph: graph), date: Date())
        recents.removeAll { $0.originId == entry.originId && $0.destinationId == entry.destinationId }
        recents.insert(entry, at: 0)
        recents = Array(recents.prefix(5))
        if let data = try? JSONEncoder().encode(recents) { defaults.set(data, forKey: Self.recentsKey) }
    }

    /// "Something's wrong": search again from the start of the current step.
    func rerouteFromCurrentStep(graph: NetworkGraph, stepFree: Bool, walking: Bool) {
        if let plan = selectedPlan, plan.legs.indices.contains(stepIndex), let here = plan.legs[stepIndex].stops.first {
            originId = here
            originConfirmed = true
            onLine = plan.legs[stepIndex].lineId
        }
        startSearch(graph: graph, stepFree: stepFree, walking: walking)
    }

    func reopen(_ recent: RecentReroute, graph: NetworkGraph, stepFree: Bool, walking: Bool) {
        guard graph.stations[recent.originId] != nil, graph.stations[recent.destinationId] != nil else { return }
        originId = recent.originId
        originConfirmed = true
        destinationId = recent.destinationId
        onLine = nil
        situations = []
        tab = 0
        startSearch(graph: graph, stepFree: stepFree, walking: walking)
    }

    func finishJourney() {
        selectedPlan = nil
        screen = .capture
        thread = []
        situations = []
        awaiting = nil
    }

    // MARK: - Copy

    private func openingMessage(graph: NetworkGraph) -> String {
        let origin = originId.flatMap { graph.stations[$0]?.name } ?? "a station"
        let destination = destinationId.flatMap { graph.stations[$0]?.name } ?? "my destination"
        var parts: [String] = []
        if let onLine { parts.append("I’m on the \(graph.lineName(onLine)) line at \(origin).") }
        else { parts.append("I’m at \(origin).") }
        let reported = Situation.allCases.filter(situations.contains).map(\.rawValue)
        if !reported.isEmpty { parts.append("\(reported.joined(separator: ", ")).") }
        parts.append("How do I get to \(destination)?")
        return parts.joined(separator: " ")
    }

    private func routesReply(_ plans: [RoutePlan], graph: NetworkGraph, notes: [String]) -> String {
        let destination = destinationId.flatMap { graph.stations[$0]?.name } ?? "your destination"
        let summary = switch plans.count {
        case 0: "I couldn’t find a route to \(destination) on the saved map with those conditions."
        case 1: notes.isEmpty ? "Here’s the best way to \(destination) from here:" : "Here’s the best way:"
        default: notes.isEmpty ? "There are \(plans.count) ways to \(destination) from here:" : "Here are \(plans.count) ways:"
        }
        return (notes + [summary]).joined(separator: " ")
    }
}

/// Human-readable route text, built only from graph data.
enum RouteText {
    static func title(_ plan: RoutePlan, graph: NetworkGraph) -> String {
        if plan.isWalkOnly { return "Walk instead" }
        let names = plan.rideLegs.compactMap(\.lineId).map(graph.lineName)
        var collapsed: [String] = []
        for name in names where collapsed.last != name { collapsed.append(name) }
        if collapsed.count == 1 { return plan.rideLegs.count > 1 ? "\(collapsed[0]) line, change trains" : "\(collapsed[0]) line" }
        return collapsed.joined(separator: " → ")
    }

    static func detail(_ plan: RoutePlan, graph: NetworkGraph) -> String {
        if case let .walk(metres)? = plan.legs.first?.kind, plan.isWalkOnly {
            return "\(distance(metres)) · leave the station"
        }
        let stops = plan.rideLegs.reduce(0) { $0 + $1.stopCount }
        let stopText = stops == 1 ? "1 stop" : "\(stops) stops"
        guard plan.changes > 0 else { return "\(stopText) · no changes" }
        let changeStations = plan.rideLegs.dropFirst().compactMap { graph.stations[$0.stops.first ?? ""]?.name }
        return "\(stopText) · change at \(changeStations.joined(separator: ", "))"
    }

    static func summary(_ plan: RoutePlan, graph: NetworkGraph) -> String {
        plan.isWalkOnly ? "walked" : "via \(title(plan, graph: graph))"
    }

    static func instruction(for leg: RouteLeg, index: Int, in plan: RoutePlan, onLine: String?, trainStuck: Bool, graph: NetworkGraph) -> String {
        let start = graph.stations[leg.stops.first ?? ""]?.name ?? "this station"
        let end = graph.stations[leg.stops.last ?? ""]?.name ?? "the next station"
        switch leg.kind {
        case .walk:
            return "Walk to \(end)"
        case let .ride(lineId, towards):
            let line = graph.lineName(lineId)
            let direction = towards.map { " towards \($0)" } ?? ""
            if index == 0 {
                if lineId == onLine && !trainStuck { return "Stay on the \(line) line\(direction)" }
                return "Take the \(line) line\(direction)"
            }
            return "At \(start), change to the \(line) line\(direction)"
        }
    }

    static func legDetail(_ leg: RouteLeg, graph: NetworkGraph) -> String {
        let end = graph.stations[leg.stops.last ?? ""]?.name ?? "the next station"
        switch leg.kind {
        case let .walk(metres):
            return "About \(distance(metres)) · \(max(Int(leg.minutes.rounded()), 1)) min on foot"
        case .ride:
            let stops = leg.stopCount == 1 ? "1 stop" : "\(leg.stopCount) stops"
            return "\(stops) · get off at \(end)"
        }
    }

    static func distance(_ metres: Int) -> String {
        metres < 1_000 ? "\(Int((Double(metres) / 10).rounded()) * 10) m" : String(format: "%.1f km", Double(metres) / 1_000)
    }
}
