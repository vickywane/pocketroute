import Foundation
import FoundationModels

/// What the on-device model fills in. Every field is "only if the passenger
/// said it": the model copies names, it does not choose stations or routes.
@Generable(description: "What a London Underground passenger just said about their disrupted journey")
struct ModelTurn {
    @Guide(description: "Station the passenger is at or stuck at now, copied from their words. Empty if not said.")
    var currentStation: String?
    @Guide(description: "Station the passenger wants to get to, copied from their words. Empty if not said.")
    var destination: String?
    @Guide(description: "Tube line the passenger is or was travelling on, for example Northern. Empty if not said.")
    var line: String?
    @Guide(description: "What happened, if said", .anyOf(["held", "terminating", "lineClosed", "missedStop"]))
    var situation: String?
    @Guide(description: "True only if they say their train is moving again")
    var trainMoving: Bool
    @Guide(description: "Tube lines they say are closed, suspended or not running")
    var closedLines: [String]
    @Guide(description: "Station they say a closure starts at, when they name a section such as 'between Camden and Euston'")
    var closedFrom: String?
    @Guide(description: "Station they say that closed section ends at")
    var closedTo: String?
    @Guide(description: "Stations they say are closed or want to avoid")
    var closedStations: [String]
    @Guide(description: "True if they say the suggested route, that branch or that train is not running or can't be used")
    var currentRouteBlocked: Bool
    @Guide(description: "True if they need step-free access, lifts, or can't use stairs")
    var stepFree: Bool
    @Guide(description: "\"yes\" if they want or are happy to walk, \"no\" if they don't want to walk, empty otherwise", .anyOf(["yes", "no"]))
    var walking: String?
    @Guide(description: "True if they want fewer changes or a direct train")
    var fewerChanges: Bool
    @Guide(description: "True if they ask for live service status, delays, when a train will move, platforms or exits")
    var asksForUnavailableInfo: Bool
}

enum AssistantAvailability: Equatable, Sendable {
    case onDevice
    case notEligible
    case appleIntelligenceOff
    case modelDownloading
    case unavailable

    static var current: AssistantAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return SystemLanguageModel.default.supportsLocale() ? .onDevice : .unavailable
        case .unavailable(.deviceNotEligible): return .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .modelDownloading
        case .unavailable: return .unavailable
        }
    }

    var title: String {
        switch self {
        case .onDevice: "On this iPhone"
        case .notEligible, .unavailable: "Keywords only"
        case .appleIntelligenceOff: "Apple Intelligence off"
        case .modelDownloading: "Getting ready"
        }
    }

    var detail: String {
        switch self {
        case .onDevice: "Apple Intelligence reads what you type or say, offline. Routes still come only from the saved map."
        case .notEligible: "This iPhone can’t run Apple Intelligence. Station names, quick replies and common phrases still work."
        case .appleIntelligenceOff: "Turn on Apple Intelligence in the Settings app to describe problems in your own words."
        case .modelDownloading: "Apple Intelligence is still downloading. Until then, station names and quick replies work."
        case .unavailable: "Apple Intelligence isn’t available in this language. Station names and quick replies still work."
        }
    }
}

/// A model's reading as plain values, whichever model produced it.
struct ModelFields: Sendable {
    var currentStation: String?
    var destination: String?
    var line: String?
    var situation: String?
    var trainMoving = false
    var closedLines: [String] = []
    var closedFrom: String?
    var closedTo: String?
    var closedStations: [String] = []
    var currentRouteBlocked = false
    var stepFree = false
    var walking: String?
    var fewerChanges = false
    var asksForUnavailableInfo = false
}

/// Context the model needs to make sense of "that branch" or "the change".
struct TurnContext: Sendable, Equatable {
    var origin: String?
    var destination: String?
    var line: String?
    var currentRoute: String?
}

/// Apple Foundation Models, on device. One short, stateless request per
/// message, so the context window never fills up and no history is kept.
struct OnDeviceParser: Sendable {
    static let instructions = """
    You read short messages from London Underground passengers whose journey has gone wrong, often with no signal. \
    Fill in only what the passenger actually said. Copy station and line names as they wrote them; do not correct them \
    into other stations, and never add stations, lines, closures or delays they did not mention. \
    Leave a field empty when they did not say it. You do not plan routes and you do not know live service information.
    """

    /// The request text shared by the on-device and Gemini readers.
    static func prompt(_ text: String, context: TurnContext) -> String {
        var prompt = ""
        if let origin = context.origin { prompt += "Known so far: at \(origin)" }
        if let destination = context.destination { prompt += (prompt.isEmpty ? "Known so far: " : ", ") + "going to \(destination)" }
        if let line = context.line { prompt += (prompt.isEmpty ? "Known so far: " : ", ") + "on the \(line) line" }
        if !prompt.isEmpty { prompt += ".\n" }
        if let route = context.currentRoute { prompt += "Route currently suggested: \(route).\n" }
        return prompt + "Passenger says: \(text)"
    }

    func parse(_ text: String, context: TurnContext) async throws -> ParsedTurn {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: Self.instructions)
        let response = try await session.respond(to: Self.prompt(text, context: context), generating: ModelTurn.self,
                                                 options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300))
        return Self.turn(from: response.content)
    }

    static func turn(from model: ModelTurn) -> ParsedTurn {
        turn(from: ModelFields(
            currentStation: model.currentStation, destination: model.destination, line: model.line,
            situation: model.situation, trainMoving: model.trainMoving, closedLines: model.closedLines,
            closedFrom: model.closedFrom, closedTo: model.closedTo, closedStations: model.closedStations,
            currentRouteBlocked: model.currentRouteBlocked, stepFree: model.stepFree, walking: model.walking,
            fewerChanges: model.fewerChanges, asksForUnavailableInfo: model.asksForUnavailableInfo
        ))
    }

    static func turn(from model: ModelFields) -> ParsedTurn {
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  !["none", "null", "unknown", "n/a"].contains(value.lowercased()) else { return nil }
            return value
        }
        var turn = ParsedTurn()
        turn.currentStation = clean(model.currentStation)
        turn.destination = clean(model.destination)
        turn.line = clean(model.line)
        turn.situation = switch model.situation {
        case "held": .held
        case "terminating": .terminating
        case "lineClosed": .lineClosed
        case "missedStop": .missedStop
        default: nil
        }
        turn.trainMoving = model.trainMoving
        turn.closedLines = model.closedLines.compactMap(clean)
        if let from = clean(model.closedFrom), let to = clean(model.closedTo) {
            turn.closedSections = [.init(line: turn.closedLines.first, from: from, to: to)]
            turn.closedLines.removeAll { $0 == turn.closedSections[0].line }
        }
        turn.closedStations = model.closedStations.compactMap(clean)
        turn.currentRouteBlocked = model.currentRouteBlocked
        turn.stepFree = model.stepFree ? true : nil
        turn.walking = model.walking == "yes" ? true : (model.walking == "no" ? false : nil)
        turn.fewerChanges = model.fewerChanges
        turn.asksForUnavailableInfo = model.asksForUnavailableInfo
        return turn
    }
}
