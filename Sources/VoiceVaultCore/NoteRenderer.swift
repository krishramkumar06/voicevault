import Foundation

/// Turns a processed memo into an Obsidian markdown note.
public enum NoteRenderer {
    public struct Options: Sendable {
        public var includeTags: Bool
        public var includePeople: Bool
        public var includeKeyPoints: Bool
        /// Set when the audio was copied into the vault, so the note can
        /// reference (and Obsidian can play) it.
        public var audioFilename: String?

        public init(includeTags: Bool = true, includePeople: Bool = true,
                    includeKeyPoints: Bool = true, audioFilename: String? = nil) {
            self.includeTags = includeTags
            self.includePeople = includePeople
            self.includeKeyPoints = includeKeyPoints
            self.audioFilename = audioFilename
        }
    }

    public static func render(
        memo: Memo,
        transcript: String,
        summary: MemoSummary?,
        corrections: [NameCorrection],
        options: Options = Options()
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(yamlString(memo.title))")
        lines.append("created: \(iso8601.string(from: memo.created))")
        if let duration = memo.duration {
            lines.append("duration: \"\(hhmmss(duration))\"")
        }
        lines.append("type: voice-memo")
        lines.append("transcription: apple-speechanalyzer")
        if let audio = options.audioFilename {
            lines.append("source: \(yamlString("./" + audio))")
        }
        if let summary {
            if options.includeTags {
                lines.append("x-suggested-tags: \(yamlList(summary.tags.map(normalizeTag)))")
            }
            if options.includePeople {
                lines.append("x-suggested-people: \(yamlList(summary.people))")
            }
        }
        if !corrections.isEmpty {
            lines.append("x-name-corrections: \(yamlList(corrections.map(\.label), quoted: true))")
        }
        if transcript.isEmpty {
            lines.append("status: no-transcript")
        } else if summary == nil {
            lines.append("status: transcript-only")
        }
        lines.append("---")
        lines.append("")

        if transcript.isEmpty {
            lines.append("(No speech was transcribed from this recording.)")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        if let summary {
            lines.append("## Summary")
            lines.append("")
            let distillation = summary.distillation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !distillation.isEmpty {
                lines.append(distillation)
                lines.append("")
            }
            if options.includeKeyPoints, !summary.keyPoints.isEmpty {
                for point in summary.keyPoints {
                    lines.append("- \(point)")
                }
                lines.append("")
            }
            if options.includePeople, !summary.people.isEmpty {
                lines.append("People: " + summary.people.map { "[[\($0)]]" }.joined(separator: ", "))
                lines.append("")
            }
            lines.append("---")
            lines.append("")
        }

        lines.append("## Transcript")
        lines.append("")
        lines.append(transcript)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Filenames

    /// A vault-safe filename from a memo title. Obsidian forbids
    /// `# ^ [ ] |` in names; the filesystem forbids `/ :`.
    public static func filename(for title: String, existing: Set<String> = [], created: Date? = nil) -> String {
        var name = title
        for ch in ["/", ":", "\\", "#", "^", "[", "]", "|", "\"", "*", "?", "<", ">"] {
            name = name.replacingOccurrences(of: ch, with: " ")
        }
        name = name.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.prefix(120))
        if name.isEmpty { name = "Untitled voice memo" }

        var candidate = name + ".md"
        if existing.contains(candidate), let created {
            let day = dayFormatter.string(from: created)
            candidate = "\(name) (\(day)).md"
        }
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(name) (\(counter)).md"
            counter += 1
        }
        return candidate
    }

    // MARK: - Helpers

    static func hhmmss(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    static func normalizeTag(_ tag: String) -> String {
        tag.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9/-]", with: "", options: .regularExpression)
    }

    static func yamlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func yamlList(_ items: [String], quoted: Bool = false) -> String {
        guard !items.isEmpty else { return "[]" }
        let rendered = quoted ? items.map(yamlString) : items
        return "[" + rendered.joined(separator: ", ") + "]"
    }

    static var iso8601: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }
}
