import FirebaseAILogic
import FirebaseCore
import FirebaseRemoteConfig
import FoundationModels
import Foundation
import Network
import os

/// Gemini through Firebase AI Logic. It reads a message into the same
/// `ModelTurn` fields as the on-device model, as JSON constrained by a schema,
/// and its reading goes through the same grounding as every other reader.
/// It only runs when the passenger has opted in, the phone is online, and
/// Remote Config hasn't switched it off.
struct CloudParser: Sendable {
    static let defaultModel = "gemini-3.1-flash-lite"

    /// The JSON Gemini returns. Mirrors `ModelTurn`.
    struct Reply: Decodable {
        var currentStation: String?
        var destination: String?
        var line: String?
        var situation: String?
        var trainMoving: Bool?
        var closedLines: [String]?
        var closedFrom: String?
        var closedTo: String?
        var closedStations: [String]?
        var currentRouteBlocked: Bool?
        var stepFree: Bool?
        var walking: String?
        var fewerChanges: Bool?
        var asksForUnavailableInfo: Bool?
    }

    static let schema = Schema.object(
        properties: [
            "currentStation": .string(description: "Station the passenger is at or stuck at now, copied from their words", nullable: true),
            "destination": .string(description: "Station the passenger wants to get to, copied from their words", nullable: true),
            "line": .string(description: "Tube line the passenger is or was on, for example Northern", nullable: true),
            "situation": .enumeration(values: ["held", "terminating", "lineClosed", "missedStop"], description: "What happened, if said", nullable: true),
            "trainMoving": .boolean(description: "True only if they say their train is moving again"),
            "closedLines": .array(items: .string(), description: "Tube lines they say are closed, suspended or not running"),
            "closedFrom": .string(description: "Station a closed section starts at, for 'between A and B'", nullable: true),
            "closedTo": .string(description: "Station that closed section ends at", nullable: true),
            "closedStations": .array(items: .string(), description: "Stations they say are closed or want to avoid"),
            "currentRouteBlocked": .boolean(description: "True if they say the suggested route, that branch or that train can't be used"),
            "stepFree": .boolean(description: "True if they need step-free access, lifts, or can't use stairs"),
            "walking": .enumeration(values: ["yes", "no"], description: "yes if happy to walk, no if they don't want to walk", nullable: true),
            "fewerChanges": .boolean(description: "True if they want fewer changes or a direct train"),
            "asksForUnavailableInfo": .boolean(description: "True if they ask for live status, delays, when a train will move, platforms or exits"),
        ],
        optionalProperties: ["currentStation", "destination", "line", "situation", "closedFrom", "closedTo", "walking"]
    )

    func parse(_ text: String, context: TurnContext) async throws -> ParsedTurn {
        if #available(iOS 27.0, *) { return try await parseInSession(text, context: context) }
        return try await parseWithSchema(text, context: context)
    }

    /// iOS 27+: Gemini through Firebase AI Logic's `GeminiLanguageModel`, driven by
    /// the same Foundation Models session and `@Generable` type as the on-device
    /// reader, so both halves of the hybrid share one request and one schema.
    @available(iOS 27.0, *)
    private func parseInSession(_ text: String, context: TurnContext) async throws -> ParsedTurn {
        let model = FirebaseAI.firebaseAI(backend: .googleAI()).geminiLanguageModel(name: CloudAssist.modelName)
        let session = LanguageModelSession(model: model, instructions: OnDeviceParser.instructions)
        let response = try await session.respond(to: OnDeviceParser.prompt(text, context: context), generating: CloudTurn.self,
                                                 options: GenerationOptions(maximumResponseTokens: 400))
        return Self.turn(from: response.content)
    }

    static func turn(from model: CloudTurn) -> ParsedTurn {
        OnDeviceParser.turn(from: ModelFields(
            currentStation: model.currentStation, destination: model.destination, line: model.line,
            situation: model.situation, trainMoving: model.trainMoving, closedLines: model.closedLines,
            closedFrom: model.closedFrom, closedTo: model.closedTo, closedStations: model.closedStations,
            currentRouteBlocked: model.currentRouteBlocked, stepFree: model.stepFree, walking: model.walking,
            fewerChanges: model.fewerChanges, asksForUnavailableInfo: model.asksForUnavailableInfo
        ))
    }

    /// iOS 26: Gemini's `generateContent` with a JSON schema that mirrors `ModelTurn`.
    private func parseWithSchema(_ text: String, context: TurnContext) async throws -> ParsedTurn {
        let model = FirebaseAI.firebaseAI(backend: .googleAI()).generativeModel(
            modelName: CloudAssist.modelName,
            generationConfig: GenerationConfig(maxOutputTokens: 400, responseMIMEType: "application/json",
                                               responseSchema: Self.schema, thinkingConfig: ThinkingConfig(thinkingLevel: .minimal)),
            systemInstruction: ModelContent(role: "system", parts: OnDeviceParser.instructions)
        )
        let response = try await model.generateContent(OnDeviceParser.prompt(text, context: context))
        guard let data = response.text?.data(using: .utf8) else { throw CloudError.emptyReply }
        return Self.turn(from: try JSONDecoder().decode(Reply.self, from: data))
    }

