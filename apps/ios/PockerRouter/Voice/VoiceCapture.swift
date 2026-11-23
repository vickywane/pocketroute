import AVFAudio
import Foundation
import Observation
import Speech

/// On-device speech to text. Nothing is sent off the phone: recognition
/// requires on-device support and refuses to start without it.
@MainActor
@Observable
final class VoiceCapture {
    private(set) var isRecording = false
    /// What the passenger said. Never contains status or error text.
    private(set) var transcript = ""
    private(set) var errorMessage: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var tapInstalled = false

    /// Start a fresh recording, asking for permissions if needed.
    func begin() async {
        stop()
        transcript = ""
        errorMessage = nil
        guard await Self.speechAuthorized() else {
            errorMessage = "Allow speech recognition in Settings to use voice input."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Allow microphone access in Settings to use voice input."
            return
        }
        start()
    }

    /// Stop listening and keep what was heard.
    func finish() { stop() }

    /// Stop listening and discard what was heard.
    func cancel() {
        stop()
        transcript = ""
        errorMessage = nil
    }

    private func start() {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Voice input is unavailable right now."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            errorMessage = "Offline speech recognition isn’t available on this iPhone."
            return
        }
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.requiresOnDeviceRecognition = true
            request = recognitionRequest

            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                recognitionRequest.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    if let text { self.transcript = text }
                    if failed && self.transcript.isEmpty { self.errorMessage = "I didn’t catch that. Try again." }
                    if failed || isFinal { self.stop() }
                }
            }
        } catch {
            errorMessage = "Couldn’t start voice input. Try again."
            stop()
        }
    }

    private func stop() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}
