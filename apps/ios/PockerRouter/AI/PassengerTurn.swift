import Foundation

/// What one passenger message says, as names and flags, before anything is
/// matched to the map. Produced by the on-device model or by keyword rules.
/// It never carries route facts: only what the passenger reported or wants.
struct ParsedTurn: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        var line: String?
        var from: String
        var to: String
    }

    /// "I'm at …", "held at …", "now at …".
    var currentStation: String?
    /// "going to …", "need to get to …".
    var destination: String?
    /// The line the passenger is or was on.
    var line: String?
    var situation: Situation?
    /// "Train is moving again".
    var trainMoving = false
    /// Lines reported as closed or not running.
    var closedLines: [String] = []
    /// "No service between Camden Town and Euston".
    var closedSections: [Section] = []
    /// Stations reported as closed ("Bank is shut").
    var closedStations: [String] = []
    /// "That branch isn't running", "can't take that": the top route's first leg is out.
    var currentRouteBlocked = false
    var stepFree: Bool?
    /// true: happy to walk; false: no walking routes.
    var walking: Bool?
    var fewerChanges = false
    /// Asked for something the saved map can't know: live status, delays, platforms, exits.
    var asksForUnavailableInfo = false
    /// A bare station name with no cue ("Euston"), used to answer a question.
    var unassignedStation: String?

    var isEmpty: Bool { self == ParsedTurn() }

    /// Merge two readings of the same message: `self` (the model) wins on
    /// names; flags and lists from either side are kept.
    func merged(with other: ParsedTurn) -> ParsedTurn {
        var result = self
        result.currentStation = currentStation ?? other.currentStation
        result.destination = destination ?? other.destination
        result.line = line ?? other.line
        result.situation = situation ?? other.situation
        result.trainMoving = trainMoving || other.trainMoving
        result.closedLines = Array(Set(closedLines + other.closedLines)).sorted()
        result.closedSections = closedSections.isEmpty ? other.closedSections : closedSections
        result.closedStations = Array(Set(closedStations + other.closedStations)).sorted()
        result.currentRouteBlocked = currentRouteBlocked || other.currentRouteBlocked
        result.stepFree = stepFree ?? other.stepFree
        result.walking = walking ?? other.walking
        result.fewerChanges = fewerChanges || other.fewerChanges
        result.asksForUnavailableInfo = asksForUnavailableInfo || other.asksForUnavailableInfo
        result.unassignedStation = unassignedStation ?? other.unassignedStation
        return result
    }
}

/// Rules that read a message without a model. Precise rather than clever:
/// it is the fallback on phones without Apple Intelligence, and it reads the
/// quick-reply chips so taps never wait for a model.
struct KeywordParser: Sendable {
    let matcher: StationMatcher

    private static let closureWords = ["closed", "not running", "isnt running", "arent running", "no service", "no trains",
                                       "suspended", "shut", "part closure", "out of service", "not working"]

    /// Whether the message reports anything closed or to avoid at all.
    static func reportsClosure(_ text: String) -> Bool {
        let normal = " " + StationMatcher.normalise(text) + " "
        return (closureWords + ["avoid", "avoiding", "not via", "no", "blocked", "cant use", "not that"]).contains { normal.contains(" \($0) ") }
    }

    /// Whether the message asks for fewer changes in words the rules know.
    static func mentionsChanges(_ text: String) -> Bool {
        let normal = " " + StationMatcher.normalise(text) + " "
        return [" change", " changing", " direct ", " one train "].contains { normal.contains($0) }
    }

