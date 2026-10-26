import Foundation

#if os(Windows)
private let videoLibraryIsWindows = true
#else
private let videoLibraryIsWindows = false
#endif

public enum VideoOnlineState: String, Sendable, Codable {
    case online, offline, identityPending = "identity_pending"
}

public struct VideoSearchHit: Sendable, Codable, Equatable {
    public let id: Int64
    public let fileName: String
    public let relativePath: String
    public let fullPath: String
    public let rootID: String?
    public let volumeLabel: String?
    public let starred: Bool
    public let onlineState: VideoOnlineState
}

public struct VideoSearchPage: Sendable, Codable, Equatable {
    public let hits: [VideoSearchHit]
    public let cursor: String?
}

public struct LibraryRootRecord: Sendable, Codable, Equatable {
    public let id: String
    public let selectedPath: String
    public let volumeGUID: String?
    public let volumeSerial: String?
    public let volumeLabel: String?
    public let lastMountPath: String
    public let onlineState: VideoOnlineState
}

extension IndexStore {
    static let videoLibrarySchema = """
        CREATE TABLE IF NOT EXISTS library_roots(
            id TEXT PRIMARY KEY,
            selected_path TEXT NOT NULL UNIQUE,
            volume_guid TEXT,
            volume_serial TEXT,
            volume_label TEXT,
            volume_relative_root TEXT,
            last_mount_path TEXT NOT NULL,
            online_state TEXT NOT NULL DEFAULT 'identity_pending',
            last_successful_scan REAL
        );
        CREATE TABLE IF NOT EXISTS scan_runs(
            id TEXT PRIMARY KEY,
            root_id TEXT NOT NULL REFERENCES library_roots(id) ON DELETE CASCADE,
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            finished_at REAL,
            error TEXT
        );
        CREATE INDEX IF NOT EXISTS scan_runs_root ON scan_runs(root_id, started_at DESC);
        CREATE TABLE IF NOT EXISTS video_names(
            file INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            root_id TEXT REFERENCES library_roots(id),
            relative_path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            ancestors TEXT NOT NULL,
            normalized_name TEXT NOT NULL,
            normalized_ancestors TEXT NOT NULL,
            normalized_path TEXT NOT NULL,
            compact_code TEXT NOT NULL,
            starred INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS video_names_root ON video_names(root_id);
        CREATE UNIQUE INDEX IF NOT EXISTS video_names_location ON video_names(root_id, relative_path)
            WHERE root_id IS NOT NULL;
        CREATE INDEX IF NOT EXISTS video_names_starred ON video_names(starred);
        CREATE TABLE IF NOT EXISTS video_grams(
            gram TEXT NOT NULL,
            file INTEGER NOT NULL REFERENCES video_names(file) ON DELETE CASCADE,
            field INTEGER NOT NULL,
            PRIMARY KEY(gram, file, field)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS video_grams_file ON video_grams(file);
        """

    /// NFKC + locale-independent case/width folding, with whitespace made stable for storage and comparison.
    public static func normalizedVideoText(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func compactVideoCode(_ text: String) -> String {
        normalizedVideoText(text).filter { $0 != "-" && $0 != "_" && !$0.isWhitespace }
    }

    static func videoGrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= 3 else { return [] }
        return Set((0...(characters.count - 3)).map { String(characters[$0...($0 + 2)]) })
    }

