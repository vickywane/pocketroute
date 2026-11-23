import CoreLocation
import Foundation
import Testing
@testable import PockerRouter

/// Loads the bundled TfL snapshot once for all tests.
enum Fixture {
    static let graph: NetworkGraph = {
        let url = Bundle.main.url(forResource: "london-underground-network-v1", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        return NetworkGraph(snapshot: try! JSONDecoder().decode(NetworkSnapshot.self, from: data))
    }()

    static func id(_ name: String) -> String {
        guard let station = graph.stations.values.first(where: { $0.name == name }) else {
            fatalError("No station named \(name)")
        }
        return station.id
    }

    static func names(_ leg: RouteLeg) -> [String] { leg.stops.compactMap { graph.stations[$0]?.name } }
}

struct RouteEngineTests {
    let engine = RouteEngine(graph: Fixture.graph)

    @Test func camdenToWarrenStreetFastestIsDirectViaCharingCrossBranch() throws {
        let request = RerouteRequest(origin: Fixture.id("Camden Town"), destination: Fixture.id("Warren Street"), onLine: "northern")
        let fastest = try #require(engine.options(for: request).first { $0.badge == .fastest })
        #expect(fastest.rideLegs.count == 1)
        let leg = try #require(fastest.rideLegs.first)
        #expect(leg.lineId == "northern")
        #expect(Fixture.names(leg) == ["Camden Town", "Mornington Crescent", "Euston", "Warren Street"])
        // The old hardcoded card told people to change to the Victoria line here.
        #expect(!fastest.legs.contains { $0.lineId == "victoria" })
    }

    @Test func branchNotRunningFallsBackToEustonAndVictoria() throws {
        var request = RerouteRequest(origin: Fixture.id("Camden Town"), destination: Fixture.id("Warren Street"), onLine: "northern")
        let first = try #require(engine.options(for: request).first?.rideLegs.first)
        for (a, b) in zip(first.stops, first.stops.dropFirst()) {
            request.avoidSegments.insert(RerouteRequest.segmentKey(line: "northern", a, b))
        }
        request.includeWalking = false
        let plan = try #require(engine.options(for: request).first)
        #expect(plan.rideLegs.map(\.lineId) == ["northern", "victoria"])
        #expect(Fixture.names(plan.rideLegs[0]) == ["Camden Town", "Euston"])
        #expect(Fixture.names(plan.rideLegs[1]) == ["Euston", "Warren Street"])
    }

    @Test func crossingNorthernBranchesNeedsAChangeOfTrain() throws {
        // Angel is on the Bank branch, Mornington Crescent on the Charing Cross branch.
        var request = RerouteRequest(origin: Fixture.id("Angel"), destination: Fixture.id("Mornington Crescent"))
        request.avoidLines = Set(Fixture.graph.lineNames.keys).subtracting(["northern"])
        request.includeWalking = false
        let plan = try #require(engine.options(for: request).first)
        #expect(plan.rideLegs.allSatisfy { $0.lineId == "northern" })
        #expect(plan.rideLegs.count >= 2, "One train can't run Bank branch → Charing Cross branch southbound")
    }

    @Test func closedLineIsNeverUsed() {
        var request = RerouteRequest(origin: Fixture.id("Camden Town"), destination: Fixture.id("Warren Street"), onLine: "northern")
        request.avoidLines = ["northern"]
        let plans = engine.options(for: request)
        #expect(!plans.isEmpty)
        #expect(plans.allSatisfy { plan in !plan.legs.contains { $0.lineId == "northern" } })
    }

    @Test func stepFreeOnlyChangesAtLiftStations() {
        var request = RerouteRequest(origin: Fixture.id("Brixton"), destination: Fixture.id("Baker Street"))
        request.stepFreeOnly = true
        request.includeWalking = false
        for plan in engine.options(for: request) {
            for leg in plan.rideLegs.dropFirst() {
                #expect(Fixture.graph.stations[leg.stops[0]]?.liftAccess == true)
            }
        }
    }

    @Test func offersAnAlternativeEvenWhenTheOriginHasOneLine() {
        // Brixton is served only by the Victoria line.
        var request = RerouteRequest(origin: Fixture.id("Brixton"), destination: Fixture.id("Warren Street"))
        request.includeWalking = false
        let plans = engine.options(for: request)
        #expect(plans.count >= 2)
        #expect(Set(plans.map(\.id)).count == plans.count)
    }

