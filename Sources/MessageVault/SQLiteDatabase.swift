import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close(handle)
            throw MessageVaultError.database(message)
        }
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit { sqlite3_close(handle) }

    func beginSnapshot() throws { try execute("BEGIN DEFERRED TRANSACTION") }
    func endSnapshot() { try? execute("ROLLBACK") }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func query(_ sql: String, bindings: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { value.bind(to: statement, index: Int32(index + 1)) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(SQLiteRow(statement: statement!))
            case SQLITE_DONE: return
            default: throw error()
            }
        }
    }

    func columns(in table: String) throws -> Set<String> {
        var result = Set<String>()
        try query("PRAGMA table_info(\(table))") { result.insert($0.string(1) ?? "") }
        return result
    }

    private func error() -> MessageVaultError {
        MessageVaultError.database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error")
    }
}

enum SQLiteValue {
    case integer(Int64), text(String), null
    func bind(to statement: OpaquePointer?, index: Int32) {
        switch self {
        case .integer(let value): sqlite3_bind_int64(statement, index, value)
        case .text(let value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case .null: sqlite3_bind_null(statement, index)
        }
    }
}

struct SQLiteRow {
    let statement: OpaquePointer
    func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func bool(_ index: Int32) -> Bool { sqlite3_column_int(statement, index) != 0 }
    func string(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }
    func data(_ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
