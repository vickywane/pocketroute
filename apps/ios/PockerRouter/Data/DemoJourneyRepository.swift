import Foundation

struct DemoJourneyRepository {
    func load() -> Journey {
        Journey(
            id: "demo-central-line",
            title: "Illustrative demo journey",
            origin: "Oxford Circus",
            destination: "Liverpool Street",
            steps: [
                JourneyStep(id: "1", instruction: "Take the Central line eastbound", station: "Oxford Circus", line: "Central"),
                JourneyStep(id: "2", instruction: "Stay on the train to Liverpool Street", station: "Liverpool Street", line: "Central")
            ],
            sourceNote: "Illustrative fixture only; not validated for live travel."
        )
    }
}