    @Test func walkingOptionFollowsPreference() {
        var request = RerouteRequest(origin: Fixture.id("Camden Town"), destination: Fixture.id("Warren Street"))
        #expect(engine.options(for: request).contains { $0.isWalkOnly })
        request.includeWalking = false
        #expect(!engine.options(for: request).contains { $0.isWalkOnly })
    }

    @Test func everyStationPairNearbyHasARoute() {
        for (from, to) in [("Bank", "Paddington"), ("Stratford", "Heathrow Terminal 5"), ("Morden", "High Barnet")] {
            let request = RerouteRequest(origin: Fixture.id(from), destination: Fixture.id(to))
            #expect(!engine.options(for: request).filter { !$0.isWalkOnly }.isEmpty, "\(from) → \(to)")
        }
    }

    @Test func legsTellTheTruthAboutDirection() throws {
        let request = RerouteRequest(origin: Fixture.id("Euston"), destination: Fixture.id("Warren Street"), onLine: "victoria")
        let plan = try #require(engine.options(for: request).first { !$0.isWalkOnly })
        let leg = try #require(plan.rideLegs.first)
        if case let .ride(_, towards) = leg.kind { #expect(towards != nil) }
    }
}

struct NetworkGraphTests {
    @Test func displayNamesAreCleaned() {
        #expect(NetworkGraph.displayName("Paddington (H&C Line)-Underground") == "Paddington (H&C Line)")
        #expect(NetworkGraph.displayName("Bank Underground Station") == "Bank")
        #expect(!Fixture.graph.stations.values.contains { $0.name.contains("Underground") })
    }

    @Test func nearestStationUsesTheFullMap() throws {
        // Just outside Camden Town station.
        let fix = CLLocation(latitude: 51.5394, longitude: -0.1427)
        let match = try #require(Fixture.graph.nearestStation(to: fix, within: 2_000))
        #expect(match.station.name == "Camden Town")
        // Brixton is not in the old 16-station sample; the full map must find it.
        let brixton = try #require(Fixture.graph.nearestStation(to: CLLocation(latitude: 51.4627, longitude: -0.1145), within: 2_000))
        #expect(brixton.station.name == "Brixton")
    }

    @Test func nothingIsSuggestedFarFromTheNetwork() {
        #expect(Fixture.graph.nearestStation(to: CLLocation(latitude: 52.2053, longitude: 0.1218), within: 2_000) == nil) // Cambridge
    }
}

@MainActor
struct StationLocatorTests {
    @Test func suggestionIsRecomputedWhenTheMapLoads() throws {
        let defaults = try #require(UserDefaults(suiteName: "StationLocatorTests-\(UUID())"))
        let locator = StationLocator(defaults: defaults)
        let manager = CLLocationManager()
        let fix = CLLocation(coordinate: .init(latitude: 51.4627, longitude: -0.1145), altitude: 0,
                             horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: Date())
        // The fix arrives before the map is loaded…
        locator.locationManager(manager, didUpdateLocations: [fix])
        #expect(locator.suggestion == nil)
        // …and is matched once it is.
        locator.graph = Fixture.graph
        #expect(locator.suggestion?.name == "Brixton")
        #expect(locator.status == .found)
    }

    @Test func newestFixWinsAndRoughFixesAreIgnored() throws {
        let defaults = try #require(UserDefaults(suiteName: "StationLocatorTests-\(UUID())"))
        let locator = StationLocator(defaults: defaults)
        locator.graph = Fixture.graph
        let manager = CLLocationManager()
        let old = CLLocation(coordinate: .init(latitude: 51.5394, longitude: -0.1427), altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: Date().addingTimeInterval(-60))
        let new = CLLocation(coordinate: .init(latitude: 51.4627, longitude: -0.1145), altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: Date())
        locator.locationManager(manager, didUpdateLocations: [old, new])
        #expect(locator.suggestion?.name == "Brixton")

        let rough = CLLocation(coordinate: .init(latitude: 51.5394, longitude: -0.1427), altitude: 0, horizontalAccuracy: 3_000, verticalAccuracy: -1, timestamp: Date())
        locator.locationManager(manager, didUpdateLocations: [rough])
        #expect(locator.suggestion?.name == "Brixton")
    }

