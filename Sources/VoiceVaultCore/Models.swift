import Foundation

/// One recording, wherever it came from (Voice Memos library or a plain folder).
public struct Memo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let created: Date
    public let duration: TimeInterval?
    /// False when iCloud has evicted the audio and it isn't on disk.
    public let isAvailable: Bool

    public init(id: String, title: String, url: URL, created: Date, duration: TimeInterval?, isAvailable: Bool = true) {
        self.id = id
        self.title = title
        self.url = url
        self.created = created
        self.duration = duration
        self.isAvailable = isAvailable
    }
}

/// What the local model returns for one transcript.
public struct MemoSummary: Codable, Hashable, Sendable {
    public var distillation: String
    public var keyPoints: [String]
    public var tags: [String]
    public var people: [String]

    enum CodingKeys: String, CodingKey {
        case distillation
        case keyPoints = "key_points"
        case tags, people
    }

    public init(distillation: String = "", keyPoints: [String] = [], tags: [String] = [], people: [String] = []) {
        self.distillation = distillation
        self.keyPoints = keyPoints
        self.tags = tags
        self.people = people
    }
}

/// A person the user has told us about, with known mishearings.
public struct PersonName: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Canonical spelling, e.g. "Suren" or "Isabel Matos".
    public var name: String
    /// Mishearings seen in the wild, e.g. "Soren". Always corrected on exact match.
    public var aliases: [String]

    public init(id: UUID = UUID(), name: String, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }
}

/// A name fix applied to a transcript, for the frontmatter audit trail.
public struct NameCorrection: Hashable, Sendable {
    public let from: String
    public let to: String
    public var count: Int

    public init(from: String, to: String, count: Int = 1) {
        self.from = from
        self.to = to
        self.count = count
    }

    public var label: String { "\(from) → \(to)" }
}

/// A fully processed memo waiting in the review queue.
public struct ProcessedNote: Identifiable, Hashable, Sendable {
    public let id: String              // memo id
    public let memo: Memo
    public let markdown: String
    public let filename: String
    public let corrections: [NameCorrection]
    public let transcriptIsEmpty: Bool
    public let summaryFailed: Bool
    public let summaryError: String?

    public init(memo: Memo, markdown: String, filename: String,
                corrections: [NameCorrection] = [],
                transcriptIsEmpty: Bool = false,
                summaryFailed: Bool = false,
                summaryError: String? = nil) {
        self.id = memo.id
        self.memo = memo
        self.markdown = markdown
        self.filename = filename
        self.corrections = corrections
        self.transcriptIsEmpty = transcriptIsEmpty
        self.summaryFailed = summaryFailed
        self.summaryError = summaryError
    }
}
