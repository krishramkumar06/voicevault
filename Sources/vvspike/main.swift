import Foundation
import VoiceVaultCore

// Developer harness: exercises the exact pipeline the app runs, from the CLI.
//   vvspike transcribe <audio> [names…]     transcription + name biasing
//   vvspike e2e <folder> <vault> [limit]    full pipeline into a vault folder
let args = CommandLine.arguments
guard args.count > 2 else {
    print("usage: vvspike transcribe <audio.m4a> [names…] | vvspike e2e <folder> <vault> [limit]")
    exit(1)
}

switch args[1] {
case "transcribe":
    let t = Transcriber()
    do {
        try await t.ensureModel { p in print("download: \(Int(p * 100))%") }
        let start = Date()
        let text = try await t.transcribe(
            url: URL(fileURLWithPath: args[2]),
            contextualStrings: Array(args.dropFirst(3)))
        print("--- transcript (\(Int(Date().timeIntervalSince(start)))s) ---")
        print(text)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }

case "e2e":
    guard args.count >= 4 else { print("usage: vvspike e2e <folder> <vault> [limit]"); exit(1) }
    var settings = AppSettings()
    settings.inputFolderPath = args[2]
    settings.vaultFolderPath = args[3]
    let limit = args.count > 4 ? Int(args[4]) ?? .max : .max
    settings.people = [
        PersonName(name: "Suren"),
        PersonName(name: "Isa", aliases: ["Issa"]),
        PersonName(name: "Sosnovsky"),
    ]

    do {
        let memos = try VoiceMemoLibrary.load(from: URL(fileURLWithPath: args[2]))
        print("found \(memos.count) memos")
        let engine = ProcessingEngine(settings: settings)
        for memo in memos.prefix(limit) {
            let start = Date()
            print("→ \(memo.title) [\(memo.durationLabel())]")
            let note = try await engine.process(memo)
            if note.transcriptIsEmpty { print("   ! empty transcript") }
            if note.summaryFailed { print("   ! summary failed: \(note.summaryError ?? "?")") }
            for c in note.corrections { print("   fixed: \(c.from) → \(c.to) ×\(c.count)") }
            let filename = try engine.write(note)
            print("   ✓ \(filename) (\(Int(Date().timeIntervalSince(start)))s)")
        }
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }

default:
    print("unknown command \(args[1])")
    exit(1)
}

extension Memo {
    func durationLabel() -> String {
        guard let duration else { return "?" }
        let s = Int(duration.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
