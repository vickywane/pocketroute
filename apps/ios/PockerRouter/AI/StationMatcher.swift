import Foundation

/// Turns names people type or say ("kings x", "warren st", "the Northern")
/// into ids from the downloaded map. Deterministic and offline: the model may
/// pass names in, but only this type decides which station a name means.
struct StationMatcher: Sendable {
    enum Match: Equatable, Sendable {
        case station(String)
        /// Several stations fit ("Edgware Road"): ask, never guess.
        case ambiguous([String])
        /// Nothing fits; `suggestions` are the closest spellings.
        case unknown(suggestions: [String])
    }

    struct Mention: Equatable, Sendable {
        let stationIds: [String]
        /// Word range in the normalised text.
        let range: Range<Int>
    }

    let graph: NetworkGraph
    /// Normalised full name and base name (without "(Circle Line)") per station.
    private let keys: [(id: String, full: String, base: String)]
    private let lineKeys: [(id: String, key: String)]

    /// Spoken and typed short forms. Keys and values are normalised names.
    private static let aliases: [String: String] = [
        "kings x": "kings cross st pancras",
        "kx": "kings cross st pancras",
        "st pancras": "kings cross st pancras",
        "tcr": "tottenham court road",
        "high st kensington": "high street kensington",
        "ally pally": "alexandra palace",
        "olympia": "kensington olympia",
    ]

    /// First words too common to stand for a station on their own.
    private static let weakFirstWords: Set<String> = [
        "north", "south", "east", "west", "great", "high", "green", "royal", "white", "upper", "queens",
        "regents", "turnham", "golders", "elephant", "tower", "russell", "covent", "goldhawk", "manor", "london", "station",
    ]

    /// Line names people use. "Victoria" alone is a station; "Victoria line" is a line.
    private static let lineAliases: [String: String] = [
        "h and c": "hammersmith-city", "hammersmith and city": "hammersmith-city",
        "w and c": "waterloo-city", "waterloo and city": "waterloo-city", "drain": "waterloo-city",
        "met": "metropolitan", "picc": "piccadilly",
    ]

