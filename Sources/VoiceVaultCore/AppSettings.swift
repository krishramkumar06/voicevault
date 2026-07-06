import Foundation

/// Everything the user can configure, persisted as plain JSON in
/// Application Support so it's inspectable and portable.
public struct AppSettings: Codable, Sendable, Equatable {
    public enum InputMode: String, Codable, Sendable {
        case voiceMemos   // the real Voice Memos library
        case folder       // any folder of audio files
    }

    public var inputMode: InputMode = .voiceMemos
    /// The folder being read. For `.voiceMemos` this is the Recordings
    /// container (stored after the user grants access); for `.folder`,
    /// whatever they picked.
    public var inputFolderPath: String? = nil
    public var vaultFolderPath: String? = nil

    public var model: String = AppSettings.defaultModel
    public var systemPrompt: String = AppSettings.defaultSystemPrompt
    public var contextWindow: Int = 16384
    public var ollamaURLString: String = "http://localhost:11434"
    public var transcriptionLocale: String = "en_US"

    public var includeTags: Bool = true
    public var includePeople: Bool = true
    public var includeKeyPoints: Bool = true
    public var copyAudioIntoVault: Bool = false
    public var autoSaveAfterProcessing: Bool = false

    public var people: [PersonName] = []

    public var onboardingComplete: Bool = false

    /// Memo ID → note filename, for "already exported" badges.
    public var exported: [String: String] = [:]

    public init() {}

    public var ollamaURL: URL {
        URL(string: ollamaURLString) ?? URL(string: "http://localhost:11434")!
    }

    public var vaultFolder: URL? {
        vaultFolderPath.map { URL(fileURLWithPath: $0) }
    }

    public var inputFolder: URL? {
        inputFolderPath.map { URL(fileURLWithPath: $0) }
    }

    public static let defaultModel = "qwen3.5:latest"

    /// Models worth suggesting to someone who has none, smallest first.
    public static let recommendedModels: [(name: String, blurb: String)] = [
        ("llama3.2:3b", "Small and fast (~2 GB) — fine for short memos"),
        ("qwen3:8b", "Balanced (~5 GB)"),
        ("qwen3.5:latest", "Best summaries (~7 GB) — what VoiceVault was tuned on"),
    ]

    public static let defaultSystemPrompt = """
    You are archiving a personal voice-memo brain dump for later retrieval in an Obsidian vault.
    Return JSON only, no commentary.
    - distillation: 2 to 3 sentences of plain declarative prose, no em dashes, saying what this memo is actually about.
    - key_points: 3 to 6 short bullets capturing the substantive ideas, not filler or throat-clearing.
    - tags: 2 to 6 lowercase hyphenated topic tags. Reuse conventional tags; do not invent baroque ones.
    - people: names of specific people the speaker mentions by name. Empty list if none.
    """
}

/// Loads and saves settings. Not thread-safe by design — use from the main actor.
public final class SettingsStore {
    public static var settingsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceVault/settings.json")
    }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public static func save(_ settings: AppSettings) {
        let url = settingsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
