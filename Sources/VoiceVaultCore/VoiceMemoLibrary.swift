import Foundation
import SQLite3
import AVFoundation

/// Reads recordings from the real Apple Voice Memos library (real titles
/// included) or from any plain folder of .m4a files.
public enum VoiceMemoLibrary {
    /// Where Voice Memos keeps its recordings and database on macOS.
    public static var defaultRecordingsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
    }

    public enum LibraryError: LocalizedError {
        case folderUnreadable(String)
        case notAVoiceMemosLibrary

        public var errorDescription: String? {
            switch self {
            case .folderUnreadable(let path):
                return "VoiceVault doesn't have permission to read \(path)."
            case .notAVoiceMemosLibrary:
                return "That folder doesn't look like a Voice Memos library (no recordings database found)."
            }
        }
    }

    /// Loads memos from a folder. If it contains the Voice Memos database,
    /// real titles and dates come from there; otherwise it's treated as a
    /// plain folder of audio files.
    public static func load(from folder: URL) throws -> [Memo] {
        let db = folder.appendingPathComponent("CloudRecordings.db")
        if FileManager.default.fileExists(atPath: db.path) {
            return try loadFromDatabase(db, recordingsFolder: folder)
        }
        return try loadFromPlainFolder(folder)
    }

    // MARK: - Voice Memos database

    static func loadFromDatabase(_ dbURL: URL, recordingsFolder: URL) throws -> [Memo] {
        // Copy the database (and WAL sidecars) so a live Voice Memos session
        // can't interfere, and we can never write to the original.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicevault-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: dbURL.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(
                    at: src,
                    to: tempDir.appendingPathComponent(src.lastPathComponent))
            }
        }

        let tempDB = tempDir.appendingPathComponent(dbURL.lastPathComponent)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(tempDB.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            throw LibraryError.notAVoiceMemosLibrary
        }
        defer { sqlite3_close(db) }

        // Column names verified against the Tahoe schema, but introspected
        // defensively: Apple renames things between releases.
        let available = columnNames(db: db, table: "ZCLOUDRECORDING")
        guard available.contains("ZPATH") else { throw LibraryError.notAVoiceMemosLibrary }

        // The user-visible title moves between columns across macOS releases
        // (ZENCRYPTEDTITLE is plaintext despite the name, and on Tahoe it's
        // often the only one filled in). Select every candidate and coalesce
        // per row — per table is not enough, because a library mixes rows
        // written by different OS versions.
        let titleColumns = ["ZCUSTOMLABEL", "ZENCRYPTEDTITLE", "ZCUSTOMLABELFORSORTING"]
            .filter(available.contains)
        var columns = ["ZPATH"]
        columns.append(contentsOf: titleColumns)
        let dateColumn = available.contains("ZDATE") ? "ZDATE" : nil
        if let dateColumn { columns.append(dateColumn) }
        let durationColumn = available.contains("ZDURATION") ? "ZDURATION" : nil
        if let durationColumn { columns.append(durationColumn) }
        let idColumn = available.contains("ZUNIQUEID") ? "ZUNIQUEID" : nil
        if let idColumn { columns.append(idColumn) }

        let sql = "SELECT \(columns.joined(separator: ", ")) FROM ZCLOUDRECORDING"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LibraryError.notAVoiceMemosLibrary
        }
        defer { sqlite3_finalize(stmt) }

        var memos: [Memo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ index: Int32) -> String? {
                guard let c = sqlite3_column_text(stmt, index) else { return nil }
                let s = String(cString: c)
                return s.isEmpty ? nil : s
            }
            guard let path = text(0) else { continue }
            var column: Int32 = 1
            var title: String? = nil
            for _ in titleColumns {
                if title == nil { title = text(column) }
                column += 1
            }
            var created = Date()
            if dateColumn != nil {
                // Core Data timestamps count from 2001-01-01.
                created = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, column))
                column += 1
            }
            var duration: TimeInterval? = nil
            if durationColumn != nil {
                let d = sqlite3_column_double(stmt, column)
                if d > 0 { duration = d }
                column += 1
            }
            var uniqueID: String? = nil
            if idColumn != nil { uniqueID = text(column) }

            let filename = (path as NSString).lastPathComponent
            let url = recordingsFolder.appendingPathComponent(filename)
            let onDisk = FileManager.default.fileExists(atPath: url.path)
            memos.append(Memo(
                id: uniqueID ?? filename,
                title: title ?? (filename as NSString).deletingPathExtension,
                url: url,
                created: created,
                duration: duration,
                isAvailable: onDisk))
        }
        return memos.sorted { $0.created > $1.created }
    }

    private static func columnNames(db: OpaquePointer, table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        return names
    }

    // MARK: - Plain folder of audio files

    static func loadFromPlainFolder(_ folder: URL) throws -> [Memo] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw LibraryError.folderUnreadable(folder.path)
        }

        let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "mp4"]
        return contents
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> Memo? in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                var duration: TimeInterval? = nil
                if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
                    duration = Double(file.length) / file.fileFormat.sampleRate
                }
                return Memo(
                    id: url.path,
                    title: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    created: created,
                    duration: duration)
            }
            .sorted { $0.created > $1.created }
    }
}
