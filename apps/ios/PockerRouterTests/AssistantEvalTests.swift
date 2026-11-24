import Foundation
import Testing
@testable import PockerRouter

/// Labelled passenger messages in `shared/fixtures/assistant-eval.json`,
/// scored field by field. The web client scores the same file.
enum AssistantEval {
    struct Case: Decodable {
        struct Expect: Decodable {
            var currentStation: String?
            var destination: String?
            var unassignedStation: String?
            var line: String?
            var situation: String?
            var closedLines: [String]?
            var closedStations: [String]?
            var closedSection: [String]?
            var trainMoving: Bool?
            var currentRouteBlocked: Bool?
            var stepFree: Bool?
            var walking: Bool?
            var fewerChanges: Bool?
            var asksForUnavailableInfo: Bool?
        }
        let text: String
        let expect: Expect
    }

    static let cases: [Case] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../shared/fixtures/assistant-eval.json").standardized
        struct File: Decodable { let cases: [Case] }
        return try! JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }()

    /// What's wrong with a reading, or an empty list when it matches. Fields
    /// left out of a case must stay empty, so an invented station fails.
    static func mismatches(_ turn: ParsedTurn, _ expect: Case.Expect, matcher: StationMatcher) -> [String] {
        let graph = Fixture.graph
        func station(_ raw: String?) -> String? {
            guard let raw else { return nil }
            if case let .station(id) = matcher.match(raw, preferLine: turn.line.flatMap(matcher.line)) { return graph.stations[id]?.name }
            return "?\(raw)"
        }
        var problems: [String] = []
        func check<T: Equatable>(_ field: String, _ got: T, _ want: T) {
            if got != want { problems.append("\(field): got \(String(describing: got)), want \(String(describing: want))") }
        }
        check("currentStation", station(turn.currentStation), expect.currentStation)
        check("destination", station(turn.destination), expect.destination)
        if let want = expect.unassignedStation { check("unassignedStation", station(turn.unassignedStation), want) }
        check("line", turn.line.flatMap(matcher.line), expect.line)
        check("situation", turn.situation.map(situationKey), expect.situation)
        check("closedLines", Set(turn.closedLines.compactMap(matcher.line)), Set(expect.closedLines ?? []))
        check("closedStations", Set(turn.closedStations.compactMap(station)), Set(expect.closedStations ?? []))
        check("closedSection", turn.closedSections.first.map { [station($0.from), station($0.to)].compactMap { $0 } }, expect.closedSection)
        check("trainMoving", turn.trainMoving, expect.trainMoving ?? false)
        check("currentRouteBlocked", turn.currentRouteBlocked, expect.currentRouteBlocked ?? false)
        check("stepFree", turn.stepFree ?? false, expect.stepFree ?? false)
        check("walking", turn.walking, expect.walking)
        check("fewerChanges", turn.fewerChanges, expect.fewerChanges ?? false)
        check("asksForUnavailableInfo", turn.asksForUnavailableInfo, expect.asksForUnavailableInfo ?? false)
        return problems
    }

    static func situationKey(_ situation: Situation) -> String {
        switch situation {
        case .held: "held"
        case .terminating: "terminating"
        case .lineClosed: "lineClosed"
        case .missedStop: "missedStop"
        }
    }

    /// Runs a reader over every case and returns how many passed.
    static func score(_ interpreter: any TurnInterpreting) async -> (passed: Int, failures: [String]) {
        let matcher = StationMatcher(graph: Fixture.graph)
        var passed = 0
        var failures: [String] = []
        for item in cases {
            let (turn, _) = await interpreter.interpret(item.text, context: TurnContext(), matcher: matcher)
            let problems = mismatches(turn, item.expect, matcher: matcher)
            if problems.isEmpty { passed += 1 } else { failures.append("“\(item.text)”: \(problems.joined(separator: "; "))") }
        }
        return (passed, failures)
    }
}

struct AssistantEvalTests {
    /// Keyword rules are the floor every phone gets. This must not regress.
    @Test func keywordRulesScore() async {
        let (passed, failures) = await AssistantEval.score(KeywordInterpreter())
        print("Keyword rules: \(passed)/\(AssistantEval.cases.count)\n" + failures.joined(separator: "\n"))
        #expect(passed >= AssistantEval.keywordFloor, "\(failures.joined(separator: "\n"))")
    }

    /// Apple Intelligence plus grounding. Runs only where the model can.
    @Test(.enabled(if: AssistantAvailability.current == .onDevice))
    func onDeviceModelScore() async {
        let interpreter = HybridInterpreter(timeout: .seconds(20), cloudAllowed: { false })
        let (passed, failures) = await AssistantEval.score(interpreter)
        print("Apple Intelligence: \(passed)/\(AssistantEval.cases.count)\n" + failures.joined(separator: "\n"))
        #expect(passed >= AssistantEval.modelFloor)
    }

