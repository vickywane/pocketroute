import Foundation

struct Journey: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let origin: String
    let destination: String
    let steps: [JourneyStep]
    let sourceNote: String
}

struct JourneyStep: Codable, Identifiable, Equatable {
    let id: String
    let instruction: String
    let station: String?
    let line: String?
}

enum JourneyQuestionIntent: Equatable {
    case nextStep
    case interchange
    case destination
    case unsupported
}
