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

        // The user-visible title moves between columns across macOS releases,
        // and on Tahoe the columns actively lie: ZCUSTOMLABEL holds an ISO
        // timestamp string, while the real title sits in ZENCRYPTEDTITLE
        // (plaintext despite the name) and ZCUSTOMLABELFORSORTING. Diagnosed
        // against a real 476-recording library. Coalesce per row, best
        // column first; unknown future columns are caught by the
        // LABEL/TITLE/NAME sweep, and timestamp-shaped values are rejected
        // by isPlausibleTitle.
        let knownTitleColumns = ["ZENCRYPTEDTITLE", "ZCUSTOMLABELFORSORTING", "ZCUSTOMLABEL"]
        let extraTitleColumns = available
            .filter { $0.contains("LABEL") || $0.contains("TITLE") || $0.contains("NAME") }
            .subtracting(knownTitleColumns)
            .sorted()
        let titleColumns = knownTitleColumns.filter(available.contains) + extraTitleColumns
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
                // Some columns have carried encrypted bytes in some OS
                // versions — accept only values that look like human text.
                if title == nil, let candidate = text(column), isPlausibleTitle(candidate) {
                    title = candidate
                }
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

    static func isPlausibleTitle(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 500, !s.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return false }
        // Tahoe stuffs ISO timestamps into ZCUSTOMLABEL; a timestamp is
        // metadata, not a title.
        if s.range(of: #"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?Z?$"#,
                   options: .regularExpression) != nil { return false }
        return true
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

    // MARK: - Diagnostics

    /// A plain-text report of what's actually inside a recordings folder —
    /// files, database tables, and where titles live. Written locally so a
    /// user can help debug title problems without exposing recordings.
    public static func diagnosticReport(for folder: URL) -> String {
        var out: [String] = ["VoiceVault diagnostic report", "folder: \(folder.path)", ""]

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
        out.append("── files (\(contents.count)):")
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            out.append("  \(url.lastPathComponent)  (\(size) bytes)")
        }
        out.append("")

        for dbURL in contents where dbURL.pathExtension == "db" {
            out.append("── database: \(dbURL.lastPathComponent)")
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("voicevault-diag-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: dbURL.path + suffix)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.copyItem(
                        at: src, to: tempDir.appendingPathComponent(src.lastPathComponent))
                }
            }
            var handle: OpaquePointer?
            let tempDB = tempDir.appendingPathComponent(dbURL.lastPathComponent)
            guard sqlite3_open_v2(tempDB.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let db = handle else {
                out.append("  (couldn't open)")
                continue
            }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            var tables: [String] = []
            if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { tables.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(stmt)

            for table in tables.sorted() {
                var count = 0
                if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \"\(table)\"", -1, &stmt, nil) == SQLITE_OK,
                   sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
                let columns = columnNames(db: db, table: table).sorted().joined(separator: ", ")
                out.append("  table \(table) (\(count) rows): \(columns)")

                // For recording tables, show which columns actually hold the
                // titles, with a few sample values.
                if table.contains("RECORDING"), count > 0 {
                    let titleish = columnNames(db: db, table: table)
                        .filter { $0.contains("LABEL") || $0.contains("TITLE") || $0.contains("NAME") || $0 == "ZPATH" }
                        .sorted()
                    for col in titleish {
                        var samples: [String] = []
                        var filled = 0
                        let sql = "SELECT \"\(col)\" FROM \"\(table)\" ORDER BY Z_PK DESC LIMIT 5"
                        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                            while sqlite3_step(stmt) == SQLITE_ROW {
                                if let c = sqlite3_column_text(stmt, 0) {
                                    let v = String(cString: c)
                                    if !v.isEmpty {
                                        filled += 1
                                        samples.append(String(v.prefix(48)))
                                    } else {
                                        samples.append("(empty)")
                                    }
                                } else {
                                    samples.append("(null)")
                                }
                            }
                        }
                        sqlite3_finalize(stmt)
                        out.append("    \(col): last-5 = [\(samples.joined(separator: " | "))]")
                    }
                }
            }
            out.append("")
        }
        return out.joined(separator: "\n")
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
