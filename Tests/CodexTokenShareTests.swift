import SQLite3
import XCTest
@testable import Codenotch

/// The second line of a Codex session row: this conversation's share of the
/// day's tokens, read out of the rollout it writes.
///
/// Three things have to hold for the line to be worth anything. It has to count
/// the *day* the app counts — `UsageDay`'s boundary, which is a setting — and
/// not midnight. It has to add up the per-response increments Codex writes and
/// not the session's lifetime total, which is a number large enough to bury
/// every other row. And it has to read each rollout once and then only its
/// tail, because the files run to tens of megabytes and the monitor asks every
/// two seconds.
///
/// Main-actor, like the monitor whose `read` these drive — the same shape
/// `CodexOpenRolloutTests` uses for the same reason.
@MainActor
final class CodexTokenShareTests: XCTestCase {
    private var dir: URL!
    private let manager = FileManager.default

    /// Fixed, so a test's day is the test's rather than the machine's.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        dir = manager.temporaryDirectory
            .appendingPathComponent("CodexTokenShareTests-\(UUID().uuidString)")
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: dir)
        // The boundary is app-wide state, so a test that moves it puts it back
        // or the next class to file a day inherits this one's.
        UsageDay.configure(startHour: UsageDay.defaultStartHour)
    }

    // MARK: - The day

    /// **Six in the morning, not midnight.** The same increment belongs to
    /// today or not depending only on the hour the app counts from, and the
    /// day has to turn over when that hour passes.
    func testOnlyIncrementsInsideTheAppsDayAreCounted() throws {
        UsageDay.configure(startHour: 6)
        let url = try rollout("day", lines: [
            record(at: at(29, 5), tokens: 100),          // yesterday, still
            record(at: at(29, 6), tokens: 200),          // the first minute of today
            record(at: at(29, 23), tokens: 300),
        ])
        let usage = CodexRolloutUsage()

        // Five in the morning on the 30th is still the 29th's day, which is the
        // whole reason the boundary is not midnight.
        XCTAssertEqual(usage.tokensToday(in: url, now: at(30, 5), calendar: utc), 500)
    }

    /// The day rolls over, and what was counted for yesterday is not carried
    /// into it: the first look after the boundary reads the file again and
    /// finds nothing of the new day in it.
    func testTheDayStartsOverWhenTheBoundaryPasses() throws {
        UsageDay.configure(startHour: 6)
        let url = try rollout("rollover", lines: [
            record(at: at(29, 6), tokens: 200),
            record(at: at(29, 23), tokens: 300),
        ])
        let usage = CodexRolloutUsage()
        XCTAssertEqual(usage.tokensToday(in: url, now: at(30, 5), calendar: utc), 500)

        XCTAssertEqual(usage.tokensToday(in: url, now: at(30, 7), calendar: utc), 0,
                       "the new day began with none of the old day's tokens in it")

        try append(record(at: at(30, 6, 30), tokens: 400), to: url)
        XCTAssertEqual(usage.tokensToday(in: url, now: at(30, 8), calendar: utc), 400,
                       "only the new day's increment, not the old day's as well")
    }

    /// **A rollout rewritten in place is not read as a continuation of itself.**
    ///
    /// The cursor resumes on `(inode, size, offset)`, and an inode is not an
    /// identity on a copy-on-write filesystem: APFS hands a deleted file's
    /// number to the next one that asks for one. This rewrites the rollout at
    /// the same path — same inode, same length, different bytes — which the
    /// size check waves through and only a hash of the bytes behind the cursor
    /// can tell from a file that merely grew.
    ///
    /// Nothing afterwards would show it: the total is a sum of increments, so a
    /// wrong one is indistinguishable from a busy day.
    func testARolloutRewrittenInPlaceIsNotReadAsAContinuation() throws {
        let line = record(at: at(29, 12), tokens: 500) + "\n"
        let url = try rollout("replaced", lines: [record(at: at(29, 12), tokens: 500)])
        let usage = CodexRolloutUsage()

        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 13), calendar: utc), 500)

        // The same bytes in length and structure, a different number in them.
        let rewritten = line.replacingOccurrences(of: "500", with: "700")
        XCTAssertEqual(rewritten.utf8.count, line.utf8.count,
                       "the fixture has to keep the length, or the size check catches it instead")
        try Data(rewritten.utf8).write(to: url)

        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 13), calendar: utc), 700,
                       "the replacement's own total, not the one that was there before it")
    }

    /// **The lifetime figure is a different question.** `event_msg` /
    /// `token_count` carries the session's running total — 531 million for one
    /// session measured here — and counting it would swamp every other row.
    func testTheSessionsLifetimeTotalIsNotCounted() throws {
        UsageDay.configure(startHour: 6)
        let url = try rollout("lifetime", lines: [
            lifetime(531_127_690, last: 999),
            record(at: at(29, 12), tokens: 500),
            lifetime(531_128_000, last: 310),
        ])
        XCTAssertEqual(CodexRolloutUsage().tokensToday(in: url, now: at(29, 13), calendar: utc),
                       500)
    }

    /// The seed walks backwards past everything older than the day, however far
    /// that is. A conversation that has been running since yesterday keeps
    /// today's records at the end of a file whose beginning is yesterday's.
    func testTheBackwardsSeedFindsTodayBehindOlderWriting() throws {
        UsageDay.configure(startHour: 6)
        var lines = [record(at: at(28, 9), tokens: 1_000_000)]
        // Past one 256 KB window, so finding the boundary takes more than the
        // window the file ends in.
        lines += Array(repeating: filler(4_000), count: 100)
        lines.append(record(at: at(29, 8), tokens: 700))
        let url = try rollout("seed", lines: lines)

        let size = try XCTUnwrap(manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        XCTAssertGreaterThan(size.intValue, 256 * 1024, "the fixture must be more than one window")

        XCTAssertEqual(CodexRolloutUsage().tokensToday(in: url, now: at(29, 9), calendar: utc),
                       700)
    }

    // MARK: - Reading only the tail

    /// **Appending adds; re-reading does not duplicate.** The second look at a
    /// grown file must count the bytes that arrived since the first and leave
    /// the ones already folded in alone.
    func testAppendingAddsToTheDayWithoutCountingWhatWasAlreadyRead() throws {
        UsageDay.configure(startHour: 6)
        let url = try rollout("tail", lines: [record(at: at(29, 7), tokens: 100)])
        let usage = CodexRolloutUsage()
        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 8), calendar: utc), 100)

        try append(record(at: at(29, 8), tokens: 250), to: url)
        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 9), calendar: utc), 350)

        // Half a line is not a record yet — the writer was mid-append. It is
        // read again next tick rather than being skipped for good.
        let whole = record(at: at(29, 9), tokens: 900)
        try append(String(whole.prefix(40)), to: url, newline: false)
        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 10), calendar: utc), 350,
                       "a half-written line was counted as a record")

        try append(String(whole.dropFirst(40)), to: url)
        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 11), calendar: utc), 1_250,
                       "the finished line was lost")
    }

    /// A rollout cut back to nothing is read from the start again rather than
    /// being trusted at the cursor the longer file left behind.
    func testATruncatedRolloutIsReadAgain() throws {
        UsageDay.configure(startHour: 6)
        let url = try rollout("truncated", lines: [
            record(at: at(29, 7), tokens: 100),
            record(at: at(29, 8), tokens: 250),
        ])
        let usage = CodexRolloutUsage()
        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 9), calendar: utc), 350)

        try Data().write(to: url)
        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 10), calendar: utc), 0)
    }

    /// A record whose line is cut by a seed window's boundary is reassembled
    /// rather than dropped. Without the carry, a large rollout loses about one
    /// record per 256 KB — the day comes out quietly short, which is the worst
    /// way for a number to be wrong.
    func testARecordCutByASeedWindowBoundaryIsStillCounted() throws {
        UsageDay.configure(startHour: 6)
        let window = 256 * 1024
        let line = record(at: at(29, 7), tokens: 4_242) + "\n"
        var text = record(at: at(28, 9), tokens: 1) + "\n"
        let start = text.utf8.count
        text += line
        let pad = filler(2_000) + "\n"
        let target = start + window + line.utf8.count / 2
        var size = text.utf8.count
        while size < target {
            text += pad
            size += pad.utf8.count
        }
        let url = dir.appendingPathComponent("straddle.jsonl")
        try Data(text.utf8).write(to: url)

        XCTAssertGreaterThan(size - window, start)
        XCTAssertLessThan(size - window, start + line.utf8.count,
                          "the fixture must put the window boundary inside the record")
        XCTAssertEqual(CodexRolloutUsage().tokensToday(in: url, now: at(29, 9), calendar: utc),
                       4_242)
    }

    /// **A window that opens on a newline is still the window a carried line
    /// began in.** Skipping the carry there lost the record every time a window
    /// boundary happened to land on a line break — the record came out as zero,
    /// which no total elsewhere on the card would have contradicted.
    func testARecordCutWhereTheOlderWindowOpensOnANewlineIsStillCounted() throws {
        UsageDay.configure(startHour: 6)
        let line = record(at: at(29, 7), tokens: 4_242) + "\n"
        let content = line.utf8.count - 1
        let half = content / 2
        // `filler(n)` is n bytes of text plus its own scaffolding.
        let overhead = filler(0).utf8.count
        let opening = record(at: at(28, 9), tokens: 1) + "\n"

        var text = opening
        // A line long enough to put the *previous* window's first byte on the
        // opening line's newline, while the record straddles the boundary
        // 256 KB further on.
        text += filler(262_142 - half - overhead) + "\n"
        let start = text.utf8.count
        text += line
        text += filler(262_143 - half - 1 - overhead) + "\n"

        let url = dir.appendingPathComponent("opens-on-newline.jsonl")
        try Data(text.utf8).write(to: url)

        let size = text.utf8.count
        XCTAssertEqual(size - 524_288, opening.utf8.count - 1,
                       "the fixture must open the older window on a newline")
        XCTAssertGreaterThan(size - 262_144, start)
        XCTAssertLessThan(size - 262_144, start + content,
                          "the fixture must cut the record")

        XCTAssertEqual(CodexRolloutUsage().tokensToday(in: url, now: at(29, 9), calendar: utc),
                       4_242)
    }

    /// **The first look usually lands mid-append**, because the rollouts being
    /// read are the ones being written to. A half-written last line is not a
    /// record yet, and the rest of it must be counted when it arrives.
    func testSeedingWhileTheLastRecordIsHalfWrittenCountsItOnceItArrives() throws {
        UsageDay.configure(startHour: 6)
        let whole = record(at: at(29, 9), tokens: 900)
        let url = try rollout("live", lines: [record(at: at(29, 7), tokens: 100),
                                              record(at: at(29, 8), tokens: 250)])
        try append(String(whole.prefix(60)), to: url, newline: false)
        let usage = CodexRolloutUsage()
        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 10), calendar: utc), 350,
                       "a fragment is not a record")

        try append(String(whole.dropFirst(60)), to: url)
        XCTAssertEqual(usage.tokensToday(in: url, now: at(29, 11), calendar: utc), 1_250,
                       "the completed record was counted once it arrived")
    }

    // MARK: - The share

    /// The share is the row's tokens over the rows' total, with the absolute
    /// beside it. The two halves answer different questions: the percentage
    /// ranks rows against each other, the count says how big the day was.
    func testTheShareIsTheRowsTokensOverTheRowsTotal() {
        XCTAssertEqual(CodexActivityMonitor.tokenDetail(tokens: 42_000_000, of: 100_000_000),
                       "42% · 42.0M")
        XCTAssertEqual(CodexActivityMonitor.tokenDetail(tokens: 128_400_000, of: 300_000_000),
                       "43% · 128.4M")
        XCTAssertEqual(CodexActivityMonitor.tokenDetail(tokens: 1, of: 3), "33% · 1")
        XCTAssertEqual(CodexActivityMonitor.tokenDetail(tokens: 5, of: 5), "100% · 5")
        // Nothing today is a fact, said as one. "0%" on a card of idle rows is
        // a line of zeroes saying nothing.
        XCTAssertEqual(CodexActivityMonitor.tokenDetail(tokens: 0, of: 0), "No tokens today")
        // No denominator, no share to state.
        XCTAssertNil(CodexActivityMonitor.tokenDetail(tokens: 5, of: 0))
    }

    /// A row whose rollout cannot be read keeps the line it already had.
    /// Calling an unreadable file zero would rank it last with the same
    /// confidence as a reading, which is worse than saying nothing.
    func testARowWhoseRolloutCannotBeReadKeepsTheLineItHad() {
        let row = AgentSession(id: "codex.a", name: "Working", detail: "Working",
                               state: .busy, waitingFor: nil, since: now)
        let rows = CodexActivityMonitor.withTokenShares(
            [row], files: ["codex.a": [URL(fileURLWithPath: "/nonexistent/rollout-a.jsonl")]],
            usage: CodexRolloutUsage(), now: now
        )
        XCTAssertEqual(rows.first?.detail, "Working")
    }

    /// The desktop app writes no rollout, so its row has nothing to divide and
    /// is left exactly as it was built.
    func testARowWithNoRolloutIsLeftAlone() {
        let row = AgentSession(id: "codex.desktop", name: "Desktop chat", detail: "Working",
                               state: .busy, waitingFor: nil, since: now)
        let rows = CodexActivityMonitor.withTokenShares([row], files: [:],
                                                        usage: CodexRolloutUsage(), now: now)
        XCTAssertEqual(rows.first?.detail, "Working")
    }

    // MARK: - On the monitor's own rows

    /// End to end: two conversations, one day, and the shares divide it between
    /// them exactly as the card draws them.
    func testTheRowsDivideTheDayBetweenThem() throws {
        UsageDay.configure(startHour: 6)
        let store = try makeStore([
            (id: "big", name: "The big one", written: 1,
             lines: [record(at: at(29, 7), tokens: 7_500_000)]),
            (id: "small", name: "The small one", written: 2,
             lines: [record(at: at(29, 7), tokens: 2_500_000)]),
        ])
        let rows = read(store)

        XCTAssertEqual(rows.map(\.name), ["The big one", "The small one"])
        XCTAssertEqual(rows.map(\.detail), ["75% · 7.5M", "25% · 2.5M"])
    }

    /// A helper's rollout counts for the conversation it works for: the work a
    /// request does is mostly done by the sub-agents it spawned, and crediting
    /// only the root's own file would rank the busiest request last.
    func testAHelpersRolloutCountsForItsConversation() throws {
        UsageDay.configure(startHour: 6)
        let store = try makeStore([
            (id: "root", name: "Audit the checkout", written: 2,
             lines: [record(at: at(29, 7), tokens: 1_000_000)]),
        ])
        // The helper is a thread of that conversation with a rollout of its own.
        let helper = try rollout("helper", lines: [record(at: at(29, 7), tokens: 3_000_000)],
                                 written: 1)
        try exec(store, """
            INSERT INTO threads VALUES ('helper', '\(helper.path)', 0, 999998, NULL, NULL,
                NULL, '/Users/someone/app',
                '{"subagent":{"thread_spawn":{"parent_thread_id":"root","depth":1}}}')
            """)

        let rows = read(store)
        XCTAssertEqual(rows.count, 1, "the helper is part of the conversation, not a row of its own")
        XCTAssertEqual(rows.first?.detail, "100% · 4.0M",
                       "the conversation's day is the root's tokens and its helper's")
    }

    /// The monitor hands its reader back on every tick, so a second reading of
    /// a grown rollout adds only what was appended — this is the incremental
    /// path the design exists for, driven the way `rescan` drives it.
    func testASecondReadingOfTheRowsCountsOnlyWhatWasAppended() throws {
        UsageDay.configure(startHour: 6)
        let store = try makeStore([
            (id: "a", name: "Growing", written: 1,
             lines: [record(at: at(29, 7), tokens: 100)]),
        ])
        let usage = CodexRolloutUsage()
        XCTAssertEqual(read(store, usage: usage).first?.detail, "100% · 100")

        try append(record(at: at(29, 8), tokens: 300), to: dir.appendingPathComponent("rollout-a.jsonl"))
        XCTAssertEqual(read(store, usage: usage).first?.detail, "100% · 400")
    }

    // MARK: - Fixtures

    /// A fixed UTC calendar, so a fixture's hour means what it says wherever
    /// the suite runs — the reader takes the calendar for exactly this.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 9, day: day,
                                      hour: hour, minute: minute))!
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// One `token_usage_record` in the shape Codex writes: a top-level
    /// timestamp, and the increment that one response spent under
    /// `payload.usage.total_tokens`.
    private func record(at date: Date, tokens: Int) -> String {
        """
        {"timestamp":"\(Self.stamp.string(from: date))","ordinal":1,\
        "type":"token_usage_record","payload":{"thread_id":"t","turn_id":"u",\
        "session_id":"t","response_id":"r","usage":{"input_tokens":\(tokens),\
        "cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,\
        "reasoning_output_tokens":0,"total_tokens":\(tokens)},"turn_token_usage":{}}}
        """
    }

    /// The lifetime figure Codex writes beside the increments, which is
    /// deliberately *not* what the day is counted from.
    private func lifetime(_ total: Int, last: Int) -> String {
        """
        {"timestamp":"\(Self.stamp.string(from: now))","type":"event_msg",\
        "payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(total)},\
        "last_token_usage":{"total_tokens":\(last)}}}}
        """
    }

    /// A line of the kind that makes a rollout large — payload from a tool call
    /// — carrying no token record at all.
    private func filler(_ bytes: Int) -> String {
        #"{"type":"response_item","payload":{"text":""# + String(repeating: "x", count: bytes)
            + #""}}"#
    }

    @discardableResult
    private func rollout(_ name: String, lines: [String],
                         written: TimeInterval = 1) throws -> URL {
        let url = dir.appendingPathComponent("rollout-\(name).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try manager.setAttributes([.modificationDate: now.addingTimeInterval(-written)],
                                  ofItemAtPath: url.path)
        return url
    }

    /// Appends the way Codex does: at the end, without rewriting what is there.
    private func append(_ text: String, to url: URL, newline: Bool = true) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data((text + (newline ? "\n" : "")).utf8))
    }

    // MARK: - A monitor driven from a real store

    private func read(_ store: URL, usage: CodexRolloutUsage = CodexRolloutUsage()) -> [AgentSession] {
        CodexActivityMonitor.read(stateStore: store,
                                  desktopStore: dir.appendingPathComponent("none.db"),
                                  staleAfter: 8, now: now, usage: usage)
    }

    /// A `threads` store of the shape Codex writes, with one rollout per row.
    private func makeStore(_ rows: [(id: String, name: String, written: TimeInterval,
                                     lines: [String])]) throws -> URL {
        let url = dir.appendingPathComponent("state_5.sqlite")
        try exec(url, """
            CREATE TABLE threads (id TEXT, rollout_path TEXT, archived INTEGER,
                                  updated_at_ms INTEGER, name TEXT, preview TEXT,
                                  title TEXT, cwd TEXT, source TEXT)
            """)
        for row in rows {
            let rollout = try rollout(row.id, lines: row.lines, written: row.written)
            try exec(url, """
                INSERT INTO threads VALUES ('\(row.id)', '\(rollout.path)', 0, \
                \(Int(1_000_000 - row.written)), '\(row.name)', NULL, NULL, \
                '/Users/someone/app', 'exec')
                """)
        }
        return url
    }

    private func exec(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }
}
