import Foundation
import Testing
@testable import VoiceVaultCore

@Suite("Note rendering")
struct NoteRendererTests {
    let memo = Memo(
        id: "test-1",
        title: "yc of amsterdam AWESOME",
        url: URL(fileURLWithPath: "/tmp/test.m4a"),
        created: Date(timeIntervalSince1970: 1_751_000_000), // 2025-06-27T04:53:20Z
        duration: 723)

    let summary = MemoSummary(
        distillation: "A riff on building a startup hub in Amsterdam.",
        keyPoints: ["Amsterdam has the talent", "Nobody is organizing it"],
        tags: ["startups", "Europe Ideas"],
        people: ["Suren"])

    @Test func fullNoteStructure() {
        let md = NoteRenderer.render(
            memo: memo, transcript: "The transcript body.",
            summary: summary,
            corrections: [NameCorrection(from: "Soren", to: "Suren", count: 2)])

        #expect(md.hasPrefix("---\ntitle: \"yc of amsterdam AWESOME\"\n"))
        #expect(md.contains("created: 2025-06-27T04:53:20Z"))
        #expect(md.contains("duration: \"12:03\""))
        #expect(md.contains("type: voice-memo"))
        #expect(md.contains("transcription: apple-speechanalyzer"))
        // Tags are normalized to lowercase-hyphenated.
        #expect(md.contains("x-suggested-tags: [startups, europe-ideas]"))
        #expect(md.contains("x-suggested-people: [Suren]"))
        #expect(md.contains("x-name-corrections: [\"Soren → Suren\"]"))
        #expect(md.contains("## Summary"))
        #expect(md.contains("- Amsterdam has the talent"))
        #expect(md.contains("People: [[Suren]]"))
        #expect(md.contains("## Transcript\n\nThe transcript body."))
    }

    @Test func summaryFailureStillProducesTranscriptNote() {
        let md = NoteRenderer.render(memo: memo, transcript: "Words.", summary: nil, corrections: [])
        #expect(md.contains("status: transcript-only"))
        #expect(md.contains("## Transcript"))
        #expect(!md.contains("## Summary"))
    }

    @Test func emptyTranscriptIsFlagged() {
        let md = NoteRenderer.render(memo: memo, transcript: "", summary: nil, corrections: [])
        #expect(md.contains("status: no-transcript"))
        #expect(md.contains("(No speech was transcribed"))
    }

    @Test func enrichmentTogglesAreRespected() {
        let md = NoteRenderer.render(
            memo: memo, transcript: "Words.", summary: summary, corrections: [],
            options: .init(includeTags: false, includePeople: false, includeKeyPoints: false))
        #expect(!md.contains("x-suggested-tags"))
        #expect(!md.contains("x-suggested-people"))
        #expect(!md.contains("People: [["))
        #expect(!md.contains("- Amsterdam"))
        #expect(md.contains("A riff on building"))
    }

    @Test func titlesWithQuotesAreEscaped() {
        let tricky = Memo(id: "q", title: "she said \"no\"", url: memo.url,
                          created: memo.created, duration: nil)
        let md = NoteRenderer.render(memo: tricky, transcript: "x", summary: nil, corrections: [])
        #expect(md.contains(#"title: "she said \"no\"""#))
    }

    @Test func filenamesAreVaultSafe() {
        #expect(NoteRenderer.filename(for: "idea: build [this] | now?") == "idea build this now.md")
        #expect(NoteRenderer.filename(for: "") == "Untitled voice memo.md")
    }

    @Test func filenameCollisionsGetDateThenCounter() {
        let created = Date(timeIntervalSince1970: 1_751_000_000)
        let first = NoteRenderer.filename(for: "walk", existing: [], created: created)
        #expect(first == "walk.md")
        let second = NoteRenderer.filename(for: "walk", existing: ["walk.md"], created: created)
        #expect(second == "walk (2025-06-27).md")
        let third = NoteRenderer.filename(
            for: "walk", existing: ["walk.md", "walk (2025-06-27).md"], created: created)
        #expect(third == "walk (2).md")
    }

    @Test func hhmmss() {
        #expect(NoteRenderer.hhmmss(723) == "12:03")
        #expect(NoteRenderer.hhmmss(59.6) == "1:00")
        #expect(NoteRenderer.hhmmss(3671) == "61:11")
    }
}
