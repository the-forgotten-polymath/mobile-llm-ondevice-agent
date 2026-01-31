// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

private struct LegacySavedWorkflowScriptV2: Decodable {
    let script: WorkflowScriptV1
}

/// Dedicated durable store for dynamic workflows. Construction and read probes are side-effect
/// free; the database is created only by `openForWrite` or the first mutation.
public actor SQLiteDynamicWorkflowJournal: DynamicWorkflowJournal {
    public static let schemaVersion: Int64 = 3
    private static let applicationID: Int64 = 0x4D4C5746 // MLWF

    private let databaseURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var connection: SQLiteConnection?
    private var connectionIsWritable = false

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public nonisolated var location: URL { databaseURL }
    public nonisolated func databaseExists() -> Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    public func openForWrite() throws { _ = try writableConnection() }

    public func close() {
        connection?.close()
        connection = nil
        connectionIsWritable = false
    }

    public func saveScript(_ script: SavedWorkflowScriptV1) async throws {
        let db = try writableConnection()
        let payload = try encoder.encode(script)
        try db.execute("BEGIN IMMEDIATE")
        do {
            let existingSource = try db.rows(
                "SELECT payload FROM workflow_scripts WHERE source_digest = ? OR (script_id = ? AND version = ?)",
                [.text(script.script.sourceDigest.rawValue), .text(script.script.scriptID.description),
                 .integer(try sqliteInteger(script.script.version))]
            )
            if let row = existingSource.first {
                guard row.count == 1, let existingPayload = row[0].blob, existingSource.count == 1 else {
                    throw WorkflowJournalError.scriptConflict
                }
                let existingScript: WorkflowScriptV1
                do {
                    existingScript = try decoder.decode(
                        SavedWorkflowScriptV1.self,
                        from: existingPayload
                    ).script
                } catch {
                    // V2 payloads intentionally remain inaccessible: they had no owner. They may
                    // still serve as the content source row when the immutable source is identical.
                    existingScript = try decoder.decode(
                        LegacySavedWorkflowScriptV2.self,
                        from: existingPayload
                    ).script
                }
                guard existingScript.sourceDigest == script.script.sourceDigest,
                      existingScript.source == script.script.source,
                      existingScript.abiVersion == script.script.abiVersion
                else { throw WorkflowJournalError.scriptConflict }
            } else {
                try db.execute(
                    """
                    INSERT INTO workflow_scripts(
                        source_digest, script_id, version, metadata_name, created_at, payload
                    ) VALUES(?, ?, ?, ?, ?, ?)
                    """,
                    [.text(script.script.sourceDigest.rawValue), .text(script.script.scriptID.description),
                     .integer(try sqliteInteger(script.script.version)), .text(script.metadata.name),
                     .integer(script.createdAt.rawValue), .blob(payload)]
                )
            }
            let catalog = try db.rows(
                "SELECT payload FROM workflow_script_catalog WHERE owner_key = ? AND (source_digest = ? OR (script_id = ? AND version = ?))",
                [.text(script.owner.storageKey), .text(script.script.sourceDigest.rawValue),
                 .text(script.script.scriptID.description), .integer(try sqliteInteger(script.script.version))]
            )
            if let row = catalog.first {
                guard row.count == 1, row[0].blob == payload, catalog.count == 1 else {
                    throw WorkflowJournalError.scriptConflict
                }
            } else {
                try db.execute(
                    "INSERT INTO workflow_script_catalog(owner_key, scope, source_digest, script_id, version, metadata_name, created_at, payload) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                    [.text(script.owner.storageKey), .text(script.scope.rawValue),
                     .text(script.script.sourceDigest.rawValue), .text(script.script.scriptID.description),
                     .integer(try sqliteInteger(script.script.version)), .text(script.metadata.name),
                     .integer(script.createdAt.rawValue), .blob(payload)]
                )
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw map(error)
        }
    }

    public func loadScript(
        _ reference: WorkflowScriptReferenceV1,
        owners: [WorkflowScriptOwnerV1]
    ) async throws -> SavedWorkflowScriptV1? {
        guard let db = try existingConnection() else { return nil }
        for owner in owners {
            guard let payload = try db.rows(
                "SELECT payload FROM workflow_script_catalog WHERE owner_key = ? AND source_digest = ?",
                [.text(owner.storageKey), .text(reference.sourceDigest.rawValue)]
            ).first?.first?.blob else { continue }
            let saved: SavedWorkflowScriptV1 = try decode(payload)
            guard saved.owner == owner, saved.script.reference == reference else {
                throw WorkflowJournalError.corrupt("workflow script reference or owner mismatch")
            }
            return saved
        }
        return nil
    }

    public func resolveScript(
        named name: String,
        owners: [WorkflowScriptOwnerV1]
    ) async throws -> SavedWorkflowScriptV1? {
        guard let db = try existingConnection() else { return nil }
        for owner in owners {
            guard let payload = try db.rows(
                "SELECT payload FROM workflow_script_catalog WHERE owner_key = ? AND metadata_name = ? ORDER BY version DESC, created_at DESC LIMIT 1",
                [.text(owner.storageKey), .text(name)]
            ).first?.first?.blob else { continue }
            let saved: SavedWorkflowScriptV1 = try decode(payload)
            guard saved.owner == owner else {
                throw WorkflowJournalError.corrupt("workflow script catalog owner mismatch")
            }
            return saved
        }
        return nil
    }

    public func listScripts(owners: [WorkflowScriptOwnerV1]) async throws -> [SavedWorkflowScriptV1] {
        guard let db = try existingConnection() else { return [] }
        var result: [SavedWorkflowScriptV1] = []
        for owner in owners {
            let saved: [SavedWorkflowScriptV1] = try db.rows(
                "SELECT payload FROM workflow_script_catalog WHERE owner_key = ? ORDER BY metadata_name, version DESC",
                [.text(owner.storageKey)]
            ).map { row in
                guard let payload = row.first?.blob else {
                    throw WorkflowJournalError.corrupt("invalid workflow script row")
                }
                let saved: SavedWorkflowScriptV1 = try decode(payload)
                guard saved.owner == owner else {
                    throw WorkflowJournalError.corrupt("workflow script catalog owner mismatch")
                }
                return saved
            }
            result.append(contentsOf: saved)
        }
        return result
    }

    public func saveLaunchApproval(_ approval: WorkflowLaunchApprovalV1) async throws {
        let db = try writableConnection()
        let payload = try encoder.encode(approval)
        try db.execute("BEGIN IMMEDIATE")
        do {
            if let existing = try db.rows(
                "SELECT payload FROM workflow_launch_approvals WHERE approval_id = ?",
                [.text(approval.approvalID.description)]
            ).first?.first?.blob {
                guard existing == payload else { throw WorkflowJournalError.scriptConflict }
                try db.execute("COMMIT")
                return
            }
            try db.execute(
                "INSERT INTO workflow_launch_approvals(approval_id, source_digest, reuse_scope, conversation_id, created_at, payload) VALUES(?, ?, ?, ?, ?, ?)",
                [.text(approval.approvalID.description),
                 .text(approval.scriptReference.sourceDigest.rawValue),
                 .text(approval.reuseScope.rawValue),
                 approval.conversationID.map { .text($0.description) } ?? .null,
                 .integer(approval.createdAt.rawValue), .blob(payload)]
            )
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw map(error)
        }
    }

    public func reusableLaunchApproval(
        for launch: WorkflowLaunchSnapshotV1
    ) async throws -> WorkflowLaunchApprovalV1? {
        guard let db = try existingConnection() else { return nil }
        let rows = try db.rows(
            "SELECT payload FROM workflow_launch_approvals WHERE source_digest = ? AND (reuse_scope = 'personal' OR conversation_id = ?) ORDER BY created_at DESC",
            [.text(launch.scriptReference.sourceDigest.rawValue), .text(launch.conversationID.description)]
        )
        for row in rows {
            guard let payload = row.first?.blob else {
                throw WorkflowJournalError.corrupt("invalid launch approval row")
            }
            let approval: WorkflowLaunchApprovalV1 = try decode(payload)
            if try approval.authorizes(launch) { return approval }
        }
        return nil
    }

    public func loadProjection(for runID: WorkflowRunID) async throws -> WorkflowRunProjectionV1? {
        guard let db = try existingConnection() else { return nil }
        return try projection(for: runID, db: db)
    }

    public func append(_ request: WorkflowEventAppendRequestV1) async throws -> WorkflowJournalAppendReceipt {
        let db = try writableConnection()
        try db.execute("BEGIN IMMEDIATE")
        do {
            let requestedPayloads = try request.events.map { try encoder.encode($0) }
            var exactReplay = true
            var existingIdentity = false
            for (event, payload) in zip(request.events, requestedPayloads) {
                let rows = try db.rows(
                    "SELECT payload FROM workflow_events WHERE event_id = ?",
                    [.text(event.eventID.description)]
                )
                if let existing = rows.first?.first?.blob {
                    existingIdentity = true
                    if existing != payload { throw WorkflowJournalError.eventIdentityConflict }
                } else {
                    exactReplay = false
                }
            }
            if exactReplay, existingIdentity,
               let projection = try projection(for: request.runID, db: db)
            {
                try db.execute("COMMIT")
                return WorkflowJournalAppendReceipt(
                    disposition: .replayed,
                    projection: projection,
                    eventIDs: request.events.map(\.eventID)
                )
            }
            if existingIdentity { throw WorkflowJournalError.eventIdentityConflict }

            let head = try db.rows(
                "SELECT next_sequence, last_digest FROM workflow_runs WHERE run_id = ?",
                [.text(request.runID.description)]
            ).first
            let actualSequence: UInt64
            let actualDigest: StableDigest?
            if let head {
                guard head.count == 2, let next = head[0].integer, next > 0,
                      let digest = head[1].text,
                      let parsedDigest = try? StableDigest(rawValue: digest)
                else { throw WorkflowJournalError.corrupt("invalid workflow run head") }
                actualSequence = UInt64(next - 1)
                actualDigest = parsedDigest
            } else {
                actualSequence = 0
                actualDigest = nil
            }
            guard actualSequence == request.expectedSequence,
                  actualDigest == request.expectedDigest
            else {
                throw WorkflowJournalError.stale(
                    expectedSequence: request.expectedSequence,
                    actualSequence: actualSequence
                )
            }

            let prior = try events(for: request.runID, db: db)
            let combined = prior + request.events
            guard let projected = try WorkflowRunProjectionV1.replay(combined) else {
                throw WorkflowJournalError.corrupt("append produced an empty projection")
            }
            if head == nil {
                guard case .created(let launch) = request.events[0].kind,
                      try catalogContains(
                          launch.scriptReference,
                          owners: launch.savedWorkflowOwners,
                          db: db
                      )
                else { throw WorkflowJournalError.scriptNotFound }
                try db.execute(
                    "INSERT INTO workflow_runs(run_id, script_digest, state, next_sequence, last_digest, created_at, updated_at) VALUES(?, ?, ?, 1, '', ?, ?)",
                    [.text(request.runID.description), .text(launch.scriptReference.sourceDigest.rawValue),
                     .text(WorkflowRunStateV1.waitingForLaunchApproval.rawValue),
                     .integer(request.events[0].timestamp.rawValue), .integer(request.events[0].timestamp.rawValue)]
                )
            }
            for (event, payload) in zip(request.events, requestedPayloads) {
                try db.execute(
                    "INSERT INTO workflow_events(event_id, run_id, sequence, timestamp, previous_digest, record_digest, payload) VALUES(?, ?, ?, ?, ?, ?, ?)",
                    [.text(event.eventID.description), .text(event.runID.description),
                     .integer(try sqliteInteger(event.sequence)), .integer(event.timestamp.rawValue),
                     event.previousDigest.map { .text($0.rawValue) } ?? .null,
                     .text(event.recordDigest.rawValue), .blob(payload)]
                )
            }
            try db.execute(
                "UPDATE workflow_runs SET state = ?, next_sequence = ?, last_digest = ?, updated_at = ? WHERE run_id = ?",
                [.text(projected.state.rawValue), .integer(try sqliteInteger(projected.lastSequence + 1)),
                 .text(projected.lastDigest.rawValue), .integer(projected.lastTimestamp.rawValue),
                 .text(request.runID.description)]
            )
            try db.execute("COMMIT")
            return WorkflowJournalAppendReceipt(
                disposition: .appended,
                projection: projected,
                eventIDs: request.events.map(\.eventID)
            )
        } catch {
            try? db.execute("ROLLBACK")
            throw map(error)
        }
    }

    public func readEvents(
        runID: WorkflowRunID,
        after sequence: UInt64,
        limit: Int
    ) async throws -> WorkflowJournalEventPage {
        guard (1 ... 1_024).contains(limit) else {
            throw WorkflowJournalError.corrupt("invalid read limit")
        }
        guard let db = try existingConnection() else {
            return WorkflowJournalEventPage(events: [], reachedEnd: true)
        }
        let rows = try db.rows(
            "SELECT payload FROM workflow_events WHERE run_id = ? AND sequence > ? ORDER BY sequence LIMIT ?",
            [.text(runID.description), .integer(try sqliteInteger(sequence)), .integer(Int64(limit + 1))]
        )
        let page = try rows.prefix(limit).map { row -> WorkflowRunEventV1 in
            guard let payload = row.first?.blob else {
                throw WorkflowJournalError.corrupt("invalid workflow event row")
            }
            return try decode(payload)
        }
        return WorkflowJournalEventPage(events: page, reachedEnd: rows.count <= limit)
    }

    private func projection(for runID: WorkflowRunID, db: SQLiteConnection) throws -> WorkflowRunProjectionV1? {
        try WorkflowRunProjectionV1.replay(events(for: runID, db: db))
    }

    private func events(for runID: WorkflowRunID, db: SQLiteConnection) throws -> [WorkflowRunEventV1] {
        try db.rows(
            "SELECT payload FROM workflow_events WHERE run_id = ? ORDER BY sequence",
            [.text(runID.description)]
        ).map { row in
            guard let payload = row.first?.blob else {
                throw WorkflowJournalError.corrupt("invalid workflow event row")
            }
            return try decode(payload)
        }
    }

    private func existingConnection() throws -> SQLiteConnection? {
        if let connection { return connection }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let wal = FileManager.default.fileExists(atPath: databaseURL.path + "-wal")
        let shm = FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
        guard wal == shm else {
            throw WorkflowJournalError.unavailable("incomplete workflow WAL sidecars")
        }
        let db = try SQLiteConnection(url: databaseURL, create: false, readOnly: true, immutable: !wal)
        do {
            try configureReadOnly(db)
            try validateSchema(db)
            connection = db
            connectionIsWritable = false
            return db
        } catch {
            db.close()
            throw map(error)
        }
    }

    private func writableConnection() throws -> SQLiteConnection {
        if let connection, connectionIsWritable { return connection }
        connection?.close()
        connection = nil
        connectionIsWritable = false
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let db = try SQLiteConnection(url: databaseURL, create: true)
            try configure(db)
            try migrate(db)
            try secureStoreFiles()
            connection = db
            connectionIsWritable = true
            return db
        } catch {
            throw map(error)
        }
    }

    private func configure(_ db: SQLiteConnection) throws {
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = FULL")
        try db.execute("PRAGMA secure_delete = ON")
        try db.execute("PRAGMA trusted_schema = OFF")
        try db.execute("PRAGMA writable_schema = OFF")
        try db.execute("PRAGMA cell_size_check = ON")
        try db.execute("PRAGMA busy_timeout = 5000")
        guard try db.scalarText("PRAGMA quick_check") == "ok" else {
            throw WorkflowJournalError.corrupt("workflow database quick_check failed")
        }
    }

    private func configureReadOnly(_ db: SQLiteConnection) throws {
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA trusted_schema = OFF")
        try db.execute("PRAGMA writable_schema = OFF")
        try db.execute("PRAGMA cell_size_check = ON")
        try db.execute("PRAGMA busy_timeout = 5000")
        guard try db.scalarText("PRAGMA quick_check") == "ok" else {
            throw WorkflowJournalError.corrupt("workflow database quick_check failed")
        }
    }

    private func migrate(_ db: SQLiteConnection) throws {
        let applicationID = try db.scalarInt("PRAGMA application_id") ?? 0
        let version = try db.scalarInt("PRAGMA user_version") ?? 0
        guard applicationID == 0 || applicationID == Self.applicationID,
              version <= Self.schemaVersion
        else { throw WorkflowJournalError.corrupt("unsupported workflow database") }
        if version == Self.schemaVersion {
            try validateSchema(db)
            return
        }
        try db.execute("BEGIN EXCLUSIVE")
        do {
            try db.execute("CREATE TABLE IF NOT EXISTS workflow_scripts(source_digest TEXT PRIMARY KEY, script_id TEXT NOT NULL, version INTEGER NOT NULL CHECK(version > 0), metadata_name TEXT NOT NULL, created_at INTEGER NOT NULL, payload BLOB NOT NULL, UNIQUE(script_id, version)) STRICT")
            try db.execute("CREATE INDEX IF NOT EXISTS workflow_scripts_name ON workflow_scripts(metadata_name, version DESC)")
            // V2 workflow_scripts rows have no owner and are intentionally not copied. They remain
            // content source/FK rows only; all catalog reads go through this owner-bound V3 table.
            try db.execute("CREATE TABLE IF NOT EXISTS workflow_script_catalog(owner_key TEXT NOT NULL, scope TEXT NOT NULL CHECK(scope IN ('conversation','project','personal','bundled')), source_digest TEXT NOT NULL REFERENCES workflow_scripts(source_digest) ON DELETE CASCADE, script_id TEXT NOT NULL, version INTEGER NOT NULL CHECK(version > 0), metadata_name TEXT NOT NULL, created_at INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(owner_key, source_digest), UNIQUE(owner_key, script_id, version)) STRICT")
            try db.execute("CREATE INDEX IF NOT EXISTS workflow_script_catalog_lookup ON workflow_script_catalog(owner_key, metadata_name, version DESC, created_at DESC)")
            try db.execute("CREATE TABLE IF NOT EXISTS workflow_runs(run_id TEXT PRIMARY KEY, script_digest TEXT NOT NULL REFERENCES workflow_scripts(source_digest), state TEXT NOT NULL, next_sequence INTEGER NOT NULL CHECK(next_sequence > 0), last_digest TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL) STRICT")
            try db.execute("CREATE TABLE IF NOT EXISTS workflow_events(event_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, sequence INTEGER NOT NULL CHECK(sequence > 0), timestamp INTEGER NOT NULL, previous_digest TEXT, record_digest TEXT NOT NULL UNIQUE, payload BLOB NOT NULL, UNIQUE(run_id, sequence)) STRICT")
            try db.execute("CREATE TABLE IF NOT EXISTS workflow_launch_approvals(approval_id TEXT PRIMARY KEY, source_digest TEXT NOT NULL REFERENCES workflow_scripts(source_digest) ON DELETE CASCADE, reuse_scope TEXT NOT NULL CHECK(reuse_scope IN ('conversation','personal')), conversation_id TEXT, created_at INTEGER NOT NULL, payload BLOB NOT NULL, CHECK((reuse_scope = 'conversation' AND conversation_id IS NOT NULL) OR (reuse_scope = 'personal' AND conversation_id IS NULL))) STRICT")
            try db.execute("CREATE INDEX IF NOT EXISTS workflow_launch_approvals_lookup ON workflow_launch_approvals(source_digest, reuse_scope, conversation_id, created_at DESC)")
            try db.execute("PRAGMA application_id = \(Self.applicationID)")
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try validateSchema(db)
    }

    private func validateSchema(_ db: SQLiteConnection) throws {
        guard try db.scalarInt("PRAGMA application_id") == Self.applicationID,
              try db.scalarInt("PRAGMA user_version") == Self.schemaVersion,
              try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('workflow_scripts','workflow_script_catalog','workflow_runs','workflow_events','workflow_launch_approvals')") == 5
        else { throw WorkflowJournalError.corrupt("workflow schema mismatch") }
    }

    private func catalogContains(
        _ reference: WorkflowScriptReferenceV1,
        owners: [WorkflowScriptOwnerV1],
        db: SQLiteConnection
    ) throws -> Bool {
        for owner in owners {
            guard let payload = try db.rows(
                "SELECT payload FROM workflow_script_catalog WHERE owner_key = ? AND source_digest = ? AND script_id = ? AND version = ?",
                [.text(owner.storageKey), .text(reference.sourceDigest.rawValue),
                 .text(reference.scriptID.description), .integer(try sqliteInteger(reference.version))]
            ).first?.first?.blob else { continue }
            let saved: SavedWorkflowScriptV1 = try decode(payload)
            guard saved.owner == owner, saved.script.reference == reference else {
                throw WorkflowJournalError.corrupt("workflow script catalog identity mismatch")
            }
            return true
        }
        return false
    }

    private func secureStoreFiles() throws {
        for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
            where FileManager.default.fileExists(atPath: path)
        {
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
            #endif
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = URL(fileURLWithPath: path)
            try url.setResourceValues(values)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw WorkflowJournalError.corrupt("invalid durable workflow payload") }
    }

    private func sqliteInteger(_ value: UInt64) throws -> Int64 {
        guard value <= UInt64(Int64.max) else {
            throw WorkflowJournalError.corrupt("workflow integer overflow")
        }
        return Int64(value)
    }

    private func map(_ error: Error) -> Error {
        if let error = error as? WorkflowJournalError { return error }
        if let error = error as? WorkflowProjectionError {
            return WorkflowJournalError.corrupt(String(describing: error))
        }
        if let error = error as? SQLiteStoreError {
            return WorkflowJournalError.unavailable(String(describing: error))
        }
        return error
    }
}