    func parse(_ text: String) -> ParsedTurn {
        let normal = StationMatcher.expandStreet(StationMatcher.normalise(text))
        let words = normal.split(separator: " ").map(String.init)
        var turn = ParsedTurn()
        func has(_ phrase: String) -> Bool { " \(normal) ".contains(" \(phrase) ") }
        func hasAny(_ phrases: [String]) -> Bool { phrases.contains(where: has) }

        let reportsClosure = hasAny(Self.closureWords)

        // Situation and train state.
        if hasAny(["held", "stuck", "stopped", "not moving", "isnt moving", "standing", "sat at", "sitting at"]) { turn.situation = .held }
        if normal.contains("terminat") || hasAny(["kicked off", "everyone off", "all change", "last stop"]) { turn.situation = .terminating }
        if hasAny(["missed my stop", "missed the stop", "went past", "missed it", "missed my station"]) { turn.situation = .missedStop }
        if hasAny(["moving again", "moving now", "train is moving", "started moving", "going again", "on the move"]) {
            turn.trainMoving = true
            if turn.situation == .held { turn.situation = nil }
        }

        // Preferences.
        if hasAny(["step free", "stepfree", "lift", "lifts", "wheelchair", "pushchair", "buggy", "pram", "no stairs", "without stairs", "no steps", "without steps", "cant do stairs", "no escalators"]) {
            turn.stepFree = true
        }
        if hasAny(["no walking", "no walk", "dont want to walk", "cant walk", "not walking", "rather not walk"]) {
            turn.walking = false
        } else if hasAny(["walk", "walking", "on foot", "id rather walk"]) {
            turn.walking = true
        }
        if hasAny(["fewer changes", "fewest changes", "less changes", "no changes", "without changing", "direct", "one train"]) {
            turn.fewerChanges = true
        }
        if hasAny(["when will", "how long will", "how long until", "delay", "delays", "is there a service", "status",
                   "which platform", "what platform", "platform number", "which exit", "what exit", "live", "next train",
                   "is it running", "are they running", "running normally", "good service"]) {
            turn.asksForUnavailableInfo = true
        }

        // Stations, with their role from the words just before them.
        let mentions = matcher.mentions(in: text)
        let lines = matcher.lineMentions(in: text, excluding: mentions)
        func name(_ mention: StationMatcher.Mention) -> String {
            words[mention.range].joined(separator: " ")
        }
        func before(_ mention: StationMatcher.Mention, _ count: Int = 3) -> [String] {
            Array(words[max(0, mention.range.lowerBound - count)..<mention.range.lowerBound])
        }
        func after(_ mention: StationMatcher.Mention, _ count: Int = 4) -> String {
            words[mention.range.upperBound..<min(words.count, mention.range.upperBound + count)].joined(separator: " ")
        }

        var consumed = Set<Int>()
        // "between A and B" with a closure word: a closed section.
        if reportsClosure, let between = words.firstIndex(of: "between") {
            let pair = mentions.filter { $0.range.lowerBound > between }.prefix(2)
            if pair.count == 2 {
                let lineName = lines.first.map { words[$0.range].joined(separator: " ") }
                turn.closedSections.append(.init(line: lineName, from: name(pair[pair.startIndex]), to: name(pair[pair.startIndex + 1])))
                pair.forEach { consumed.insert($0.range.lowerBound) }
            }
        }

        for mention in mentions where !consumed.contains(mention.range.lowerBound) {
            let cue = before(mention)
            let last = cue.last
            let nextWords = after(mention)
            let closedHere = Self.closureWords.contains { nextWords.hasPrefix($0) || nextWords.hasPrefix("is \($0)") || nextWords.hasPrefix("station is \($0)") }
                || last == "avoid" || cue.suffix(2) == ["not", "via"] || last == "avoiding"
            if closedHere {
                turn.closedStations.append(name(mention))
            } else if last == "towards" || last == "via" {
                continue // a direction or a stop on the way, not a goal
            } else if ["at", "from", "in", "reached", "near", "outside"].contains(last ?? "") {
                if turn.currentStation == nil { turn.currentStation = name(mention) }
            } else if (["to", "for", "reach", "need", "needs"].contains(last ?? "") && cue.suffix(2) != ["change", "to"])
                        || cue.contains("going") || cue.contains("heading") {
                if turn.destination == nil { turn.destination = name(mention) }
            } else if turn.unassignedStation == nil {
                turn.unassignedStation = name(mention)
            }
        }
        // "Camden to Warren Street": two bare names, first is here.
        if turn.currentStation == nil, turn.destination == nil || turn.unassignedStation != nil, mentions.count == 2, consumed.isEmpty,
           turn.closedStations.isEmpty, words[mentions[0].range.upperBound..<mentions[1].range.lowerBound].contains("to") {
            turn.currentStation = name(mentions[0])
            turn.destination = name(mentions[1])
            turn.unassignedStation = nil
        }

        // Lines: closed, or the one the passenger is on.
        for mention in lines {
            let lineName = words[mention.range].joined(separator: " ")
            let tail = words[mention.range.upperBound..<min(words.count, mention.range.upperBound + 5)].joined(separator: " ")
            let head = words[max(0, mention.range.lowerBound - 3)..<mention.range.lowerBound]
            let closedLine = Self.closureWords.contains { tail.contains($0) } || head.contains("avoid") || head.contains("no")
            if turn.closedSections.contains(where: { $0.line == lineName }) { continue }
            if closedLine && !turn.asksForUnavailableInfo {
                turn.closedLines.append(lineName)
            } else if head.last == "to" && head.contains("change") {
                continue
            } else if turn.line == nil && !turn.asksForUnavailableInfo {
                turn.line = lineName
            }
        }
        if reportsClosure && turn.situation == nil && turn.closedLines.isEmpty && turn.closedSections.isEmpty && turn.closedStations.isEmpty {
            if hasAny(["branch", "that way", "that route", "this route", "that line", "this line"]) {
                turn.currentRouteBlocked = true
            } else if has("line") || has("closed") || has("suspended") {
                turn.situation = .lineClosed
            }
        }
        if hasAny(["cant take that", "cant use that", "that doesnt work", "not that way", "that wont work", "something else", "another way"]) {
            turn.currentRouteBlocked = true
        }
        return turn
    }
}
