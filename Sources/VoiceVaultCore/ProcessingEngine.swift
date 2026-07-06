import Foundation

/// Runs the per-memo pipeline: transcribe → correct names → summarize →
/// render. Produces `ProcessedNote`s for the review queue; writing to the
/// vault is a separate, explicit step.
public struct ProcessingEngine: Sendable {
    public let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public enum Phase: Sendable {
        case transcribing
        /// `charactersGenerated` grows as the model streams — surface it,
        /// because a silent multi-minute generation looks like a hang.
        case summarizing(charactersGenerated: Int)
    }

    /// Processes one memo. Never throws for summary failures — a memo with a
    /// transcript but no summary is still worth keeping (the PoC's lesson);
    /// the note is flagged instead.
    public func process(
        _ memo: Memo,
        phase: (@Sendable (Phase) -> Void)? = nil
    ) async throws -> ProcessedNote {
        phase?(.transcribing)
        let transcriber = Transcriber(locale: Locale(identifier: settings.transcriptionLocale))
        let contextual = settings.people.flatMap { [$0.name] + $0.aliases }
        let rawTranscript = try await transcriber.transcribe(
            url: memo.url, contextualStrings: contextual)

        guard !rawTranscript.isEmpty else {
            let markdown = NoteRenderer.render(
                memo: memo, transcript: "", summary: nil, corrections: [], options: renderOptions())
            return ProcessedNote(
                memo: memo, markdown: markdown,
                filename: NoteRenderer.filename(for: memo.title, created: memo.created),
                transcriptIsEmpty: true)
        }

        let corrected = NameCorrector(people: settings.people).correct(rawTranscript)

        phase?(.summarizing(charactersGenerated: 0))
        var summary: MemoSummary? = nil
        var summaryError: String? = nil
        do {
            summary = try await OllamaClient(baseURL: settings.ollamaURL).summarize(
                transcript: corrected.text,
                systemPrompt: settings.systemPrompt,
                model: settings.model,
                peopleHint: settings.people.map(\.name),
                contextWindow: Self.contextWindow(for: corrected.text, ceiling: settings.contextWindow),
                progress: { chars in phase?(.summarizing(charactersGenerated: chars)) })
        } catch {
            summaryError = error.localizedDescription
        }

        let markdown = NoteRenderer.render(
            memo: memo,
            transcript: corrected.text,
            summary: summary,
            corrections: corrected.corrections,
            options: renderOptions())

        return ProcessedNote(
            memo: memo,
            markdown: markdown,
            filename: NoteRenderer.filename(for: memo.title, created: memo.created),
            corrections: corrected.corrections,
            summaryFailed: summary == nil,
            summaryError: summaryError)
    }

    /// Right-sizes the model's context to the transcript. A full 16k window
    /// makes every summary pay long-memo costs (slower load, slower prompt
    /// eval); a short memo fits comfortably in 4k. Never exceeds `ceiling`,
    /// never goes below 4096, and keeps ~2k headroom for the system prompt
    /// and the generated JSON. Truncation is the one unforgivable failure —
    /// estimates are deliberately pessimistic (3 chars/token).
    static func contextWindow(for transcript: String, ceiling: Int) -> Int {
        let estimatedTokens = transcript.count / 3 + 2048
        for candidate in [4096, 8192, 16384, 32768] where candidate >= estimatedTokens {
            return Swift.min(candidate, Swift.max(ceiling, 4096))
        }
        return Swift.max(ceiling, 4096)
    }

    private func renderOptions() -> NoteRenderer.Options {
        // audioFilename is injected at write time, once the final note
        // filename (and thus the copied audio's name) is known.
        NoteRenderer.Options(
            includeTags: settings.includeTags,
            includePeople: settings.includePeople,
            includeKeyPoints: settings.includeKeyPoints)
    }

    // MARK: - Writing

    public enum WriteError: LocalizedError {
        case noVaultConfigured
        case vaultUnreachable(String)

        public var errorDescription: String? {
            switch self {
            case .noVaultConfigured:
                return "No vault folder is set. Choose one in Settings."
            case .vaultUnreachable(let path):
                return "Couldn't write into \(path). Is the folder still there?"
            }
        }
    }

    /// Writes a reviewed note (and optionally its audio) into the vault.
    /// Returns the final filename used.
    public func write(_ note: ProcessedNote) throws -> String {
        guard let vault = settings.vaultFolder else { throw WriteError.noVaultConfigured }
        guard FileManager.default.fileExists(atPath: vault.path) else {
            throw WriteError.vaultUnreachable(vault.path)
        }

        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? [])
        let filename = NoteRenderer.filename(
            for: note.memo.title, existing: existing, created: note.memo.created)

        var markdown = note.markdown
        if settings.copyAudioIntoVault, note.memo.isAvailable {
            let audioName = (filename as NSString).deletingPathExtension
                + "." + (note.memo.url.pathExtension.isEmpty ? "m4a" : note.memo.url.pathExtension)
            let audioTarget = vault.appendingPathComponent(audioName)
            if !FileManager.default.fileExists(atPath: audioTarget.path) {
                try? FileManager.default.copyItem(at: note.memo.url, to: audioTarget)
            }
            // Re-render with the audio reference now that we know the name.
            markdown = markdown.replacingOccurrences(
                of: "\ntype: voice-memo\n",
                with: "\ntype: voice-memo\nsource: \"./\(audioName)\"\n")
        }

        let target = vault.appendingPathComponent(filename)
        try markdown.write(to: target, atomically: true, encoding: .utf8)
        return filename
    }
}
