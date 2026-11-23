import CoreLocation
import Foundation

/// What the passenger told us, in route-engine terms.
struct RerouteRequest: Equatable, Sendable {
    var origin: String
    var destination: String
    /// The line the passenger was on when things went wrong, if known.
    var onLine: String?
    /// Their train is held or terminating: staying on it has no advantage.
    var trainStuck = false
    var avoidLines: Set<String> = []
    /// Undirected line segments reported as not running ("line|a|b", a < b).
    var avoidSegments: Set<String> = []
    /// Stations reported closed: trains may pass through, but nobody can
    /// change, walk or get off there.
    var avoidStations: Set<String> = []
    var stepFreeOnly = false
    var includeWalking = true

    static func segmentKey(line: String, _ a: String, _ b: String) -> String {
        a < b ? "\(line)|\(a)|\(b)" : "\(line)|\(b)|\(a)"
    }
}

struct RouteLeg: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ride(lineId: String, towards: String?)
        case walk(metres: Int)
    }

    let kind: Kind
    /// Station ids in travel order, including both ends.
    let stops: [String]
    let minutes: Double

    var lineId: String? { if case let .ride(lineId, _) = kind { lineId } else { nil } }
    var stopCount: Int { max(stops.count - 1, 0) }
}

struct RoutePlan: Identifiable, Equatable, Sendable {
    enum Badge: String, Sendable { case fastest = "Fastest", fewestChanges = "Fewest changes" }

    let legs: [RouteLeg]
    let minutes: Int
    var badge: Badge?

    var id: String {
        legs.map { leg in
            switch leg.kind {
            case let .ride(lineId, _): "\(lineId):\(leg.stops.joined(separator: ","))"
            case .walk: "walk:\(leg.stops.joined(separator: ","))"
            }
        }.joined(separator: "/")
    }

    var rideLegs: [RouteLeg] { legs.filter { $0.lineId != nil } }
    var changes: Int { max(rideLegs.count - 1, 0) }
    var isWalkOnly: Bool { rideLegs.isEmpty }
}

/// Deterministic search over the offline network. The model (when connected)
/// may phrase answers, but every station, line and stop count comes from here.
struct RouteEngine: Sendable {
    let graph: NetworkGraph

    /// Wait for a first train when not already on one.
    var boardMinutes = 4.0
    /// Walk between platforms plus a wait.
    var changeMinutes = 5.0
    /// Walks longer than this are not offered.
    var maxWalkMinutes = 40.0

    func options(for request: RerouteRequest) -> [RoutePlan] {
        guard request.origin != request.destination,
              let origin = graph.stations[request.origin],
              let destination = graph.stations[request.destination] else { return [] }

        var plans: [RoutePlan] = []
        if let fastest = search(request, changeWeight: changeMinutes) { plans.append(fastest) }
        if let fewest = search(request, changeWeight: changeMinutes + 25), !plans.contains(where: { $0.id == fewest.id }) {
            plans.append(fewest)
        }
        // A genuinely different alternative: drop one leg of the best plan at a
        // time (keeping the first hop out of the origin, which may be the only
        // way out) and keep the quickest result that differs.
        if plans.count < 2, let best = plans.first {
            var alternatives: [RoutePlan] = []
            for (index, leg) in best.rideLegs.enumerated() {
                guard let line = leg.lineId else { continue }
                var alternative = request
                let pairs = Array(zip(leg.stops, leg.stops.dropFirst())).dropFirst(index == 0 ? 1 : 0)
                guard !pairs.isEmpty else { continue }
                for (a, b) in pairs { alternative.avoidSegments.insert(RerouteRequest.segmentKey(line: line, a, b)) }
                if let other = search(alternative, changeWeight: changeMinutes), other.id != best.id { alternatives.append(other) }
            }
            if let quickest = alternatives.min(by: { $0.minutes < $1.minutes }) { plans.append(quickest) }
        }

        if request.includeWalking {
            let metres = origin.location.distance(from: destination.location)
            let minutes = NetworkGraph.walkMinutes(metres: metres)
            if minutes <= maxWalkMinutes {
                let leg = RouteLeg(kind: .walk(metres: Int((metres * 1.3).rounded())), stops: [origin.id, destination.id], minutes: minutes)
                plans.append(RoutePlan(legs: [leg], minutes: max(Int(minutes.rounded()), 1)))
            }
        }

        plans.sort { $0.minutes < $1.minutes }
        if let fastestIndex = plans.indices.first { plans[fastestIndex].badge = .fastest }
        let transit = plans.filter { !$0.isWalkOnly }
        if let fewest = transit.min(by: { ($0.changes, $0.minutes) < ($1.changes, $1.minutes) }),
           fewest.id != plans.first?.id,
           fewest.changes < (plans.first?.changes ?? 0),
           let index = plans.firstIndex(where: { $0.id == fewest.id }) {
            plans[index].badge = .fewestChanges
        }
        return plans
    }

    // MARK: - Search

    /// A position in the search: at a station, optionally on a train of `line`
    /// that arrived from `previous` (so we know whether it can continue).
    private struct State: Hashable {
        let station: String
        let line: String?
        let previous: String?
        let isStart: Bool
    }

    private enum Step {
        case ride(line: String, from: String, to: String, minutes: Double, sameLineChange: Bool)
        case alight
        case walk(from: String, to: String, metres: Double, minutes: Double)
    }

