import Carbon
import Foundation
import QuartzCore
import SQLite3

/// What kind of key a logged press was. Never the key itself.
enum LogKind: String {
    case left, right, double, apostrophe, space, punct, backspace, enter, other
}

/// Records one row per key press into a local SQLite file: when it happened, its
/// kind, how long it was held, the gap to the next press, and which cues fired.
/// It never stores which key was pressed, so your text can't be rebuilt from it.
///
/// Everything except the database writes happens on the main thread.
final class Recorder {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tblink", isDirectory: true)
    }
    static var databaseURL: URL { directory.appendingPathComponent("tblink.sqlite") }

    private let hesitationThreshold: TimeInterval
    /// A press waits in memory this long for its release and for the next press,
    /// so hold time and gap can be filled in. Longer gaps are stored as empty.
    private let flushDelay: TimeInterval = 6

    // Main thread.
    private var sessionStart: CFTimeInterval?
    private var pending: [Press] = []
    private var heldKeys: [Int64: Press] = [:]
    private var tickTimer: Timer?
    private var secureInputOn = false

    // Database, only touched on `queue`.
    private let queue = DispatchQueue(label: "tblink.recorder")
    private var db: OpaquePointer?
    private var sessionId: Int64?

    private final class Press {
        /// Kept in memory only, to match the key's release to its press. Never written.
        let keyCode: Int64
        let t: CFTimeInterval
        let kind: LogKind
        let hand: String?
        let shift: Bool
        let isRepeat: Bool
        let cues: [String]
        let armsHesitation: Bool
        var holdMs: Double?
        var released = false
        var gapAfter: Double?

        init(keyCode: Int64, t: CFTimeInterval, kind: LogKind, hand: String?, shift: Bool,
             isRepeat: Bool, cues: [String], armsHesitation: Bool) {
            self.keyCode = keyCode
            self.t = t
            self.kind = kind
            self.hand = hand
            self.shift = shift
            self.isRepeat = isRepeat
            self.cues = cues
            self.armsHesitation = armsHesitation
        }
    }

    init(hesitationThreshold: TimeInterval) {
        self.hesitationThreshold = hesitationThreshold
        queue.async { self.openDatabase() }
    }

    // MARK: - Sessions

    /// A session runs while tblink is on and the Mac is awake.
    func startSession() {
        guard sessionStart == nil else { return }
        sessionStart = CACurrentMediaTime()
        secureInputOn = IsSecureEventInputEnabled()
        let startedAt = Self.wallClock()
        let secure = secureInputOn
        queue.async {
            guard self.db != nil else { return }
            self.run("INSERT INTO sessions (started_at) VALUES (?)", [.text(startedAt)])
            self.sessionId = sqlite3_last_insert_rowid(self.db)
            if secure { self.insertMarker(t: 0, name: "secure-input-on") }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Writes everything still waiting and closes the session. Blocks until it's on disk.
    func endSession(reason: String) {
        guard sessionStart != nil else { return }
        flush(force: true)
        heldKeys.removeAll()
        tickTimer?.invalidate()
        tickTimer = nil
        sessionStart = nil
        let endedAt = Self.wallClock()
        queue.sync {
            guard let id = self.sessionId else { return }
            self.run("UPDATE sessions SET ended_at = ?, end_reason = ? WHERE id = ?",
                     [.text(endedAt), .text(reason), .int(id)])
            self.sessionId = nil
        }
    }

    // MARK: - Key events

    func keyDown(keyCode: Int64, kind: LogKind, hand: String?, shift: Bool, isRepeat: Bool,
                 cues: [String], armsHesitation: Bool, at t: CFTimeInterval) {
        guard sessionStart != nil else { return }
        if let previous = pending.last, previous.gapAfter == nil {
            previous.gapAfter = t - previous.t
        }
        let press = Press(keyCode: keyCode, t: t, kind: kind, hand: hand, shift: shift,
                          isRepeat: isRepeat, cues: cues, armsHesitation: armsHesitation)
        pending.append(press)
        heldKeys[keyCode] = press
    }

    func keyUp(keyCode: Int64, at t: CFTimeInterval) {
        guard let press = heldKeys.removeValue(forKey: keyCode) else { return }
        press.holdMs = (t - press.t) * 1000
        press.released = true
    }

    // MARK: - Writing

    private func tick() {
        // Password fields hide keys from tblink; mark those stretches so the silence
        // isn't mistaken for hesitation.
        let secure = IsSecureEventInputEnabled()
        if secure != secureInputOn, let start = sessionStart {
            secureInputOn = secure
            let t = CACurrentMediaTime() - start
            queue.async { self.insertMarker(t: t, name: secure ? "secure-input-on" : "secure-input-off") }
        }
        flush(force: false)
    }

    /// Writes presses whose hold time and following gap are known (or that have
    /// waited long enough), oldest first.
    private func flush(force: Bool) {
        guard let start = sessionStart else { return }
        let now = CACurrentMediaTime()
        var rows: [[Value]] = []
        while let first = pending.first {
            let complete = first.released && first.gapAfter != nil
            guard force || complete || now - first.t >= flushDelay else { break }
            pending.removeFirst()
            if heldKeys[first.keyCode] === first { heldKeys[first.keyCode] = nil }

            let waited = first.gapAfter ?? (now - first.t)
            let alarm = first.armsHesitation && waited >= hesitationThreshold
            rows.append([
                .real(first.t - start),
                .text(first.kind.rawValue),
                first.hand.map { .text($0) } ?? .null,
                .int(first.shift ? 1 : 0),
                .int(first.isRepeat ? 1 : 0),
                first.holdMs.map { .real($0) } ?? .null,
                first.gapAfter.map { .real($0 * 1000) } ?? .null,
                .int(alarm ? 1 : 0),
                first.cues.isEmpty ? .null : .text(first.cues.joined(separator: ",")),
            ])
        }
        guard !rows.isEmpty else { return }
        queue.async {
            guard let id = self.sessionId else { return }
            self.exec("BEGIN")
            for row in rows {
                self.run("""
                    INSERT INTO events (session_id, t, kind, hand, shift, is_repeat,
                                        hold_ms, gap_after_ms, alarm, cues)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.int(id)] + row)
            }
            self.exec("COMMIT")
        }
    }

    // MARK: - SQLite (on `queue`)

    private enum Value {
        case int(Int64), real(Double), text(String), null
    }

    private func openDatabase() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        } catch {
            NSLog("tblink: can't create log folder: %@", error.localizedDescription)
            return
        }
        guard sqlite3_open(Self.databaseURL.path, &db) == SQLITE_OK else {
            NSLog("tblink: can't open log database")
            db = nil
            return
        }
        exec("PRAGMA journal_mode = WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                id         INTEGER PRIMARY KEY,
                started_at TEXT NOT NULL,   -- local date and time, ISO 8601
                ended_at   TEXT,
                end_reason TEXT             -- off, sleep, quit
            );
            CREATE TABLE IF NOT EXISTS events (
                id           INTEGER PRIMARY KEY,
                session_id   INTEGER NOT NULL REFERENCES sessions(id),
                t            REAL NOT NULL,     -- seconds since the session started
                kind         TEXT NOT NULL,     -- left right double apostrophe space punct backspace enter other
                hand         TEXT,              -- left/right for left, right and double
                shift        INTEGER NOT NULL,  -- 1 if Shift was held
                is_repeat    INTEGER NOT NULL,  -- 1 if a non-letter key repeated the previous key ('' .. double space)
                hold_ms      REAL,              -- how long the key was held; empty if unknown
                gap_after_ms REAL,              -- time until the next press; empty if over 6 s or the session ended
                alarm        INTEGER NOT NULL,  -- 1 if the hesitation alarm went off after this press
                cues         TEXT               -- other cues that fired: double, punct-typo, apostrophe
            );
            CREATE TABLE IF NOT EXISTS markers (
                id         INTEGER PRIMARY KEY,
                session_id INTEGER NOT NULL REFERENCES sessions(id),
                t          REAL NOT NULL,
                name       TEXT NOT NULL        -- secure-input-on, secure-input-off
            );
            CREATE INDEX IF NOT EXISTS events_session_t ON events(session_id, t);
            """)
    }

    private func insertMarker(t: Double, name: String) {
        guard let id = sessionId else { return }
        run("INSERT INTO markers (session_id, t, name) VALUES (?, ?, ?)", [.int(id), .real(t), .text(name)])
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("tblink sqlite: %@", String(cString: sqlite3_errmsg(db)))
        }
    }

    private func run(_ sql: String, _ values: [Value]) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("tblink sqlite: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let x): sqlite3_bind_int64(stmt, index, x)
            case .real(let x): sqlite3_bind_double(stmt, index, x)
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("tblink sqlite: %@", String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func wallClock() -> String {
        ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                    formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }
}
