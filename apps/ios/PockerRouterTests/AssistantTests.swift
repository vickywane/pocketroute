import Foundation
import Testing
@testable import PockerRouter

struct StationMatcherTests {
    let matcher = StationMatcher(graph: Fixture.graph)

    func name(_ match: StationMatcher.Match) -> String? {
        if case let .station(id) = match { return Fixture.graph.stations[id]?.name }
        return nil
    }

    @Test func everyStationMatchesItsOwnName() {
        for station in Fixture.graph.stations.values {
            #expect(matcher.match(station.name) == .station(station.id), "\(station.name)")
        }
    }

    @Test func shortFormsAndTyposResolve() {
        #expect(name(matcher.match("kings cross")) == "King's Cross St. Pancras")
        #expect(name(matcher.match("KX")) == "King's Cross St. Pancras")
        #expect(name(matcher.match("warren st")) == "Warren Street")
        #expect(name(matcher.match("Tottenham Court Rd")) == "Tottenham Court Road")
        #expect(name(matcher.match("picadilly circus")) == "Piccadilly Circus")
        #expect(name(matcher.match("st pauls")) == "St. Paul's")
        #expect(name(matcher.match("Camden")) == "Camden Town")
        #expect(name(matcher.match("elephant & castle station")) == "Elephant & Castle")
    }

    @Test func sameNamedStationsAreAskedAboutUnlessTheLineDecides() {
        guard case let .ambiguous(ids) = matcher.match("Edgware Road") else {
            Issue.record("Edgware Road should be ambiguous"); return
        }
        #expect(ids.count == 2)
        #expect(name(matcher.match("Edgware Road", preferLine: "bakerloo")) == "Edgware Road (Bakerloo)")
    }

    @Test func unknownNamesSuggestNeighboursAndNeverGuess() {
        guard case let .unknown(suggestions) = matcher.match("Hogwarts") else {
            Issue.record("Hogwarts is not a Tube station"); return
        }
        #expect(suggestions.count <= 3)
    }

    @Test func victoriaIsAStationUnlessItIsTheVictoriaLine() {
        #expect(matcher.lineMentions(in: "I'm at Victoria").isEmpty)
        #expect(matcher.lineMentions(in: "the Victoria line is closed").first?.lineId == "victoria")
        #expect(matcher.line("H&C") == "hammersmith-city")
        #expect(matcher.mentions(in: "Waterloo & City line is shut").isEmpty)
    }
}

struct KeywordParserTests {
    let parser = KeywordParser(matcher: StationMatcher(graph: Fixture.graph))

    @Test func readsAFullDescription() {
        let turn = parser.parse("Held at Camden Town on the Northern line, I need to get to Warren St")
        #expect(turn.currentStation == "camden town")
        #expect(turn.destination == "warren street")
        #expect(turn.line == "northern")
        #expect(turn.situation == .held)
    }

    @Test func readsClosuresOfLinesSectionsAndStations() {
        #expect(parser.parse("The Victoria line is suspended").closedLines == ["victoria"])
        let section = parser.parse("No service between Camden Town and Euston")
        #expect(section.closedSections == [.init(line: nil, from: "camden town", to: "euston")])
        #expect(parser.parse("Bank is closed").closedStations == ["bank"])
        #expect(parser.parse("avoid Bank please").closedStations == ["bank"])
    }

    @Test func quickRepliesMapToFlags() {
        #expect(parser.parse("Train is moving again").trainMoving)
        #expect(parser.parse("Branch isn’t running").currentRouteBlocked)
        #expect(parser.parse("Step-free only").stepFree == true)
        #expect(parser.parse("I’d rather walk").walking == true)
        #expect(parser.parse("I don't want to walk").walking == false)
    }

    @Test func bankBranchIsNotBankStation() {
        let turn = parser.parse("the Bank branch isn't running")
        #expect(turn.closedStations.isEmpty)
        #expect(turn.currentRouteBlocked)
    }

    @Test func liveQuestionsAreFlaggedNotAnswered() {
        let turn = parser.parse("When will the Victoria line be running again?")
        #expect(turn.asksForUnavailableInfo)
        #expect(turn.closedLines.isEmpty)
    }
}

struct GroundingTests {
    let matcher = StationMatcher(graph: Fixture.graph)

    @Test func dropsStationsThePassengerNeverSaid() {
        var model = ParsedTurn()
        model.currentStation = "Camden Town"
        model.destination = "Oxford Circus" // invented
        model.closedLines = ["Victoria"]   // invented
        let kept = Grounding.keepSaid(model, in: "stuck at camden", matcher: matcher)
        #expect(kept.currentStation == "Camden Town")
        #expect(kept.destination == nil)
        #expect(kept.closedLines.isEmpty)
    }

    @Test func keepsCorrectedSpellingsAndAliases() {
        var model = ParsedTurn()
        model.destination = "King's Cross St. Pancras"
        model.currentStation = "Warren Street"
        let kept = Grounding.keepSaid(model, in: "at warren st, going to kx", matcher: matcher)
        #expect(kept.destination == "King's Cross St. Pancras")
        #expect(kept.currentStation == "Warren Street")
    }
}

struct TrustFlagsTests {
    let parser = KeywordParser(matcher: StationMatcher(graph: Fixture.graph))

