import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

typealias Row = [String: Any]

/// Dunne wrapper rond SQLite. Alle gegevens staan in
/// ~/Library/Application Support/TimeTrack/timetrack.sqlite
final class Database {
    static let shared = Database()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TimeTrack", isDirectory: true)
    }

    private var db: OpaquePointer?
    private let lock = NSLock()

    private static let schema = """
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS activity (
        id INTEGER PRIMARY KEY,
        start REAL NOT NULL,
        end REAL NOT NULL,
        app TEXT NOT NULL,
        bundle TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS activity_end ON activity(end);
    CREATE TABLE IF NOT EXISTS rules (
        id INTEGER PRIMARY KEY,
        field TEXT NOT NULL,
        pattern TEXT NOT NULL,
        skip INTEGER NOT NULL DEFAULT 0,
        company_id TEXT,
        company_name TEXT NOT NULL DEFAULT '',
        work_type_id TEXT,
        work_type_name TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS entries (
        id INTEGER PRIMARY KEY,
        day TEXT NOT NULL,
        start REAL NOT NULL,
        minutes INTEGER NOT NULL,
        company_id TEXT,
        company_name TEXT NOT NULL DEFAULT '',
        work_type_id TEXT,
        work_type_name TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        invoiceable INTEGER NOT NULL DEFAULT 1,
        auto INTEGER NOT NULL DEFAULT 0,
        group_key TEXT,
        pushed_id TEXT,
        pushed_at REAL,
        error TEXT
    );
    CREATE INDEX IF NOT EXISTS entries_day ON entries(day);
    """

    private init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let path = Self.directory.appendingPathComponent("timetrack.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            fatalError("Kan database niet openen: \(path)")
        }
        sqlite3_busy_timeout(db, 5000)
        sqlite3_exec(db, Self.schema, nil, nil, nil)
        migrate()
    }

    /// Schema-uitbreidingen, bijgehouden via PRAGMA user_version.
    private func migrate() {
        let migrations = [
            // 1: website (enkel domein) per activiteit, Teamleader-bedrijven, genegeerde voorstellen
            """
            ALTER TABLE activity ADD COLUMN host TEXT NOT NULL DEFAULT '';
            ALTER TABLE rules ADD COLUMN invoiceable INTEGER NOT NULL DEFAULT 1;
            CREATE TABLE IF NOT EXISTS companies (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                domains TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS dismissed (
                id INTEGER PRIMARY KEY,
                start REAL NOT NULL,
                end REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS dismissed_end ON dismissed(end);
            """,
        ]
        let current = Int(query("PRAGMA user_version").first?.int("user_version") ?? 0)
        for (i, sql) in migrations.enumerated() where i >= current {
            sqlite3_exec(db, "BEGIN; \(sql) PRAGMA user_version = \(i + 1); COMMIT;", nil, nil, nil)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: Any?...) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare(sql, args) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("SQL-fout: %@", String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    func query(_ sql: String, _ args: Any?...) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row = Row()
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("SQL-fout: %@ in %@", String(cString: sqlite3_errmsg(db)), sql)
            return nil
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            guard let arg else { sqlite3_bind_null(stmt, idx); continue }
            switch arg {
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String { self[key] as? String ?? "" }

    func optionalString(_ key: String) -> String? {
        guard let s = self[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    func int(_ key: String) -> Int {
        if let v = self[key] as? Int64 { return Int(v) }
        if let v = self[key] as? Double { return Int(v) }
        return 0
    }

    func double(_ key: String) -> Double {
        if let v = self[key] as? Double { return v }
        if let v = self[key] as? Int64 { return Double(v) }
        return 0
    }
}