    @discardableResult
    func ensureLibraryRoot(path: String) throws -> String {
        let volume = FileSystem.volumeIdentity(of: path)
        var found: String?
        var foundBySelectedPath = false
        try db.query("SELECT id FROM library_roots WHERE selected_path = ?", [.text(path)]) {
            found = $0.text(0)
            foundBySelectedPath = true
        }
        if found == nil, let guid = volume.guid {
            try db.query("""
                SELECT id FROM library_roots WHERE volume_guid = ? AND volume_relative_root = ? LIMIT 1
                """, [.text(guid), .text(volume.relativeRoot)]) { found = $0.text(0) }
        }
        if let found {
            try db.run("""
                UPDATE library_roots SET selected_path = CASE WHEN ? THEN ? ELSE selected_path END,
                    volume_guid = coalesce(?, volume_guid),
                    volume_serial = coalesce(?, volume_serial),
                    volume_label = coalesce(?, volume_label), volume_relative_root = ?, last_mount_path = ?,
                    online_state = ? WHERE id = ?
                """, [.int(foundBySelectedPath ? 1 : 0), .text(path), .optional(volume.guid),
                      .optional(volume.serial), .optional(volume.label),
                      .text(volume.relativeRoot), .text(volume.mountPath),
                      .text(volume.guid == nil && videoLibraryIsWindows ? "identity_pending" : "online"), .text(found)])
            return found
        }
        let id = UUID().uuidString.lowercased()
        try db.run("""
            INSERT INTO library_roots(id, selected_path, volume_guid, volume_serial, volume_label,
                                      volume_relative_root, last_mount_path, online_state)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(id), .text(path), .optional(volume.guid), .optional(volume.serial), .optional(volume.label),
                  .text(volume.relativeRoot), .text(volume.mountPath),
                  .text(volume.guid == nil && videoLibraryIsWindows ? "identity_pending" : "online")])
        return id
    }

    func upsertVideoName(file: Int64, path: String, rootPath: String?) throws {
        let rootID = try rootPath.map { try ensureLibraryRoot(path: $0) }
        var effectiveRoot = rootPath
        var effectiveRootID = rootID
        if effectiveRoot == nil {
            var matches: [(String, String)] = []
            try db.query("SELECT selected_path, id FROM library_roots") {
                let root = $0.text(0) ?? ""
                if path == root || FolderSelection.isInside(path, root) {
                    matches.append((root, $0.text(1) ?? ""))
                }
            }
            if let match = matches.max(by: { $0.0.count < $1.0.count }) {
                effectiveRoot = match.0
                effectiveRootID = match.1
            }
        }
        let relative: String
        if let root = effectiveRoot, path == root { relative = (path as NSString).lastPathComponent }
        else if let root = effectiveRoot, FolderSelection.isInside(path, root) {
            relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
        }
        else { relative = path }
        let name = (path as NSString).lastPathComponent
        let parent = (relative as NSString).deletingLastPathComponent
        let ancestors = parent == "." ? "" : parent.split(whereSeparator: { $0 == "/" || $0 == "\\" }).joined(separator: " ")
        let normalizedName = Self.normalizedVideoText(name)
        let normalizedAncestors = Self.normalizedVideoText(ancestors)
        let normalizedPath = Self.normalizedVideoText(relative.replacingOccurrences(of: "\\", with: "/"))
        let compact = Self.compactVideoCode(name + " " + ancestors)
        let starred = name.hasPrefix("☆")
        try db.run("""
            INSERT INTO video_names(file, root_id, relative_path, file_name, ancestors, normalized_name,
                                    normalized_ancestors, normalized_path, compact_code, starred)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(file) DO UPDATE SET root_id=excluded.root_id, relative_path=excluded.relative_path,
                file_name=excluded.file_name, ancestors=excluded.ancestors, normalized_name=excluded.normalized_name,
                normalized_ancestors=excluded.normalized_ancestors, normalized_path=excluded.normalized_path,
                compact_code=excluded.compact_code, starred=excluded.starred
            """, [.int(file), effectiveRootID.map { .text($0) } ?? .null, .text(relative), .text(name), .text(ancestors),
                  .text(normalizedName), .text(normalizedAncestors), .text(normalizedPath), .text(compact),
                  .int(starred ? 1 : 0)])
        try db.run("DELETE FROM video_grams WHERE file = ?", [.int(file)])
        for (field, value) in [(0, normalizedName), (1, normalizedAncestors), (2, compact)] {
            for gram in Self.videoGrams(value) {
                try db.run("INSERT OR IGNORE INTO video_grams(gram, file, field) VALUES(?, ?, ?)",
                           [.text(gram), .int(file), .int(Int64(field))])
            }
        }
    }

    func removeVideoName(file: Int64) throws {
        try db.run("DELETE FROM video_grams WHERE file = ?", [.int(file)])
        try db.run("DELETE FROM video_names WHERE file = ?", [.int(file)])
    }

    public func markLibraryRoot(path: String, online: Bool) throws {
        var existing: String?
        try db.query("SELECT id FROM library_roots WHERE selected_path = ?", [.text(path)]) { existing = $0.text(0) }
        let id: String
        if let existing { id = existing }
        else { id = try ensureLibraryRoot(path: path) }
        try db.run("UPDATE library_roots SET online_state = ? WHERE id = ?",
                   [.text(online ? "online" : "offline"), .text(id)])
    }

    /// Finds a Windows root after its drive letter changed. Only an exact Volume GUID match is accepted.
    public func resolveLibraryRoot(path: String) throws -> String? {
        #if os(Windows)
        var wantedGUID: String?, relative = ""
        var known = false
        try db.query("SELECT volume_guid, volume_relative_root FROM library_roots WHERE selected_path = ?", [.text(path)]) {
            known = true
            wantedGUID = $0.text(0); relative = $0.text(1) ?? ""
        }
        if !known { return FileSystem.canList(path) ? path : nil }
        guard let wantedGUID else { return nil }
        if FileSystem.canList(path),
           FileSystem.volumeIdentity(of: path).guid?.caseInsensitiveCompare(wantedGUID) == .orderedSame {
            return path
        }
        for letter in 65...90 {
            let mount = "\(Character(UnicodeScalar(letter)!)):/"
            guard FileManager.default.fileExists(atPath: mount) else { continue }
            let identity = FileSystem.volumeIdentity(of: mount)
            guard identity.guid?.caseInsensitiveCompare(wantedGUID) == .orderedSame else { continue }
            let candidate = relative.isEmpty ? mount : mount + relative.replacingOccurrences(of: "\\", with: "/")
            guard FileManager.default.fileExists(atPath: candidate) else { return nil }
            _ = try ensureLibraryRoot(path: candidate)
            return candidate
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Whether a currently readable path is the configured volume, not merely a reused drive letter.
    public func canUseLibraryRoot(path: String) throws -> Bool {
        #if os(Windows)
        let identity = FileSystem.volumeIdentity(of: path)
        guard let guid = identity.guid else { return false }
        var matched = false
        try db.query("""
            SELECT 1 FROM library_roots
            WHERE lower(volume_guid) = lower(?) AND volume_relative_root = ? LIMIT 1
            """, [.text(guid), .text(identity.relativeRoot)]) { _ in matched = true }
        // A newly selected root has no record until its first scan and is safe to establish now.
        var hasRecord = false
        try db.query("SELECT 1 FROM library_roots WHERE selected_path = ? LIMIT 1", [.text(path)]) { _ in hasRecord = true }
        return matched || !hasRecord
        #else
        return true
        #endif
    }

    public func libraryRoots() throws -> [LibraryRootRecord] {
        var roots: [LibraryRootRecord] = []
        try db.query("""
            SELECT id, selected_path, volume_guid, volume_serial, volume_label, last_mount_path, online_state
            FROM library_roots ORDER BY selected_path
            """) { row in
                roots.append(LibraryRootRecord(id: row.text(0) ?? "", selectedPath: row.text(1) ?? "",
                    volumeGUID: row.text(2), volumeSerial: row.text(3), volumeLabel: row.text(4),
                    lastMountPath: row.text(5) ?? "",
                    onlineState: VideoOnlineState(rawValue: row.text(6) ?? "") ?? .identityPending))
        }
        return roots
    }

    /// Every spelling a still-configured root has used. Pruning must retain all of them even while its disk is
    /// offline; otherwise a drive-letter change followed by a restart can erase the last-known index.
    func retainedLibraryPaths(selectedPaths: [String]) throws -> [String] {
        var paths = selectedPaths
        guard !selectedPaths.isEmpty else { return paths }
        let marks = Array(repeating: "?", count: selectedPaths.count).joined(separator: ",")
        try db.query("""
            SELECT selected_path, last_mount_path, volume_relative_root FROM library_roots
            WHERE selected_path IN (\(marks))
            """, selectedPaths.map { .text($0) }) { row in
                let selected = row.text(0) ?? ""
                let mount = row.text(1) ?? ""
                let relative = row.text(2) ?? ""
                paths.append(selected)
                guard !mount.isEmpty else { return }
                let full = relative.isEmpty ? mount
                    : mount.trimmingCharacters(in: CharacterSet(charactersIn: "\\/")) + "/" + relative
                paths.append(full.replacingOccurrences(of: "\\", with: "/"))
            }
        return Array(Set(paths))
    }

    /// Explicit user-confirmed relink. Unlike automatic relocation, this may replace a missing/unknown GUID.
    public func relinkLibraryRoot(id: String, to path: String) throws {
        guard FileSystem.canList(path) else {
            throw Database.Failure(message: "the selected folder cannot be read")
        }
        let volume = FileSystem.volumeIdentity(of: path)
        try db.run("""
            UPDATE library_roots SET volume_guid = ?, volume_serial = ?, volume_label = ?,
                volume_relative_root = ?, last_mount_path = ?, online_state = 'online' WHERE id = ?
            """, [.optional(volume.guid), .optional(volume.serial), .optional(volume.label),
                  .text(volume.relativeRoot), .text(volume.mountPath), .text(id)])
    }

    func refreshVideoName(file: Int64, path: String, rootPath: String?) throws {
        try upsertVideoName(file: file, path: path, rootPath: rootPath)
    }

    func beginScan(root path: String) throws -> (rootID: String, runID: String) {
        let rootID = try ensureLibraryRoot(path: path)
        let runID = UUID().uuidString.lowercased()
        try db.run("INSERT INTO scan_runs(id, root_id, status, started_at) VALUES(?, ?, 'running', ?)",
                   [.text(runID), .text(rootID), .double(Date().timeIntervalSince1970)])
        return (rootID, runID)
    }

    func finishScan(_ scan: (rootID: String, runID: String), succeeded: Bool, error: String? = nil) throws {
        let now = Date().timeIntervalSince1970
        try db.run("UPDATE scan_runs SET status = ?, finished_at = ?, error = ? WHERE id = ?",
                   [.text(succeeded ? "succeeded" : "incomplete"), .double(now), .optional(error), .text(scan.runID)])
        if succeeded {
            try db.run("UPDATE library_roots SET online_state = 'online', last_successful_scan = ? WHERE id = ?",
                       [.double(now), .text(scan.rootID)])
        }
    }

    func markSeen(file: Int64, runID: String?) throws {
        guard let runID else { return }
        try db.run("UPDATE files SET last_seen_run_id = ? WHERE id = ?", [.text(runID), .int(file)])
    }

    public func searchVideos(query: String, rootIDs: Set<String>? = nil, starredOnly: Bool = false,
                             onlineState: VideoOnlineState? = nil, pageSize: Int = 50,
                             cursor: String? = nil) throws -> VideoSearchPage {
        let raw = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let star = starredOnly || raw.contains("☆")
        let terms = raw.filter { $0 != "☆" }.map(Self.normalizedVideoText).filter { !$0.isEmpty }
        var candidateIDs = Set<Int64>()
        if terms.isEmpty {
            try db.query("SELECT file FROM video_names") { candidateIDs.insert($0.int(0)) }
        } else {
            for term in terms {
                let variants = Set([term, Self.compactVideoCode(term)]).filter { !$0.isEmpty }
                for variant in variants {
                    let grams = Self.videoGrams(variant)
                    if grams.isEmpty {
                        try db.query("""
                            SELECT file FROM video_names WHERE instr(normalized_path, ?) > 0 OR instr(compact_code, ?) > 0
                            """, [.text(variant), .text(variant)]) { candidateIDs.insert($0.int(0)) }
                    } else {
                        let marks = Array(repeating: "?", count: grams.count).joined(separator: ",")
                        try db.query("""
                            SELECT file FROM video_grams WHERE gram IN (\(marks))
                            GROUP BY file HAVING COUNT(DISTINCT gram) = ?
                            """, grams.sorted().map(SQLValue.text) + [.int(Int64(grams.count))]) {
                                candidateIDs.insert($0.int(0))
                            }
                    }
                }
            }
        }
        struct Ranked {
            let hit: VideoSearchHit
            let matches: Int
            let nameMatches: Int
            let pathKey: String
        }
        var ranked: [Ranked] = []
        // SQLite's default bind limit is 999. Fetch candidates in groups instead of issuing one query per video;
        // common actor/directory names can legitimately match tens of thousands of rows.
        let ids = Array(candidateIDs)
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = Array(ids[start..<min(start + 500, ids.count)])
            let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
            try db.query("""
                SELECT v.file, v.file_name, v.relative_path, f.path, v.root_id, r.volume_label,
                       v.starred, coalesce(r.online_state, 'identity_pending'), v.normalized_name,
                       v.normalized_ancestors, v.normalized_path, v.compact_code
                FROM video_names v JOIN files f ON f.id = v.file
                LEFT JOIN library_roots r ON r.id = v.root_id WHERE v.file IN (\(marks))
                """, batch.map { .int($0) }) { row in
                    let isStarred = row.int(6) != 0
                    let state = VideoOnlineState(rawValue: row.text(7) ?? "") ?? .identityPending
                    let rootAllowed = rootIDs.map { allowed in
                        row.text(4).map { allowed.contains($0) } ?? false
                    } ?? true
                    guard (!star || isStarred), rootAllowed,
                          onlineState == nil || onlineState == state else { return }
                    let name = row.text(8) ?? "", ancestors = row.text(9) ?? ""
                    let path = row.text(10) ?? "", compact = row.text(11) ?? ""
                    var matches = 0, nameMatches = 0
                    for term in terms {
                        let compactTerm = Self.compactVideoCode(term)
                        let inName = name.contains(term)
                            || (!compactTerm.isEmpty && Self.compactVideoCode(name).contains(compactTerm))
                        let anywhere = inName || ancestors.contains(term) || path.contains(term)
                            || (!compactTerm.isEmpty && compact.contains(compactTerm))
                        if anywhere { matches += 1 }
                        if inName { nameMatches += 1 }
                    }
                    guard terms.isEmpty || matches > 0 else { return }
                    ranked.append(Ranked(hit: VideoSearchHit(id: row.int(0), fileName: row.text(1) ?? "",
                        relativePath: row.text(2) ?? "", fullPath: row.text(3) ?? "", rootID: row.text(4),
                        volumeLabel: row.text(5), starred: isStarred, onlineState: state),
                        matches: matches, nameMatches: nameMatches, pathKey: path))
                }
        }
        ranked.sort {
            if $0.matches != $1.matches { return $0.matches > $1.matches }
            if $0.nameMatches != $1.nameMatches { return $0.nameMatches > $1.nameMatches }
            if $0.pathKey != $1.pathKey { return $0.pathKey < $1.pathKey }
            return $0.hit.id < $1.hit.id
        }
        if let cursor, let data = Data(base64Encoded: cursor),
           let last = try? JSONDecoder().decode(VideoCursor.self, from: data) {
            ranked.removeAll { item in
                item.matches > last.matches ||
                    (item.matches == last.matches && item.nameMatches > last.nameMatches) ||
                    (item.matches == last.matches && item.nameMatches == last.nameMatches && item.pathKey < last.path) ||
                    (item.matches == last.matches && item.nameMatches == last.nameMatches && item.pathKey == last.path
                     && item.hit.id <= last.id)
            }
        }
        let limit = min(max(pageSize, 1), 200)
        let page = Array(ranked.prefix(limit))
        let next = ranked.count > limit ? page.last.flatMap {
            let cursor = VideoCursor(matches: $0.matches, nameMatches: $0.nameMatches, path: $0.pathKey, id: $0.hit.id)
            return try? JSONEncoder().encode(cursor).base64EncodedString()
        } : nil
        return VideoSearchPage(hits: page.map(\.hit), cursor: next)
    }
}

private struct VideoCursor: Codable {
    let matches: Int
    let nameMatches: Int
    let path: String
    let id: Int64
}