    @Test func sectionClosureIsNotAlsoAStationClosureOrABlockedRoute() {
        // What the on-device model returned in the simulator for this message.
        let text = "trains not running between camden and euston"
        var model = ParsedTurn()
        model.closedSections = [.init(line: nil, from: "Camden", to: "Euston")]
        model.closedStations = ["Euston"]
        model.currentRouteBlocked = true
        model.asksForUnavailableInfo = true
        let trusted = Grounding.trustFlags(model, keywords: parser.parse(text), text: text)
        #expect(trusted.closedStations.isEmpty)
        #expect(!trusted.currentRouteBlocked)
        #expect(!trusted.asksForUnavailableInfo)
        #expect(trusted.closedSections.count == 1)
    }

    @Test func realQuestionsKeepTheLiveInfoFlag() {
        var model = ParsedTurn()
        model.asksForUnavailableInfo = true
        let text = "is the jubilee line ok?"
        #expect(Grounding.trustFlags(model, keywords: parser.parse(text), text: text).asksForUnavailableInfo)
    }
}

struct TurnPlannerTests {
    let planner = TurnPlanner(graph: Fixture.graph)

    @Test func sectionClosureBecomesSegmentsOnTheSharedLine() {
        var turn = ParsedTurn()
        turn.closedSections = [.init(line: nil, from: "Camden Town", to: "Euston")]
        let planned = planner.plan(turn, state: PlannerState())
        #expect(!planned.avoidSegments.isEmpty)
        #expect(planned.avoidSegments.allSatisfy { $0.hasPrefix("northern|") })
    }

    @Test func ambiguousStationBecomesAQuestionWithChoices() {
        var turn = ParsedTurn()
        turn.currentStation = "Hammersmith"
        let planned = planner.plan(turn, state: PlannerState())
        #expect(planned.origin == nil)
        #expect(planned.question?.field == .origin)
        #expect(planned.question?.choices.count == 2)
    }

    @Test func bareNameAnswersTheQuestionAsked() {
        var turn = ParsedTurn()
        turn.unassignedStation = "Euston"
        let planned = planner.plan(turn, state: PlannerState(origin: Fixture.id("Camden Town"), awaiting: .destination))
        #expect(planned.destination == Fixture.id("Euston"))
    }
}

@MainActor
struct ConversationTests {
    func session() throws -> RerouteSession {
        RerouteSession(defaults: try #require(UserDefaults(suiteName: "Conversation-\(UUID())")), interpreter: KeywordInterpreter())
    }

    @Test func oneSentenceGetsStraightToRoutes() async throws {
        let session = try session()
        await session.describe("Held at Camden Town on the Northern line, going to Warren Street", graph: Fixture.graph)
        #expect(session.originId == Fixture.id("Camden Town"))
        #expect(session.destinationId == Fixture.id("Warren Street"))
        #expect(session.onLine == "northern")
        #expect(session.situations.contains(.held))
        #expect(!session.latestPlans.isEmpty)
        #expect(session.thread.last?.tags.contains("At Camden Town") == true)
    }

    @Test func missingStationIsAskedForThenAnswered() async throws {
        let session = try session()
        await session.describe("I'm going to Warren Street", graph: Fixture.graph)
        #expect(session.awaiting == .origin)
        #expect(session.latestPlans.isEmpty)
        await session.followUp("Euston", graph: Fixture.graph)
        #expect(session.originId == Fixture.id("Euston"))
        #expect(session.awaiting == nil)
        #expect(!session.latestPlans.isEmpty)
    }

    @Test func tappingAChoiceResolvesAnAmbiguousStation() async throws {
        let session = try session()
        session.destinationId = Fixture.id("Baker Street")
        await session.describe("I'm at Edgware Road", graph: Fixture.graph)
        #expect(session.awaiting == .origin)
        let choice = try #require(session.thread.last?.choices.first)
        session.choose(choice, graph: Fixture.graph)
        #expect(session.originId == choice)
        #expect(!session.latestPlans.isEmpty)
    }

    @Test func closedLineIsAvoidedInTheNextRoutes() async throws {
        let session = try session()
        session.setOrigin(Fixture.id("Euston"), confirmed: true)
        session.destinationId = Fixture.id("Oxford Circus")
        session.startSearch(graph: Fixture.graph, stepFree: false, walking: false)
        #expect(session.latestPlans.first?.rideLegs.first?.lineId == "victoria")
        await session.followUp("the Victoria line is closed", graph: Fixture.graph)
        #expect(session.request?.avoidLines.contains("victoria") == true)
        #expect(session.thread.last?.plans.isEmpty == false)
        #expect(session.latestPlans.allSatisfy { plan in !plan.legs.contains { $0.lineId == "victoria" } })
    }

    @Test func liveQuestionGetsAnHonestAnswerAndKeepsRoutes() async throws {
        let session = try session()
        session.setOrigin(Fixture.id("Camden Town"), confirmed: true)
        session.destinationId = Fixture.id("Warren Street")
        session.startSearch(graph: Fixture.graph, stepFree: false, walking: true)
        let before = session.latestPlans
        await session.followUp("when will my train move?", graph: Fixture.graph)
        #expect(session.latestPlans == before)
        #expect(session.thread.last?.replyText.contains("can’t see live service") == true)
    }
}