    /// Gemini through Firebase AI Logic. Runs only when asked for, with
    /// network access and Firebase configured: POCKETROUTE_EVAL_GEMINI=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKETROUTE_EVAL_GEMINI"] == "1" && CloudAssist.isConfigured))
    func geminiScore() async {
        let interpreter = HybridInterpreter(timeout: .seconds(20), onDeviceAvailable: { false }, cloudAllowed: { true })
        let (passed, failures) = await AssistantEval.score(interpreter)
        print("Gemini: \(passed)/\(AssistantEval.cases.count)\n" + failures.joined(separator: "\n"))
        #expect(passed >= AssistantEval.modelFloor)
    }
}

extension AssistantEval {
    static let keywordFloor = 29
    /// Models can be rate-limited mid-run and fall back to keywords for a
    /// message, so their runs are held to a slightly lower bar.
    static let modelFloor = 26
}

struct CloudReaderTests {
    let matcher = StationMatcher(graph: Fixture.graph)

    @Test func geminiJSONMapsToTheSameFieldsAsTheOnDeviceModel() throws {
        let json = #"{"currentStation":"Camden","destination":"Warren St","line":"Northern","situation":"held","trainMoving":false,"closedLines":["Northern"],"closedFrom":"Camden","closedTo":"Euston","closedStations":[],"currentRouteBlocked":false,"stepFree":true,"walking":"no","fewerChanges":false,"asksForUnavailableInfo":false}"#
        let turn = CloudParser.turn(from: try JSONDecoder().decode(CloudParser.Reply.self, from: Data(json.utf8)))
        #expect(turn.currentStation == "Camden")
        #expect(turn.situation == .held)
        #expect(turn.closedSections == [.init(line: "Northern", from: "Camden", to: "Euston")])
        #expect(turn.closedLines.isEmpty)
        #expect(turn.stepFree == true)
        #expect(turn.walking == false)
    }

    @Test func missingFieldsAreEmptyNotInvented() throws {
        let turn = CloudParser.turn(from: try JSONDecoder().decode(CloudParser.Reply.self, from: Data(#"{"destination":"null"}"#.utf8)))
        #expect(turn.isEmpty)
    }

    @Test func geminiIsUsedWhenTheOnDeviceModelCantRun() async {
        let interpreter = HybridInterpreter(onDeviceAvailable: { false }, cloudAllowed: { true },
                                            cloud: { _, _ in var turn = ParsedTurn(); turn.destination = "Warren Street"; return turn })
        let (turn, by) = await interpreter.interpret("need warren street", context: TurnContext(), matcher: matcher)
        #expect(by == .cloud)
        #expect(turn.destination == "Warren Street")
    }

    @Test func geminiReadingsAreGroundedToo() async {
        let interpreter = HybridInterpreter(onDeviceAvailable: { false }, cloudAllowed: { true },
                                            cloud: { _, _ in var turn = ParsedTurn(); turn.destination = "Brixton"; return turn })
        let (turn, _) = await interpreter.interpret("my train is held", context: TurnContext(), matcher: matcher)
        #expect(turn.destination == nil)
    }

    @Test func onDeviceFailureFallsBackToGeminiThenKeywords() async {
        struct Failure: Error {}
        let both = HybridInterpreter(onDeviceAvailable: { true }, cloudAllowed: { true },
                                     onDevice: { _, _ in throw Failure() }, cloud: { _, _ in ParsedTurn() })
        #expect(await both.interpret("held at bank", context: TurnContext(), matcher: matcher).1 == .cloud)

        let neither = HybridInterpreter(onDeviceAvailable: { true }, cloudAllowed: { false }, onDevice: { _, _ in throw Failure() })
        #expect(await neither.interpret("held at bank", context: TurnContext(), matcher: matcher).1 == .keywords)
    }

    /// Readings Apple Intelligence really produced on the simulator.
    @Test func inventedClosuresAreDropped() async {
        func model(_ fields: ModelFields) -> HybridInterpreter {
            HybridInterpreter(onDeviceAvailable: { true }, cloudAllowed: { false }, onDevice: { _, _ in OnDeviceParser.turn(from: fields) })
        }
        let cases: [(String, ModelFields)] = [
            ("Held at Camden on the Northern, need Warren St",
             ModelFields(currentStation: "Camden", destination: "Warren St", line: "Northern", closedLines: ["Northern"], closedStations: ["Warren St"])),
            ("no trains between Camden and Euston", ModelFields(closedFrom: "Camden", closedTo: "Euston", closedStations: ["Euston", "Camden Town"])),
            ("Northern line suspended between Kennington and Stockwell", ModelFields(closedLines: ["Northern"], closedFrom: "Kennington", closedTo: "Stockwell")),
            ("I have a buggy so lifts only", ModelFields(stepFree: true, fewerChanges: true)),
        ]
        for (text, fields) in cases {
            let (turn, _) = await model(fields).interpret(text, context: TurnContext(), matcher: matcher)
            let expect = AssistantEval.cases.first { $0.text == text }!.expect
            #expect(AssistantEval.mismatches(turn, expect, matcher: matcher).isEmpty, "\(text): \(AssistantEval.mismatches(turn, expect, matcher: matcher))")
        }
    }

    @Test func geminiIsOffUntilThePassengerOptsIn() throws {
        let defaults = try #require(UserDefaults(suiteName: "Cloud-\(UUID())"))
        #expect(!CloudAssist.canRun(defaults: defaults))
    }
}