    static func turn(from reply: Reply) -> ParsedTurn {
        OnDeviceParser.turn(from: ModelFields(
            currentStation: reply.currentStation, destination: reply.destination, line: reply.line,
            situation: reply.situation, trainMoving: reply.trainMoving ?? false,
            closedLines: reply.closedLines ?? [], closedFrom: reply.closedFrom, closedTo: reply.closedTo,
            closedStations: reply.closedStations ?? [], currentRouteBlocked: reply.currentRouteBlocked ?? false,
            stepFree: reply.stepFree ?? false, walking: reply.walking, fewerChanges: reply.fewerChanges ?? false,
            asksForUnavailableInfo: reply.asksForUnavailableInfo ?? false
        ))
    }

    enum CloudError: Error { case emptyReply }
}

/// `ModelTurn` for Gemini. The schema Gemini receives marks every field as
/// required, so each choice has an explicit "none" and each name may be empty.
@Generable(description: "What a London Underground passenger just said about their disrupted journey")
struct CloudTurn {
    @Guide(description: "Station the passenger is at or stuck at now, copied from their words. Empty string if not said.")
    var currentStation: String?
    @Guide(description: "Station the passenger wants to get to, copied from their words. Empty string if not said.")
    var destination: String?
    @Guide(description: "Tube line the passenger is or was travelling on, for example Northern. Empty string if not said.")
    var line: String?
    @Guide(description: "What happened. none unless they say their train is held, terminating, the line is closed, or they missed their stop",
           .anyOf(["none", "held", "terminating", "lineClosed", "missedStop"]))
    var situation: String?
    @Guide(description: "True only if they say their train is moving again")
    var trainMoving: Bool
    @Guide(description: "Tube lines they say are closed, suspended or not running")
    var closedLines: [String]
    @Guide(description: "Station a closed section starts at, for 'between A and B'. Empty string otherwise.")
    var closedFrom: String?
    @Guide(description: "Station that closed section ends at. Empty string otherwise.")
    var closedTo: String?
    @Guide(description: "Stations they say are closed or want to avoid")
    var closedStations: [String]
    @Guide(description: "True if they say the suggested route, that branch or that train is not running or can't be used")
    var currentRouteBlocked: Bool
    @Guide(description: "True if they need step-free access, lifts, or can't use stairs")
    var stepFree: Bool
    @Guide(description: "yes if they say they're happy to walk, no if they say they don't want to walk, none otherwise",
           .anyOf(["none", "yes", "no"]))
    var walking: String?
    @Guide(description: "True if they want fewer changes or a direct train")
    var fewerChanges: Bool
    @Guide(description: "True if they ask for live service status, delays, when a train will move, platforms or exits")
    var asksForUnavailableInfo: Bool
}

/// Whether Gemini may be used for this message, and which model to call.
enum CloudAssist {
    static let enabledKey = "assistant_cloud_enabled"
    static let modelKey = "assistant_cloud_model"

    /// Firebase is set up, Remote Config allows it, the passenger opted in, and there is a network path.
    static func canRun(defaults: UserDefaults = .standard) -> Bool {
        isConfigured && remoteEnabled && defaults.bool(forKey: Preference.cloudAssist) && NetworkPath.shared.isOnline
    }

    static var isConfigured: Bool { FirebaseApp.app() != nil }

    static var remoteEnabled: Bool {
        guard isConfigured else { return false }
        return RemoteConfig.remoteConfig().configValue(forKey: enabledKey).boolValue
    }

    static var modelName: String {
        guard isConfigured else { return CloudParser.defaultModel }
        let value = RemoteConfig.remoteConfig().configValue(forKey: modelKey).stringValue
        return value.hasPrefix("gemini-") ? value : CloudParser.defaultModel
    }

    /// Called once after `FirebaseApp.configure()`.
    static func startRemoteConfig() {
        let config = RemoteConfig.remoteConfig()
        config.setDefaults([enabledKey: true as NSObject, modelKey: CloudParser.defaultModel as NSObject])
        config.fetchAndActivate { _, _ in }
    }
}

/// A network-path check that can be read from any thread.
final class NetworkPath: Sendable {
    static let shared = NetworkPath()
    private let online = OSAllocatedUnfairLock(initialState: false)
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [online] path in online.withLock { $0 = path.status == .satisfied } }
        monitor.start(queue: DispatchQueue(label: "pocketroute.networkpath"))
    }

    var isOnline: Bool { online.withLock { $0 } }
}
