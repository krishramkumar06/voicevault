import Foundation
import Speech
import AVFoundation

/// On-device transcription via Apple's SpeechAnalyzer (macOS 26+).
/// The speech model is downloaded once by the system via AssetInventory;
/// after that everything runs locally.
public enum TranscriberError: LocalizedError {
    case localeNotSupported(String)
    case assetDownloadFailed(String)
    case audioUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .localeNotSupported(let l):
            return "On-device transcription doesn't support the language “\(l)” yet."
        case .assetDownloadFailed(let m):
            return "Couldn't download Apple's speech model: \(m)"
        case .audioUnreadable(let m):
            return "Couldn't read the audio file: \(m)"
        }
    }
}

public struct Transcriber: Sendable {
    public let locale: Locale

    public init(locale: Locale = Locale(identifier: "en_US")) {
        self.locale = locale
    }

    /// Locales the installed OS can transcribe on-device.
    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// True when the speech model for `locale` is already installed.
    public func isModelInstalled() async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Downloads the on-device speech model if needed. `progress` is 0...1.
    public func ensureModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw TranscriberError.localeNotSupported(locale.identifier)
        }
        if await isModelInstalled() { return }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return // nothing to install
        }
        let observation: Task<Void, Never>? = progress.map { report in
            let p = request.progress
            return Task {
                while !Task.isCancelled {
                    report(p.fractionCompleted)
                    if p.isFinished { break }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        defer { observation?.cancel() }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw TranscriberError.assetDownloadFailed(error.localizedDescription)
        }
        progress?(1.0)
    }

    /// Transcribes an audio file to plain text. Fully on-device.
    /// `contextualStrings` biases recognition toward names/terms the
    /// user has told us about (the People dictionary).
    public func transcribe(url: URL, contextualStrings: [String] = []) async throws -> String {
        try await ensureModel()

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriberError.audioUnreadable(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }
        async let collected: [AttributedString] = {
            var parts: [AttributedString] = []
            for try await result in transcriber.results where result.isFinal {
                parts.append(result.text)
            }
            return parts
        }()

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let parts = try await collected
        let text = parts.map { String($0.characters) }.joined()
        return Self.tidy(text)
    }

    /// Collapse odd whitespace the recognizer sometimes emits.
    static func tidy(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ([.,!?;:])", with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