    @Test func lastFixSurvivesRelaunch() throws {
        let suite = "StationLocatorTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let first = StationLocator(defaults: defaults)
        first.locationManager(CLLocationManager(), didUpdateLocations: [
            CLLocation(coordinate: .init(latitude: 51.5394, longitude: -0.1427), altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: Date())
        ])
        let relaunched = StationLocator(defaults: defaults)
        relaunched.graph = Fixture.graph
        #expect(relaunched.suggestion?.name == "Camden Town")
    }
}

@MainActor
struct RerouteSessionTests {
    @Test func gpsSuggestionDoesNotOverrideAManualChoice() throws {
        let session = RerouteSession(defaults: try #require(UserDefaults(suiteName: "Session-\(UUID())")), interpreter: KeywordInterpreter())
        session.applySuggestion(Fixture.id("Brixton"))
        #expect(session.originId == Fixture.id("Brixton"))
        session.setOrigin(Fixture.id("Bank"), confirmed: true)
        session.applySuggestion(Fixture.id("Camden Town"))
        #expect(session.originId == Fixture.id("Bank"))
    }

    @Test func unrecognisedFollowUpSaysSoAndKeepsRoutes() async throws {
        let session = RerouteSession(defaults: try #require(UserDefaults(suiteName: "Session-\(UUID())")), interpreter: KeywordInterpreter())
        session.setOrigin(Fixture.id("Camden Town"), confirmed: true)
        session.destinationId = Fixture.id("Warren Street")
        session.onLine = "northern"
        session.startSearch(graph: Fixture.graph, stepFree: false, walking: true)
        let before = session.latestPlans
        await session.followUp("what about the weather", graph: Fixture.graph)
        #expect(session.latestPlans == before)
        #expect(session.thread.last?.replyText.contains("haven’t changed") == true)
    }

    @Test func stepFreeChipDoesNotChangeTheSavedSetting() async throws {
        let defaults = try #require(UserDefaults(suiteName: "Session-\(UUID())"))
        let session = RerouteSession(defaults: defaults, interpreter: KeywordInterpreter())
        session.setOrigin(Fixture.id("Camden Town"), confirmed: true)
        session.destinationId = Fixture.id("Warren Street")
        session.startSearch(graph: Fixture.graph, stepFree: false, walking: true)
        await session.followUp("Step-free only", graph: Fixture.graph, isQuickReply: true)
        #expect(session.request?.stepFreeOnly == true)
        #expect(defaults.object(forKey: Preference.stepFree) == nil)
        session.startSearch(graph: Fixture.graph, stepFree: false, walking: true)
        #expect(session.request?.stepFreeOnly == false)
    }

    @Test func recentReroutesArePersistedAndReopenTheRightStations() throws {
        let defaults = try #require(UserDefaults(suiteName: "Session-\(UUID())"))
        let session = RerouteSession(defaults: defaults, interpreter: KeywordInterpreter())
        session.setOrigin(Fixture.id("Bank"), confirmed: true)
        session.destinationId = Fixture.id("King's Cross St. Pancras")
        session.startSearch(graph: Fixture.graph, stepFree: false, walking: true)
        session.start(try #require(session.latestPlans.first), graph: Fixture.graph)

        let reopened = RerouteSession(defaults: defaults, interpreter: KeywordInterpreter())
        let recent = try #require(reopened.recents.first)
        reopened.reopen(recent, graph: Fixture.graph, stepFree: false, walking: true)
        #expect(reopened.originId == Fixture.id("Bank"))
        #expect(reopened.destinationId == Fixture.id("King's Cross St. Pancras"))
    }
}

@MainActor
struct FollowUpTests {
    @Test func branchClosureKeepsTheOnlyWayOutOfTheStation() async throws {
        let session = RerouteSession(defaults: try #require(UserDefaults(suiteName: "FollowUp-\(UUID())")), interpreter: KeywordInterpreter())
        session.setOrigin(Fixture.id("Brixton"), confirmed: true)
        session.destinationId = Fixture.id("Warren Street")
        session.startSearch(graph: Fixture.graph, stepFree: false, walking: false)
        await session.followUp("Branch isn’t running", graph: Fixture.graph, isQuickReply: true)
        #expect(!session.latestPlans.isEmpty)
    }
}
