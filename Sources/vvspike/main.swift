import Foundation
import VoiceVaultCore

// Spike: prove SpeechAnalyzer transcription works from SwiftPM.
let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: vvspike <audio.m4a>")
    exit(1)
}
let url = URL(fileURLWithPath: args[1])
let t = Transcriber()
do {
    let supported = await Transcriber.supportedLocales()
    print("supported locales: \(supported.map(\.identifier).sorted().joined(separator: ", "))")
    print("model installed: \(await t.isModelInstalled())")
    try await t.ensureModel { p in print("download: \(Int(p * 100))%") }
    let start = Date()
    let names = Array(args.dropFirst(2))
    let text = try await t.transcribe(url: url, contextualStrings: names)
    print("--- transcript (\(Int(Date().timeIntervalSince(start)))s) ---")
    print(text)
} catch {
    print("ERROR: \(error.localizedDescription)")
    exit(1)
}