    init(graph: NetworkGraph) {
        self.graph = graph
        keys = graph.sortedStations.map { station in
            let full = Self.normalise(station.name)
            let base = Self.normalise(station.name.replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression))
            return (station.id, full, base)
        }
        lineKeys = graph.lineNames.map { ($0.key, Self.normalise($0.value)) }
    }

    // MARK: - Stations

    /// Resolve one name. `preferLine` breaks ties between same-named stations
    /// (two Paddingtons, two Hammersmiths) when only one is on that line.
    func match(_ raw: String, preferLine: String? = nil) -> Match {
        var name = Self.normalise(raw)
        for suffix in [" underground station", " tube station", " station", " underground", " tube"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        if name.hasPrefix("the ") { name.removeFirst(4) }
        name = Self.expandStreet(name)
        guard !name.isEmpty else { return .unknown(suggestions: []) }
        if let alias = Self.aliases[name] { name = alias }

        func pick(_ ids: [String]) -> Match? {
            guard !ids.isEmpty else { return nil }
            if ids.count == 1 { return .station(ids[0]) }
            if let preferLine {
                let onLine = ids.filter { graph.stations[$0]?.lineIds.contains(preferLine) == true }
                if onLine.count == 1 { return .station(onLine[0]) }
            }
            return .ambiguous(ids)
        }

        if let exact = pick(keys.filter { $0.full == name }.map(\.id)) { return exact }
        if let base = pick(keys.filter { $0.base == name }.map(\.id)) { return base }
        // Whole-word prefix: "warren" → Warren Street, "canary" → Canary Wharf.
        let words: [String] = name.split(separator: " ").map(String.init)
        let prefixed: [String] = keys.filter { key in
            let keyWords: [String] = key.full.split(separator: " ").map(String.init)
            return keyWords.starts(with: words)
        }.map(\.id)
        if let prefix = pick(prefixed) { return prefix }
        // Small typos: "picadilly circus", "marylebone" spelt "marlybone".
        let scored = keys.map { ($0.id, min(Self.distance(name, $0.full), Self.distance(name, $0.base))) }
            .sorted { $0.1 < $1.1 }
        let tolerance = name.count >= 9 ? 2 : (name.count >= 5 ? 1 : 0)
        if let best = scored.first, best.1 <= tolerance {
            let tied = scored.filter { $0.1 == best.1 }.map(\.0)
            if let typo = pick(tied) { return typo }
        }
        return .unknown(suggestions: scored.prefix(3).filter { $0.1 <= max(3, name.count / 2) }.map(\.0))
    }

    /// Station names written in free text, longest first, with where they appear.
    /// "Bank" in "Bank branch" is the branch, not the station, so it is skipped.
    func mentions(in text: String) -> [Mention] {
        let words = Self.expandStreet(Self.normalise(text)).split(separator: " ").map(String.init)
        var found: [Mention] = []
        var taken = Set<Int>()
        var candidates: [(ids: [String], words: [String])] = []
        var byName: [String: [String]] = [:]
        for key in keys {
            byName[key.full, default: []].append(key.id)
            if key.base != key.full { byName[key.base, default: []].append(key.id) }
        }
        for (name, ids) in byName { candidates.append((Array(Set(ids)).sorted(), name.split(separator: " ").map(String.init))) }
        for (alias, target) in Self.aliases {
            if let ids = byName[target] { candidates.append((ids, alias.split(separator: " ").map(String.init))) }
        }
        // "held at Camden" → Camden Town, when the first word is distinctive.
        let lineWords = Set(lineKeys.flatMap { $0.key.split(separator: " ").map(String.init) })
        let firstWords = Dictionary(grouping: keys.filter { $0.full.contains(" ") }, by: { String($0.full.split(separator: " ")[0]) })
        for (word, group) in firstWords where group.count == 1 && word.count >= 5 && byName[word] == nil
            && !lineWords.contains(word) && !Self.weakFirstWords.contains(word) {
            candidates.append(([group[0].id], [word]))
        }
        candidates.sort { $0.words.count > $1.words.count }

        for candidate in candidates where !candidate.words.isEmpty && candidate.words.count <= words.count {
            for start in 0...(words.count - candidate.words.count) {
                let range = start..<(start + candidate.words.count)
                guard Array(words[range]) == candidate.words, taken.isDisjoint(with: range) else { continue }
                let next = range.upperBound < words.count ? words[range.upperBound] : nil
                if next == "branch" || next == "line" { continue }
                // "Waterloo & City" is a line, not Waterloo station.
                if next == "and", range.upperBound + 1 < words.count, words[range.upperBound + 1] == "city" { continue }
                found.append(Mention(stationIds: candidate.ids, range: range))
                taken.formUnion(range)
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: - Lines

    func line(_ raw: String) -> String? {
        var name = Self.normalise(raw)
        if name.hasPrefix("the ") { name.removeFirst(4) }
        if name.hasSuffix(" line") { name.removeLast(5) }
        if let alias = Self.lineAliases[name] { return alias }
        return lineKeys.first { $0.key == name }?.id ?? lineKeys.first { Self.distance($0.key, name) <= 1 && name.count >= 5 }?.id
    }

    /// Lines named in free text. A bare "Victoria" counts only before "line".
    func lineMentions(in text: String, excluding stations: [Mention] = []) -> [(lineId: String, range: Range<Int>)] {
        let words = Self.normalise(text).split(separator: " ").map(String.init)
        var found: [(String, Range<Int>)] = []
        var names = lineKeys.map { ($0.id, $0.key.split(separator: " ").map(String.init)) }
        names += Self.lineAliases.map { ($0.value, $0.key.split(separator: " ").map(String.init)) }
        names.sort { $0.1.count > $1.1.count }
        var taken = Set(stations.flatMap { Array($0.range) })
        for (id, nameWords) in names where nameWords.count <= words.count {
            for start in 0...(words.count - nameWords.count) {
                let range = start..<(start + nameWords.count)
                guard Array(words[range]) == nameWords, taken.isDisjoint(with: range) else { continue }
                let next = range.upperBound < words.count ? words[range.upperBound] : nil
                // "Victoria", "Bank" and friends are stations unless followed by "line".
                let isAlsoStation = keys.contains { $0.base == nameWords.joined(separator: " ") }
                guard next == "line" || next == "lines" || !isAlsoStation else { continue }
                found.append((id, range))
                taken.formUnion(range)
            }
        }
        return found.sorted { $0.1.lowerBound < $1.1.lowerBound }
    }

    // MARK: - Text

    /// Lowercase, no accents or punctuation, "&" → "and", single spaces.
    static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// "warren st" → "warren street", but "st pauls" stays "st pauls" (Saint).
    static func expandStreet(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        let connectors: Set<String> = ["station", "to", "and", "on", "via", "from", "at", "for", "now", "but", "is"]
        for index in words.indices where words[index] == "st" && index > 0 {
            let next = index + 1 < words.count ? words[index + 1] : nil
            if next.map(connectors.contains) ?? true { words[index] = "street" }
        }
        words = words.map { $0 == "rd" ? "road" : $0 }
        return words.joined(separator: " ")
    }

    /// Levenshtein distance; names are short so the quadratic cost is fine.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
