import Foundation
import SQLite3

struct TranscriptionRecord: Identifiable, Equatable, Sendable {
    let id: Int64
    let text: String
    let rawText: String?
    let timestamp: Date
}

enum HistoryRepositoryError: LocalizedError {
    case sqlite(message: String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): message
        }
    }
}

actor HistoryRepository {
    // F1 保留策略：固定常量而非设置项——审计建议先以保守默认值小步落地，待有用户反馈再考虑开放配置。
    static let retentionDays = 90
    static let retentionMaxRows = 2000
    // 累计删除行数达到该阈值时执行一次 VACUUM 回收空间。
    private static let vacuumThreshold = 200
    // P2-17: 攒够 N 次写入再跑一次保留清理，避免每次 save() 都做 self-anti-join——
    // 原实现每条写入都跑 DELETE ... NOT IN (SELECT ...)，行数增大后代价显著。
    // 选 32 而非 64：兼顾"超出保留窗口的最坏延迟"（<= 32 条 ≈ 用户几分钟到几十分钟
    // 的听写量）与"减少低价值 prune 次数"（100 条写入 3 次而非 100 次）。启动时另外
    // 从 init() 强制跑一次，保证冷启动就能收敛到窗口内。
    static let pruneEveryNWrites = 32

    private let connection: SQLiteConnection
    private let databaseURL: URL
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var database: OpaquePointer? { connection.pointer }
    private var prunedRowsSinceVacuum = 0
    // P2-17: 距上次 save 触发 prune 已累积多少次写入；达到 pruneEveryNWrites 才触发一次。
    private var writesSincePrune = 0
    // P1-8: 默认为 nil 以保留 HEAD 行为；生产可注入 { msg in Task { await logger.write(.info, msg) } }
    // 让 save() 内部隐式触发的 prune 也被记录（当前 AppEnvironment 仅记录启动期 prune）。
    // 由测试 testPruneEmitsInfoLogWhenRowsRemoved 驱动，断言 non-zero 删除时触发一次。
    private let pruneLogger: (@Sendable (String) -> Void)?
    // P2-17: 每次 prune() 被调用时触发一次（与是否有删除无关），仅供测试观察调用频次；
    // 用途上与 pruneLogger 正交——pruneLogger 描述"删了几条"，pruneObserver 描述"跑了几次"。
    private let pruneObserver: (@Sendable () -> Void)?

    init(
        databaseURL: URL = AppPaths.databaseURL,
        pruneLogger: (@Sendable (String) -> Void)? = nil,
        pruneObserver: (@Sendable () -> Void)? = nil
    ) throws {
        self.databaseURL = databaseURL
        self.pruneLogger = pruneLogger
        self.pruneObserver = pruneObserver
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let handle { sqlite3_close(handle) }
            throw HistoryRepositoryError.sqlite(message: message)
        }
        connection = SQLiteConnection(pointer: handle)
        try Self.configureAndMigrate(handle)
    }

    // P1-7: 关闭前兜底 checkpoint 一次——delete(id:) 依赖 secure_delete=ON 就地清零，
    // 但被清零的帧仍在 -wal 里，直到默认 4MB 阈值触发自动 checkpoint 才回写。选择
    // per-shutdown 而不是"WAL 超过 N MB 主动 checkpoint"：前者零状态、零计数器，
    // 后者需要在每次 delete/save 后额外查 PRAGMA wal_autocheckpoint 页大小，收益不
    // 明显。SQLITE_OPEN_FULLMUTEX 保证在 nonisolated deinit 中调用是线程安全的。
    deinit {
        guard let handle = connection.pointer else { return }
        sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
    }

    func save(text: String, rawText: String?) throws -> TranscriptionRecord {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            throw HistoryRepositoryError.sqlite(message: "Cannot save an empty transcription")
        }
        let sql = "INSERT INTO transcriptions (text, raw_text) VALUES (?, ?)"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, cleanText, -1, Self.transient)
        if let rawText {
            sqlite3_bind_text(statement, 2, rawText, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        try stepDone(statement)
        let saved = try record(id: sqlite3_last_insert_rowid(database))
        // P2-17: 攒够 pruneEveryNWrites 次写入才跑一次保留清理——避免每条 save() 都做
        // self-anti-join，同时保证长期运行的会话最终仍会收敛到保留窗口内。
        // 冷启动的一次由 init() 负责；此处失败不影响本次保存结果。
        writesSincePrune += 1
        if writesSincePrune >= Self.pruneEveryNWrites {
            writesSincePrune = 0
            _ = try? prune()
        }
        return saved
    }

    /// F1: 删除超出保留窗口（天数/行数上限）的最旧记录，返回删除行数；
    /// 累计删除较多时执行一次 VACUUM。在 actor 串行环境内运行，避免并发写冲突。
    @discardableResult
    func prune(now: Date = Date()) throws -> Int {
        // P2-17: 每次 prune() 都通知观察者，与是否有删除无关——测试用它计数调用频次。
        pruneObserver?()
        var deleted = 0
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400)
        let expired = try prepare("DELETE FROM transcriptions WHERE timestamp < ?")
        defer { sqlite3_finalize(expired) }
        sqlite3_bind_text(expired, 1, SQLiteDateParser.string(from: cutoff), -1, Self.transient)
        try stepDone(expired)
        deleted += Int(sqlite3_changes(database))

        // P2-17: 用 IN + LIMIT -1 OFFSET 替代 NOT IN + LIMIT——语义等价（都是"保留最新 N 条、
        // 删除其余最旧的"），但 IN + OFFSET 让 SQLite 沿 timestamp 索引走一次即可，
        // 避免原 NOT IN 子查询的 self-anti-join。ORDER BY timestamp DESC, id DESC 保持
        // 与旧查询一致（并列 timestamp 时 id 大者留下）。
        let overflow = try prepare("""
            DELETE FROM transcriptions WHERE id IN (
              SELECT id FROM transcriptions ORDER BY timestamp DESC, id DESC LIMIT -1 OFFSET ?
            )
            """)
        defer { sqlite3_finalize(overflow) }
        sqlite3_bind_int(overflow, 1, Int32(Self.retentionMaxRows))
        try stepDone(overflow)
        deleted += Int(sqlite3_changes(database))

        guard deleted > 0 else { return 0 }
        try scrubLearningEvidence()
        // P1-8: 仅在真实发生删除时发一次；VACUUM 报错不吞掉观察点。
        pruneLogger?("History prune removed \(deleted) records")
        prunedRowsSinceVacuum += deleted
        if prunedRowsSinceVacuum >= Self.vacuumThreshold {
            prunedRowsSinceVacuum = 0
            try execute("VACUUM")
        }
        return deleted
    }

    func recent(limit: Int = 50, offset: Int = 0) throws -> [TranscriptionRecord] {
        let statement = try prepare(
            "SELECT id, text, raw_text, timestamp FROM transcriptions ORDER BY timestamp DESC, id DESC LIMIT ? OFFSET ?"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 1_000))))
        sqlite3_bind_int(statement, 2, Int32(max(0, offset)))
        return try collectRecords(statement)
    }

    /// D7: 在 SQL 层做大小写不敏感的 LIKE 搜索（转义 %/_/\），命中整理稿或原始稿任一列。
    func search(query: String, limit: Int = 50, offset: Int = 0) throws -> [TranscriptionRecord] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return try recent(limit: limit, offset: offset) }
        let pattern = "%\(Self.escapeLikePattern(clean))%"
        let statement = try prepare("""
            SELECT id, text, raw_text, timestamp FROM transcriptions
            WHERE text LIKE ?1 ESCAPE '\\' OR raw_text LIKE ?1 ESCAPE '\\'
            ORDER BY timestamp DESC, id DESC LIMIT ?2 OFFSET ?3
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, pattern, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 1_000))))
        sqlite3_bind_int(statement, 3, Int32(max(0, offset)))
        return try collectRecords(statement)
    }

    static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    func delete(id: Int64) throws {
        let statement = try prepare("DELETE FROM transcriptions WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        try stepDone(statement)
        try scrubLearningEvidence()
    }

    func restore(_ record: TranscriptionRecord) throws {
        let statement = try prepare(
            "INSERT OR REPLACE INTO transcriptions (id, text, raw_text, timestamp) VALUES (?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, record.id)
        sqlite3_bind_text(statement, 2, record.text, -1, Self.transient)
        if let rawText = record.rawText {
            sqlite3_bind_text(statement, 3, rawText, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, SQLiteDateParser.string(from: record.timestamp), -1, Self.transient)
        try stepDone(statement)
    }

    func clear() throws {
        try execute("DELETE FROM transcriptions")
        try scrubLearningEvidence()
        // P1-7: DELETE 已按 secure_delete=ON 就地清零本次删除的页面，但 WAL 里的
        // 历史 INSERT 帧和早于本修复的 freelist 页仍是明文。checkpoint(TRUNCATE)
        // 把待写帧回写主库并把 -wal 截断为 0 字节；随后 VACUUM 重写整库覆盖历史
        // freelist。checkpoint 因 BUSY 失败时不阻断，VACUUM 自身也会重写文件。
        try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
    }

    func dictionary() throws -> [String] {
        let statement = try prepare("SELECT word FROM custom_dictionary ORDER BY id ASC")
        defer { sqlite3_finalize(statement) }
        var words: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let value = sqlite3_column_text(statement, 0) {
                    words.append(String(cString: value))
                }
            case SQLITE_DONE:
                return words
            default:
                throw currentError()
            }
        }
    }

    func replaceDictionary(_ words: [String]) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM custom_dictionary")
            let statement = try prepare("INSERT OR IGNORE INTO custom_dictionary (word) VALUES (?)")
            defer { sqlite3_finalize(statement) }
            for word in words {
                let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, clean, -1, Self.transient)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func record(id: Int64) throws -> TranscriptionRecord {
        let statement = try prepare(
            "SELECT id, text, raw_text, timestamp FROM transcriptions WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result != SQLITE_DONE { throw currentError() }
            throw HistoryRepositoryError.sqlite(message: "Inserted transcription could not be read")
        }
        return Self.decodeRecord(statement)
    }

    private func collectRecords(_ statement: OpaquePointer?) throws -> [TranscriptionRecord] {
        var records: [TranscriptionRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                records.append(Self.decodeRecord(statement))
            case SQLITE_DONE:
                return records
            default:
                throw currentError()
            }
        }
    }

    private static func decodeRecord(_ statement: OpaquePointer?) -> TranscriptionRecord {
        let id = sqlite3_column_int64(statement, 0)
        let text = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        let rawText = sqlite3_column_text(statement, 2).map { String(cString: $0) }
        let timestampText = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
        return TranscriptionRecord(
            id: id,
            text: text,
            rawText: rawText,
            timestamp: SQLiteDateParser.date(from: timestampText)
        )
    }

    private static func configureAndMigrate(_ database: OpaquePointer?) throws {
        try execute(database, "PRAGMA journal_mode=WAL")
        // F7: 写锁竞争时最多等待 3 秒，避免并发访问直接抛 SQLITE_BUSY。
        try execute(database, "PRAGMA busy_timeout=3000")
        // P1-7: 每次打开都开启 secure_delete，让后续 DELETE 就地用零覆写被释放的
        // 页面，避免明文听写记录残留在 freelist；历史 freelist 需 VACUUM 才能回收
        // （见 clear()/prune()）。选 ON 而非 FAST：FAST 会跳过增大 I/O 的覆写，
        // 留下取证痕迹，不符合隐私目标（sqlite.org/pragma.html#pragma_secure_delete）。
        try execute(database, "PRAGMA secure_delete=ON")
        try execute(database, "PRAGMA foreign_keys=ON")
        try execute(database, """
            CREATE TABLE IF NOT EXISTS transcriptions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              text TEXT NOT NULL,
              raw_text TEXT,
              timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
              created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)
        let transcriptionColumns = try columnNames(database, table: "transcriptions")
        if !transcriptionColumns.contains("raw_text") {
            try execute(database, "ALTER TABLE transcriptions ADD COLUMN raw_text TEXT")
        }
        try execute(
            database,
            "CREATE INDEX IF NOT EXISTS idx_transcriptions_timestamp ON transcriptions(timestamp DESC)"
        )
        try execute(database, """
            CREATE TABLE IF NOT EXISTS custom_dictionary (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              word TEXT NOT NULL UNIQUE,
              created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)
        try execute(database, """
            CREATE TABLE IF NOT EXISTS correction_samples (
              history_id INTEGER PRIMARY KEY REFERENCES transcriptions(id) ON DELETE CASCADE,
              payload TEXT NOT NULL,
              processed INTEGER NOT NULL DEFAULT 0
            )
            """)
        try execute(database, """
            CREATE TABLE IF NOT EXISTS learned_terms (
              term_key TEXT PRIMARY KEY,
              payload TEXT NOT NULL
            )
            """)
    }

    private static func columnNames(_ database: OpaquePointer?, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            throw HistoryRepositoryError.sqlite(
                message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"
            )
        }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let name = sqlite3_column_text(statement, 1) {
                    names.insert(String(cString: name))
                }
            case SQLITE_DONE:
                return names
            default:
                throw HistoryRepositoryError.sqlite(
                    message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"
                )
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    private func execute(_ sql: String) throws {
        try Self.execute(database, sql)
    }

    private static func execute(_ database: OpaquePointer?, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errorMessage)
            throw HistoryRepositoryError.sqlite(message: message)
        }
    }

    private func currentError() -> HistoryRepositoryError {
        .sqlite(message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error")
    }
}

extension HistoryRepository {
    func correctionSamples(pendingOnly: Bool = true) throws -> [CorrectionSample] {
        try learningPayloads("SELECT payload FROM correction_samples \(pendingOnly ? "WHERE processed = 0" : "") ORDER BY history_id", as: CorrectionSample.self)
    }

    func saveCorrectionSample(_ sample: CorrectionSample) throws {
        // Deleted history must not be resurrected by a late capture callback.
        guard let record = try? record(id: sample.id), record.text == sample.original else { return }
        guard sample.original.utf16.count <= 16_000,
              (sample.corrected?.utf16.count ?? 0) <= 16_000 else {
            throw CorrectionLearningError.invalidCorrection
        }
        let statement = try prepare("""
            INSERT INTO correction_samples (history_id, payload, processed) VALUES (?, ?, 0)
            ON CONFLICT(history_id) DO UPDATE SET payload = excluded.payload, processed = 0
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sample.id)
        let json = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
        sqlite3_bind_text(statement, 2, json, -1, Self.transient)
        try stepDone(statement)
    }

    func learnedTerms() throws -> [LearnedTerm] {
        try learningPayloads("SELECT payload FROM learned_terms ORDER BY term_key", as: LearnedTerm.self)
    }

    func saveLearnedTerm(_ term: LearnedTerm) throws {
        let statement = try prepare("INSERT OR REPLACE INTO learned_terms (term_key, payload) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        let json = String(decoding: try JSONEncoder().encode(term), as: UTF8.self)
        sqlite3_bind_text(statement, 1, term.id, -1, Self.transient)
        sqlite3_bind_text(statement, 2, json, -1, Self.transient)
        try stepDone(statement)
    }

    /// Commit the batch cursor and candidates together; newer edits invalidate old results.
    func finishCorrectionBatch(_ samples: [CorrectionSample], terms: [LearnedTerm]) throws -> Bool {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let pending = try correctionSamples()
            guard samples.allSatisfy({ sample in pending.contains { $0.id == sample.id && $0.revision == sample.revision } }) else {
                try execute("ROLLBACK")
                return false
            }
            let existing = try learnedTerms()
            for var term in terms {
                if let prior = existing.first(where: { $0.id == term.id }) {
                    guard prior.status == "pending" else { continue }
                    let ids = Set(prior.evidence.map(\.sampleID))
                    term.evidence = Array((prior.evidence + term.evidence.filter { !ids.contains($0.sampleID) }).prefix(5))
                }
                try saveLearnedTerm(term)
            }
            let statement = try prepare("UPDATE correction_samples SET processed = 1 WHERE history_id = ?")
            defer { sqlite3_finalize(statement) }
            for sample in samples {
                sqlite3_reset(statement)
                sqlite3_bind_int64(statement, 1, sample.id)
                try stepDone(statement)
            }
            try execute("COMMIT")
            return true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func recoverCorrectionSessions() throws {
        for var sample in try correctionSamples() where !sample.ready {
            sample.ready = true
            sample.revision = UUID()
            try saveCorrectionSample(sample)
        }
    }

    func clearCorrectionLearning() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM correction_samples")
            try execute("DELETE FROM learned_terms")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func scrubLearningEvidence() throws {
        let surviving = Set(try correctionSamples(pendingOnly: false).map(\.id))
        for var term in try learnedTerms() {
            term.evidence.removeAll { !surviving.contains($0.sampleID) }
            if term.evidence.isEmpty && term.status == "pending" { term.status = "ignored" }
            try saveLearnedTerm(term)
        }
    }

    private func learningPayloads<T: Decodable>(_ sql: String, as: T.Type) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0) else { throw currentError() }
                values.append(try JSONDecoder().decode(T.self, from: Data(String(cString: text).utf8)))
            case SQLITE_DONE: return values
            default: throw currentError()
            }
        }
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer?

    init(pointer: OpaquePointer?) {
        self.pointer = pointer
    }

    deinit {
        if let pointer { sqlite3_close(pointer) }
    }
}

private enum SQLiteDateParser {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func date(from value: String) -> Date {
        formatter.date(from: value) ?? .distantPast
    }

    static func string(from value: Date) -> String {
        formatter.string(from: value)
    }
}