    private func search(_ request: RerouteRequest, changeWeight: Double) -> RoutePlan? {
        let start = State(station: request.origin, line: nil, previous: nil, isStart: true)
        var cost: [State: Double] = [start: 0]
        var back: [State: (State, Step)] = [:]
        var frontier = MinQueue<State>()
        frontier.push(start, priority: 0)
        var visited = Set<State>()

        while let (state, current) = frontier.pop() {
            guard visited.insert(state).inserted else { continue }
            if state.station == request.destination {
                return buildPlan(end: state, back: back, request: request)
            }

            func relax(_ next: State, _ step: Step, _ extra: Double) {
                let total = current + extra
                if total < cost[next, default: .infinity] {
                    cost[next] = total
                    back[next] = (state, step)
                    frontier.push(next, priority: total)
                }
            }

            if let line = state.line {
                // Stay on this line.
                for edge in graph.edgesFrom[state.station, default: []] where edge.lineId == line && allowed(edge, request) {
                    if edge.to == state.previous { continue }
                    let through = state.previous.map { graph.continues(line: line, from: $0, via: state.station, to: edge.to) } ?? true
                    if !through && !canChange(at: state.station, request) { continue }
                    let penalty = through ? 0 : changeWeight
                    relax(State(station: edge.to, line: line, previous: state.station, isStart: false),
                          .ride(line: line, from: state.station, to: edge.to, minutes: edge.minutes, sameLineChange: !through),
                          edge.minutes + penalty)
                }
                // Get off to change lines or walk to a linked station.
                if canChange(at: state.station, request) {
                    relax(State(station: state.station, line: nil, previous: nil, isStart: false), .alight, 0)
                }
            } else {
                for edge in graph.edgesFrom[state.station, default: []] where allowed(edge, request) {
                    let wait: Double
                    if state.isStart {
                        let onThisTrain = edge.lineId == request.onLine && !request.trainStuck
                        wait = onThisTrain ? 0 : boardMinutes
                    } else {
                        wait = changeWeight
                    }
                    relax(State(station: edge.to, line: edge.lineId, previous: state.station, isStart: false),
                          .ride(line: edge.lineId, from: state.station, to: edge.to, minutes: edge.minutes, sameLineChange: false),
                          edge.minutes + wait)
                }
                for linked in graph.linkedStations[state.station, default: []] where !request.avoidStations.contains(linked) {
                    guard let a = graph.stations[state.station], let b = graph.stations[linked] else { continue }
                    let metres = a.location.distance(from: b.location)
                    let minutes = NetworkGraph.walkMinutes(metres: metres) + 2
                    relax(State(station: linked, line: nil, previous: nil, isStart: false),
                          .walk(from: a.id, to: b.id, metres: metres, minutes: minutes), minutes)
                }
            }
        }
        return nil
    }

    private func allowed(_ edge: NetworkGraph.Edge, _ request: RerouteRequest) -> Bool {
        !request.avoidLines.contains(edge.lineId)
            && !request.avoidSegments.contains(RerouteRequest.segmentKey(line: edge.lineId, edge.from, edge.to))
    }

    /// With step-free on, only change where TfL records lift access. Nobody
    /// changes at a closed station.
    private func canChange(at station: String, _ request: RerouteRequest) -> Bool {
        if request.avoidStations.contains(station) && station != request.origin { return false }
        return !request.stepFreeOnly || graph.stations[station]?.liftAccess == true
    }

    private func buildPlan(end: State, back: [State: (State, Step)], request: RerouteRequest) -> RoutePlan {
        var steps: [Step] = []
        var cursor = end
        while let (previous, step) = back[cursor] {
            steps.append(step)
            cursor = previous
        }
        steps.reverse()

        var legs: [RouteLeg] = []
        var currentLine: String?
        var stops: [String] = []
        var minutes = 0.0
        var total = 0.0

        func closeRide() {
            guard let line = currentLine, stops.count >= 2 else { currentLine = nil; stops = []; minutes = 0; return }
            legs.append(RouteLeg(kind: .ride(lineId: line, towards: graph.terminus(line: line, stops: stops)), stops: stops, minutes: minutes))
            currentLine = nil; stops = []; minutes = 0
        }

        for step in steps {
            switch step {
            case let .ride(line, from, to, rideMinutes, sameLineChange):
                if currentLine != line || sameLineChange {
                    closeRide()
                    if !legs.isEmpty { total += changeMinutes }
                    currentLine = line
                    stops = [from]
                }
                stops.append(to)
                minutes += rideMinutes
                total += rideMinutes
            case .alight:
                closeRide()
            case let .walk(from, to, metres, walkMinutes):
                closeRide()
                legs.append(RouteLeg(kind: .walk(metres: Int((metres * 1.3).rounded())), stops: [from, to], minutes: walkMinutes))
                total += walkMinutes
            }
        }
        closeRide()
        if let firstLine = legs.first?.lineId, firstLine != request.onLine || request.trainStuck {
            total += boardMinutes
        }
        return RoutePlan(legs: legs, minutes: max(Int(total.rounded()), 1))
    }
}

/// Small binary heap; the graph is a few thousand states, so this is plenty.
private struct MinQueue<Element> {
    private var heap: [(Element, Double)] = []

    mutating func push(_ element: Element, priority: Double) {
        heap.append((element, priority))
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].1 < heap[parent].1 else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Element, Double)? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let top = heap.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            if left < heap.count, heap[left].1 < heap[smallest].1 { smallest = left }
            if right < heap.count, heap[right].1 < heap[smallest].1 { smallest = right }
            if smallest == parent { break }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}
