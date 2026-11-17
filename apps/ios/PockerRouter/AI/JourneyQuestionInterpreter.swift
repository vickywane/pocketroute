import FirebaseAILogic
import FirebaseCore
import Foundation

protocol JourneyQuestionInterpreting {
    func interpret(_ question: String, journey: Journey) async -> JourneyQuestionIntent
}

/// Safe baseline that works without a model or network connection.
struct OfflineKeywordInterpreter: JourneyQuestionInterpreting {
    func interpret(_ question: String, journey: Journey) async -> JourneyQuestionIntent {
        let text = question.lowercased()
        if text.contains("next") || text.contains("where") { return .nextStep }
        if text.contains("change") || text.contains("transfer") || text.contains("interchange") { return .interchange }
        if text.contains("destination") || text.contains("arrive") { return .destination }
        return .unsupported
    }
}

/// Firebase AI Logic classifies the request with Gemini.
/// Keep this behind the intent protocol so route facts remain local and trusted.
struct FirebaseHybridIntentInterpreter: JourneyQuestionInterpreting {
    func interpret(_ question: String, journey: Journey) async -> JourneyQuestionIntent {
        guard FirebaseAppCheckConfigured.isReady else {
            return await OfflineKeywordInterpreter().interpret(question, journey: journey)
        }

        do {
            let ai = FirebaseAI.firebaseAI(
                backend: .googleAI(),
                useLimitedUseAppCheckTokens: true
            )
            let model = ai.generativeModel(modelName: "gemini-3.8-flash")
            let prompt = """
            Classify the user's question about a saved transit journey. Return exactly one label: nextStep, interchange, destination, unsupported.
            Do not answer with route facts. The saved journey is the only source of route facts.
            Journey from: \(journey.origin)
            Journey to: \(journey.destination)
            Saved steps: \(journey.steps.map(\.instruction).joined(separator: " | "))
            Question: \(question)
            Label:
            """
            let response = try await model.generateContent(prompt)
            return Self.parse(response.text ?? "")
        } catch {
            return await OfflineKeywordInterpreter().interpret(question, journey: journey)
        }
    }

    private static func parse(_ text: String) -> JourneyQuestionIntent {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".`*_ ")) {
        case "nextstep": return .nextStep
        case "interchange": return .interchange
        case "destination": return .destination
        default: return .unsupported
        }
    }
}

private enum FirebaseAppCheckConfigured {
    static var isReady: Bool { FirebaseApp.app() != nil }
}
