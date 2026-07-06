import Foundation
import SQLite3
import Testing
@testable import VoiceVaultCore

@Suite("Voice Memos database reading")
struct VoiceMemoLibraryTests {
    /// Builds a miniature CloudRecordings.db with the real schema's columns.
    func makeFixtureLibrary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vv-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var db: OpaquePointer?
        let dbPath = dir.appendingPathComponent("CloudRecordings.db").path
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE ZCLOUDRECORDING (
            Z_PK INTEGER PRIMARY KEY,
            ZCUSTOMLABEL TEXT, ZDATE FLOAT, ZDURATION FLOAT,
            ZPATH TEXT, ZUNIQUEID TEXT
        );
        INSERT INTO ZCLOUDRECORDING VALUES
            (1, 'morning walk idea', 773000000.0, 95.5, 'Recordings/20250601 093000.m4a', 'UUID-AAA'),
            (2, 'call with Suren', 774000000.0, 305.2, 'Recordings/20250612 141500.m4a', 'UUID-BBB'),
            (3, NULL, 775000000.0, 12.0, 'Recordings/20250624 081000.m4a', 'UUID-CCC');
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

        // Only two of the three audio files exist on disk (iCloud eviction).
        for name in ["20250601 093000.m4a", "20250612 141500.m4a"] {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path, contents: Data([0]))
        }
        return dir
    }

    @Test func readsTitlesDatesAndAvailability() throws {
        let folder = try makeFixtureLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }

        let memos = try VoiceMemoLibrary.load(from: folder)
        #expect(memos.count == 3)
        // Sorted newest first.
        #expect(memos[0].id == "UUID-CCC")

        let suren = try #require(memos.first { $0.id == "UUID-BBB" })
        #expect(suren.title == "call with Suren")
        #expect(suren.duration == 305.2)
        #expect(suren.isAvailable)
        // Core Data epoch: 774000000 seconds after 2001-01-01.
        #expect(abs(suren.created.timeIntervalSinceReferenceDate - 774000000.0) < 1)

        // Untitled memo falls back to its filename; evicted file is flagged.
        let untitled = try #require(memos.first { $0.id == "UUID-CCC" })
        #expect(untitled.title == "20250624 081000")
        #expect(!untitled.isAvailable)
    }

    @Test func plainFolderModeUsesFilenames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vv-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("my idea.m4a").path, contents: Data([0]))
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("notes.txt").path, contents: Data([0]))

        let memos = try VoiceMemoLibrary.load(from: dir)
        #expect(memos.count == 1)
        #expect(memos[0].title == "my idea")
    }
}

@Suite("Ollama response parsing")
struct OllamaClientTests {
    @Test func parsesStructuredSummary() throws {
        let body = """
        {"message": {"role": "assistant", "content":
        "{\\"distillation\\": \\"About X.\\", \\"key_points\\": [\\"a\\"], \\"tags\\": [\\"t\\"], \\"people\\": [\\"Isa\\"]}"}}
        """
        let summary = try OllamaClient.parseChatResponse(Data(body.utf8))
        #expect(summary.distillation == "About X.")
        #expect(summary.people == ["Isa"])
    }

    @Test func malformedModelOutputThrows() {
        let body = #"{"message": {"role": "assistant", "content": "not json"}}"#
        #expect(throws: (any Error).self) {
            try OllamaClient.parseChatResponse(Data(body.utf8))
        }
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func roundTripsThroughJSON() throws {
        var settings = AppSettings()
        settings.model = "llama3.2:3b"
        settings.people = [PersonName(name: "Suren", aliases: ["Soren"])]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }
}
