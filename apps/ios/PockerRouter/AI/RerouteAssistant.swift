import Foundation

/// Who read the passenger's message, shown under it so people know how much
/// to trust the reading.
enum UnderstoodBy: String, Sendable, Equatable {
    case onDevice = "Understood on this iPhone"
    case keywords = "Matched by keywords"
    case tap = "Tapped"
}

protocol TurnInterpreting: Sendable {
    func interpret(_ text: String, context: TurnContext, matcher: StationMatcher) async -> (ParsedTurn, UnderstoodBy)
}

/// No model: keyword rules only. Used for quick-reply chips and on phones
/// without Apple Intelligence, and in tests.
struct KeywordInterpreter: TurnInterpreting {
    func interpret(_ text: String, context: TurnContext, matcher: StationMatcher) async -> (ParsedTurn, UnderstoodBy) {
        (KeywordParser(matcher: matcher).parse(text), .keywords)
    }
}

/// Apple Intelligence when it can run, keyword rules otherwise. The model's
/// reading is grounded against the passenger's own words, then merged with
/// the keyword reading so a missed flag ("step-free") is still caught.
struct HybridInterpreter: TurnInterpreting {
    var timeout: Duration = .seconds(6)

    func interpret(_ text: String, context: TurnContext, matcher: StationMatcher) async -> (ParsedTurn, UnderstoodBy) {
        let keywords = KeywordParser(matcher: matcher).parse(text)
        guard AssistantAvailability.current == .onDevice else { return (keywords, .keywords) }
        do {
            let model = try await withThrowingTaskGroup(of: ParsedTurn.self) { group in
                group.addTask { try await OnDeviceParser().parse(text, context: context) }
                group.addTask { [timeout] in
                    try await Task.sleep(for: timeout)
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
            let said = Grounding.keepSaid(model, in: text, matcher: matcher)
            return (Grounding.trustFlags(said, keywords: keywords, text: text).merged(with: keywords), .onDevice)
        } catch {
            return (keywords, .keywords)
        }
    }
}

/// Drops anything the model "heard" that the passenger never said, so a
/// helpful model can't slip a station or a closure into the plan.
enum Grounding {
    private static let filler: Set<String> = ["the", "station", "street", "road", "st", "line", "tube", "underground", "and",
                                              "park", "lane", "of", "on", "at", "central", "circle", "city", "town"]

    static func keepSaid(_ turn: ParsedTurn, in text: String, matcher: StationMatcher) -> ParsedTurn {
        var turn = turn
        let said = Set(StationMatcher.normalise(text).split(separator: " ").map(String.init))
        let mentioned = Set(matcher.mentions(in: text).flatMap(\.stationIds))

        func grounded(_ name: String?) -> Bool {
            guard let name else { return false }
            if case let .station(id) = matcher.match(name), mentioned.contains(id) { return true }
            let words = StationMatcher.normalise(name).split(separator: " ").map(String.init)
            let key = words.filter { !filler.contains($0) && $0.count >= 3 }
            if key.isEmpty { return !words.isEmpty && words.allSatisfy(said.contains) }
            return key.contains { word in
                said.contains { $0 == word || (word.count >= 5 && StationMatcher.distance($0, word) <= 1) }
            }
        }

        if !grounded(turn.currentStation) { turn.currentStation = nil }
        if !grounded(turn.destination) { turn.destination = nil }
        if !grounded(turn.line) { turn.line = nil }
        turn.closedLines = turn.closedLines.filter(grounded)
        turn.closedStations = turn.closedStations.filter(grounded)
        turn.closedSections = turn.closedSections.filter { grounded($0.from) && grounded($0.to) }
        return turn
    }

    /// The model is quick to raise flags. Keep the ones that over-restrict a
    /// route only when the words back them up:
    /// - the ends of a closed section are not closed stations,
    /// - "that route is blocked" needs the keyword rules to agree, and gives
    ///   way to an explicit closure,
    /// - a live-info question needs the keyword rules or a question mark.
    static func trustFlags(_ turn: ParsedTurn, keywords: ParsedTurn, text: String) -> ParsedTurn {
        var turn = turn
        let ends = Set(turn.closedSections.flatMap { [StationMatcher.normalise($0.from), StationMatcher.normalise($0.to)] })
        turn.closedStations.removeAll { ends.contains(StationMatcher.normalise($0)) }
        let explicitClosure = !turn.closedSections.isEmpty || !turn.closedLines.isEmpty || !turn.closedStations.isEmpty
        turn.currentRouteBlocked = turn.currentRouteBlocked && keywords.currentRouteBlocked && !explicitClosure
        turn.asksForUnavailableInfo = turn.asksForUnavailableInfo && (keywords.asksForUnavailableInfo || text.contains("?"))
        return turn
    }
}

// MARK: - Planning

enum AskField: String, Sendable, Equatable {
    case origin, destination
}

struct AssistantQuestion: Equatable, Sendable {
    let field: AskField
    let prompt: String
    /// Station ids offered as one-tap answers.
    let choices: [String]
}

/// What the session knows before a message is applied.
struct PlannerState: Sendable {
    var origin: String?
    var destination: String?
    var onLine: String?
    var awaiting: AskField?
    /// First ride of the route currently shown, for "that branch isn't running".
    var currentFirstLeg: RouteLeg?
}

/// A message resolved against the downloaded map: ids instead of names, plus
/// the sentences that say what changed. Pure and deterministic.
struct PlannedTurn: Equatable, Sendable {
    var origin: String?
    var destination: String?
    var onLine: String?
    var situation: Situation?
    var trainMoving = false
    var avoidLines: Set<String> = []
    var avoidSegments: Set<String> = []
    var avoidStations: Set<String> = []
    /// Segment out of the origin that may be restored if nothing else is left.
    var firstHop: String?
    var stepFree: Bool?
    var walking: Bool?
    var fewerChanges = false
    var asksForUnavailableInfo = false
    var question: AssistantQuestion?
    var notes: [String] = []
    var problems: [String] = []
    /// Short labels for the "understood" row under the passenger's message.
    var tags: [String] = []

    var changesTrip: Bool {
        origin != nil || destination != nil || onLine != nil || situation != nil || trainMoving
            || !avoidLines.isEmpty || !avoidSegments.isEmpty || !avoidStations.isEmpty
            || stepFree != nil || walking != nil || fewerChanges
    }
}

struct TurnPlanner: Sendable {
    let graph: NetworkGraph
    let matcher: StationMatcher

    init(graph: NetworkGraph) {
        self.graph = graph
        matcher = StationMatcher(graph: graph)
    }

    func plan(_ turn: ParsedTurn, state: PlannerState) -> PlannedTurn {
        var out = PlannedTurn()
        var turn = turn

        // A bare name answers the question we asked, or fills the one gap.
        if let name = turn.unassignedStation {
            switch state.awaiting ?? (state.origin == nil ? .origin : (state.destination == nil ? .destination : nil)) {
            case .origin? where turn.currentStation == nil: turn.currentStation = name
            case .destination? where turn.destination == nil: turn.destination = name
            default: break
            }
        }

        if let raw = turn.line {
            if let line = matcher.line(raw) {
                if line != state.onLine { out.onLine = line; out.tags.append("\(graph.lineName(line)) line") }
            } else {
                out.problems.append("I couldn’t find a “\(raw)” line on the saved Tube map.")
            }
        }
        let preferLine = out.onLine ?? state.onLine

        func station(_ raw: String?, field: AskField) -> String? {
            guard let raw else { return nil }
            switch matcher.match(raw, preferLine: preferLine) {
            case let .station(id):
                return id
            case let .ambiguous(ids):
                if out.question == nil {
                    out.question = AssistantQuestion(field: field, prompt: "There’s more than one \(raw.capitalizedTitle) on the map. Which one?", choices: ids)
                }
            case let .unknown(suggestions):
                out.problems.append("I couldn’t find “\(raw)” on the saved Tube map.")
                if out.question == nil, !suggestions.isEmpty {
                    out.question = AssistantQuestion(field: field, prompt: field == .origin ? "Did you mean one of these?" : "Were you going to one of these?",
                                                     choices: suggestions)
                }
            }
            return nil
        }

        if let id = station(turn.currentStation, field: .origin), id != state.origin {
            out.origin = id
            out.tags.append("At \(name(id))")
            if state.origin != nil { out.notes.append("OK, from \(name(id)).") }
        }
        if let id = station(turn.destination, field: .destination), id != state.destination {
            out.destination = id
            out.tags.append("To \(name(id))")
            if state.destination != nil { out.notes.append("OK, going to \(name(id)) instead.") }
        }

        if let situation = turn.situation {
            out.situation = situation
            out.tags.append(situation.rawValue)
            if situation == .lineClosed, let line = preferLine {
                out.avoidLines.insert(line)
            }
        }
        if turn.trainMoving {
            out.trainMoving = true
            out.tags.append("Train moving")
            out.notes.append(preferLine.map { "Good. Staying on the \(graph.lineName($0)) line is back in the options." } ?? "Good. Here are the options again.")
        }

        for raw in turn.closedLines {
            guard let line = matcher.line(raw) else {
                out.problems.append("I couldn’t find a “\(raw)” line on the saved Tube map.")
                continue
            }
            out.avoidLines.insert(line)
        }
        for line in out.avoidLines.sorted() {
            out.tags.append("No \(graph.lineName(line)) line")
            out.notes.append("Avoiding the \(graph.lineName(line)) line.")
        }

        for section in turn.closedSections {
            guard case let .station(a) = matcher.match(section.from, preferLine: preferLine),
                  case let .station(b) = matcher.match(section.to, preferLine: preferLine) else {
                out.problems.append("I couldn’t place “\(section.from)” and “\(section.to)” on the saved Tube map.")
                continue
            }
            let lines: [String] = if let raw = section.line, let line = matcher.line(raw) { [line] } else {
                (graph.stations[a]?.lineIds ?? []).filter { graph.stations[b]?.lineIds.contains($0) == true }
            }
            let keys = lines.reduce(into: Set<String>()) { $0.formUnion(graph.segmentKeys(line: $1, between: a, and: b)) }
            guard !keys.isEmpty else {
                out.problems.append("\(name(a)) and \(name(b)) aren’t on the same line in the saved map, so I can’t tell which section is closed.")
                continue
            }
            out.avoidSegments.formUnion(keys)
            let lineText = lines.count == 1 ? "the \(graph.lineName(lines[0])) line" : "trains"
            out.notes.append("Avoiding \(lineText) between \(name(a)) and \(name(b)).")
            out.tags.append("No service \(name(a))–\(name(b))")
        }

        for raw in turn.closedStations {
            switch matcher.match(raw, preferLine: preferLine) {
            case let .station(id):
                guard id != state.origin, id != (out.destination ?? state.destination) else { continue }
                out.avoidStations.insert(id)
                out.tags.append("Avoid \(name(id))")
                out.notes.append("Not changing or getting off at \(name(id)).")
            case .ambiguous:
                out.problems.append("There’s more than one \(raw.capitalizedTitle), so I haven’t avoided either. Say which line it’s on.")
            case .unknown:
                out.problems.append("I couldn’t find “\(raw)” on the saved Tube map.")
            }
        }

        if turn.currentRouteBlocked, let leg = state.currentFirstLeg, let line = leg.lineId, leg.stops.count >= 2 {
            for (a, b) in zip(leg.stops, leg.stops.dropFirst()) {
                out.avoidSegments.insert(RerouteRequest.segmentKey(line: line, a, b))
            }
            out.firstHop = RerouteRequest.segmentKey(line: line, leg.stops[0], leg.stops[1])
            out.tags.append("Not that route")
            out.notes.append("OK, avoiding the \(graph.lineName(line)) line between \(name(leg.stops[0])) and \(name(leg.stops[leg.stops.count - 1])).")
        }

        if turn.stepFree == true {
            out.stepFree = true
            out.tags.append("Step-free")
            out.notes.append("Showing routes that only change at stations TfL lists with lift access. Lift outages aren’t known offline.")
        }
        if let walking = turn.walking {
            out.walking = walking
            out.tags.append(walking ? "Walking OK" : "No walking")
            out.notes.append(walking ? "Walking is included." : "OK, no walking routes.")
        }
        if turn.fewerChanges {
            out.fewerChanges = true
            out.tags.append("Fewer changes")
            out.notes.append("Putting the route with the fewest changes first.")
        }
        out.asksForUnavailableInfo = turn.asksForUnavailableInfo
        return out
    }

    private func name(_ id: String) -> String { graph.stations[id]?.name ?? id }
}

private extension String {
    /// "edgware road" → "Edgware Road", leaving already-capitalised text alone.
    var capitalizedTitle: String { self == lowercased() ? capitalized : self }
}
