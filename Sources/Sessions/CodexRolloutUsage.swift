import Foundation

/// Today's token consumption, read out of the rollout files Codex appends to.
///
/// The Codex rows on the notch used to spend their second line on the state
/// word — "Working", "Complete" — which the row already says beside its name,
/// so the line told the reader nothing the first line had not. What the card
/// could not say was which of the conversations open right now is costing the
/// most, and that is in the rollouts: Codex writes one `token_usage_record` per
/// response, carrying what that one response spent.
///
/// **Increments, not the running total.** Each record's
/// `payload.usage.total_tokens` is what that response used, so adding up the
/// records a day contains gives the day. The `token_count` events beside them
/// carry the session's *lifetime* figure — 531 million for one session measured
/// on this machine — and would answer a different question entirely, which is
/// why nothing here looks at them.
///
/// **Read incrementally, because the files are enormous.** A rollout runs to
/// tens of megabytes and is being appended to while it is read, and the
/// activity monitor asks every two seconds: re-reading one per tick would put a
/// full parse of an 80 MB file in the middle of the UI's own run loop. So each
/// file is read once — backwards, in windows, far enough to cover the current
/// day — and after that only the bytes appended since the last look are
/// parsed. Rollouts are append-only, so what has been read once never needs
/// reading again.
///
/// The day is `UsageDay`'s, not midnight's: work that runs past six in the
/// morning belongs to the evening that produced it, and this has to count it
/// the same way the ledger and the cost log beside it do.
final class CodexRolloutUsage {
    /// One window of the backwards seed, and one chunk of the forwards read.
    ///
    /// 256 KB is what `CodexRolloutActivity` walks its rollouts in, for the same
    /// reason: a token record is a few hundred bytes, so a window is cheap, and
    /// a chunk of this size keeps a megabyte-long `tool_call` line from being
    /// held whole.
    private static let windowBytes: UInt64 = 256 * 1024

    /// How far the seed will walk before it settles for a floor. The walk stops
    /// at the first record older than the day, so this is a runaway guard
    /// rather than a budget: 1024 windows is 256 MB written into one rollout in
    /// one day, which no session measured here comes near. Reaching it means
    /// the figure is an undercount — the one place this can be quietly wrong,
    /// and it can only rank a monster session too low.
    private static let maxSeedWindows = 1024

    /// A line longer than this cannot be a token record. Real ones are under a
    /// kilobyte; the multi-megabyte lines are `tool_call` payloads carrying
    /// whole files. Refusing to hold them is what keeps the cost of a scan
    /// proportional to the records in a rollout rather than to its size — and
    /// it is also what bounds the fragment carried between windows, which is
    /// the difference between a walk over a rollout holding one long line and a
    /// quadratic one. A real 80 MB rollout with an 8 MB line in it measured
    /// 800 ms before this bound and 100 ms after, for the same total.
    private static let longestRecord = 64 * 1024

    /// The substring every token record carries, checked before the JSON
    /// parser is handed anything. Most lines in a rollout are tool output and
    /// never get past this.
    private static let marker = Data("token_usage_record".utf8)
    private static let newline = UInt8(ascii: "\n")

    /// Codex writes `2026-10-01T12:03:50.522Z`; the plain form is accepted too,
    /// because older rollouts omit the milliseconds.
    private static let isoWithMillis: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// What is known about one rollout between ticks.
    private struct Cursor {
        /// The day `tokens` counts. The boundary is a setting the user can move
        /// at any moment, so which day a total belongs to is part of the total.
        let dayStart: Date
        /// The file's identity when it was read. A rollout replaced by another
        /// at the same path must not be credited with the first one's bytes.
        let inode: UInt64
        /// How much of the file has been folded in. Always the offset of a line
        /// start, or the start of the file, so the next read begins on a whole
        /// line rather than in the middle of one.
        var offset: UInt64
        /// Today's increments so far.
        var tokens: Int
        /// A hash of the bytes just before `offset`. See `fingerprint(of:endingAt:)`
        /// for why the inode above is not enough on its own.
        var fingerprint: UInt64
    }

    /// The day's beginning, in the two forms a record is judged against: the
    /// instant, and the text its own timestamp can be compared to without a
    /// date parser. See `moment(of:today:)`.
    private struct Boundary {
        let start: Date
        let stamp: String
    }

    private var cursors: [String: Cursor] = [:]
    /// Formatted once per day rather than once per record, or once per tick.
    private var boundary: Boundary?

    /// Today's tokens for the rollout at `url`.
    ///
    /// Nil, never zero, when the file cannot be read: a row that cannot see its
    /// own rollout has no number to show, and the caller says so rather than
    /// printing "0%". A file that reads cleanly and holds nothing from today
    /// answers zero, which is a fact about the session rather than a gap in the
    /// reading.
    func tokensToday(in url: URL, now: Date, calendar: Calendar = .current) -> Int? {
        let today = boundary(for: now, calendar: calendar)
        let path = url.path
        guard let file = Self.identity(of: url) else {
            // A rollout that has gone cannot answer for itself, and a cursor
            // held for it would be wrong for whatever appears at that path next.
            cursors.removeValue(forKey: path)
            return nil
        }

        if var cursor = cursors[path], cursor.dayStart == today.start, cursor.inode == file.inode,
           file.size >= cursor.offset,
           Self.fingerprint(of: url, endingAt: cursor.offset) == cursor.fingerprint {
            let resumed = cursor.offset
            if file.size > resumed,
               !fold(url: url, from: resumed, into: &cursor, day: today) {
                return nil
            }
            // The read moved the cursor, so the fingerprint has to move with it:
            // it answers "are the bytes behind me still mine", and it is now
            // standing somewhere else.
            if cursor.offset != resumed {
                cursor.fingerprint = Self.fingerprint(of: url, endingAt: cursor.offset) ?? 0
            }
            cursors[path] = cursor
            return cursor.tokens
        }

        // First sight of this file, or one whose day, identity or length has
        // moved out from under the cursor — the day boundary crossing, a
        // rollout replaced by another at the same path, or a file cut back to
        // nothing. All three want the same answer, and the backwards walk gives
        // it in one pass: today's total so far, and where the last whole line
        // of the file ends, which is where every later tick reads from.
        //
        // A day crossing takes this branch too rather than resetting the total
        // in place. That is one walk per rollout per day, and it keeps a single
        // way of arriving at a total instead of two that have to agree.
        guard let seed = seed(url: url, size: file.size, day: today) else { return nil }
        cursors[path] = Cursor(dayStart: today.start, inode: file.inode,
                               offset: seed.offset, tokens: seed.tokens,
                               fingerprint: Self.fingerprint(of: url, endingAt: seed.offset) ?? 0)
        return seed.tokens
    }

    /// The day in force, formatted once and held until it changes.
    private func boundary(for now: Date, calendar: Calendar) -> Boundary {
        let start = UsageDay.start(of: now, calendar: calendar)
        if let boundary, boundary.start == start { return boundary }
        let made = Boundary(start: start, stamp: Self.isoWithMillis.string(from: start))
        boundary = made
        return made
    }

    /// Drops what is held for rollouts nothing is asking about, so a long-lived
    /// app does not keep a cursor for every conversation it has ever drawn.
    func forget(keeping live: Set<String>) {
        cursors = cursors.filter { live.contains($0.key) }
    }

    // MARK: Finding where today begins

    /// What one walk backwards found: today's total so far, and where the next
    /// read should start.
    private struct Seed {
        let tokens: Int
        /// The end of the file's last whole line — the start of any line still
        /// being written, so the next tick reads that one again rather than
        /// skipping it, and reads nothing that has already been added up.
        let offset: UInt64
    }

    /// Walks `url` backwards from its end, adding up today as it goes.
    ///
    /// Rollouts are written in time order, so the newest record older than the
    /// day is the last one before it: everything at an earlier offset is older
    /// still, and everything already passed on the way is today's. That is what
    /// lets one walk both find the boundary and total the day, instead of
    /// finding the boundary and then reading the whole stretch forwards again.
    ///
    /// The walk stops at an older record rather than at a byte offset, and the
    /// cursor it leaves is the end of the file's last whole line rather than
    /// the boundary: a line still being written is read again next tick, and
    /// nothing behind the cursor was left uncounted, so nothing is counted
    /// twice.
    ///
    /// A clock stepped backwards mid-file would break the time-order assumption
    /// and cost the few records it moved. Checking for that means scanning the
    /// whole file every time, which is the cost this design exists to avoid.
    private func seed(url: URL, size: UInt64, day: Boundary) -> Seed? {
        guard size > 0 else { return Seed(tokens: 0, offset: 0) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var windowEnd = size
        var windows = 0
        var tokens = 0
        var offset: UInt64?
        /// The leading fragment of the window last read: the tail of a line
        /// whose beginning is in the window below it, and which is therefore
        /// only parseable once that window has been read too. Never longer than
        /// a record: a run of a long line past that length cannot be a record,
        /// so holding the megabytes of it — and copying them again into every
        /// window the line runs through — buys nothing and costs everything.
        var carried = Data()
        while windowEnd > 0, windows < Self.maxSeedWindows {
            windows += 1
            let windowStart = windowEnd > Self.windowBytes ? windowEnd - Self.windowBytes : 0
            let expected = Int(windowEnd - windowStart)
            guard var window = Self.read(handle, from: windowStart, count: windowEnd - windowStart)
            else { return nil }

            // Where the last whole line of the file ends, taken from the first
            // window that holds a line break — which is the newest one that
            // does, because the walk starts at the end.
            if offset == nil, let lastBreak = window.lastIndex(of: Self.newline) {
                offset = windowStart + UInt64(window.distance(from: window.startIndex,
                                                              to: lastBreak)) + 1
            }

            // Joining the newer window's leading fragment back onto this one
            // completes the line it was the tail of, so the record it holds is
            // counted rather than dropped for being half a line — the same
            // carry `CodexRolloutActivity` walks its windows with, and the
            // reason a long file does not lose a record per window boundary. A
            // short read means the file shrank and the two are no longer
            // contiguous, so the carry is dropped instead.
            //
            // Deliberately not conditioned on this window opening on a line
            // break: that says nothing about the fragment. A window whose first
            // byte is a newline can still be the window a carried line began
            // in, and skipping the carry there lost that line's record — one
            // per 256 KB in a file whose lines happen to land on the boundary.
            if window.count == expected, !carried.isEmpty {
                window.append(carried)
            }
            var lines = window.split(separator: Self.newline, omittingEmptySubsequences: true)

            // A window opens mid-line unless it opens on a line break: its
            // first line is then the tail of one whose beginning is below, and
            // it is carried rather than parsed here. Past the cap it cannot be
            // part of a record, so its bytes stop being carried: the window's
            // last line is left as the bare fragment it is, which no parse
            // accepts, and the completed line would have been over the cap too.
            let opensOnALineBreak = window.first == Self.newline
            if windowStart > 0, !opensOnALineBreak, let fragment = lines.first {
                carried = fragment.count <= Self.longestRecord ? Data(fragment) : Data()
                lines.removeFirst()
            } else {
                carried = Data()
            }

            // One scan for the marker before any splitting: a rollout's last
            // megabyte is usually tool output, and this is what keeps a window
            // of it from being walked line by line.
            if window.range(of: Self.marker) != nil {
                // Newest line first, so the records are added in the order they
                // were written and the first one that reads as older ends it.
                for line in lines.reversed() {
                    guard let record = Self.record(from: line) else { continue }
                    // Only a record that *reads as* older ends the walk. One
                    // whose stamp cannot be read is not evidence that the lines
                    // before it are older too, and stopping on it would drop
                    // everything the file holds after the last old record —
                    // which is exactly today.
                    switch Self.moment(of: record.stamp, today: day) {
                    case .today:
                        tokens += record.tokens
                    case .older:
                        return Seed(tokens: tokens, offset: offset ?? windowStart)
                    case .unknown:
                        continue
                    }
                }
            }
            windowEnd = windowStart
        }
        // Either the whole file is today's, or the runaway guard above ran out
        // — in which case today's total is a floor, never a claim. Either way
        // the next read starts where the last whole line ended.
        return Seed(tokens: tokens, offset: offset ?? 0)
    }

    // MARK: Reading forwards

    /// Folds every complete line from `from` to the end of the file into
    /// `cursor`, advancing it past the last whole line.
    ///
    /// The last line of a file being written to is routinely half a line — the
    /// writer was mid-append when the tick landed — and half a JSON object
    /// parses as nothing. So the cursor is left at the start of that line and
    /// the bytes are read again next tick, by which time the rest of the record
    /// has arrived. Advancing past it would drop that record for good.
    private func fold(url: URL, from: UInt64, into cursor: inout Cursor, day: Boundary) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              (try? handle.seek(toOffset: from)) != nil
        else { return false }
        defer { try? handle.close() }

        var tokens = cursor.tokens
        var pending = Data()
        /// True once the line being read is too long to be a record, which is
        /// also when its bytes stop being held.
        var overflowed = false
        /// How many bytes of the line being read have arrived, kept even when
        /// `pending` was dropped, so the cursor can be left at that line's start.
        var lineLength = 0

        while let chunk = try? handle.read(upToCount: Int(Self.windowBytes)), !chunk.isEmpty {
            var start = chunk.startIndex
            while start < chunk.endIndex,
                  let breakAt = chunk[start...].firstIndex(of: Self.newline) {
                append(chunk[start..<breakAt], to: &pending, overflowed: &overflowed,
                       lineLength: &lineLength)
                if !overflowed,
                   let record = Self.record(from: pending),
                   case .today = Self.moment(of: record.stamp, today: day) {
                    tokens += record.tokens
                }
                pending.removeAll(keepingCapacity: true)
                overflowed = false
                lineLength = 0
                start = chunk.index(after: breakAt)
            }
            // What is left of the chunk holds no newline: it is the beginning,
            // or the middle, of the line the cursor will stop at.
            append(chunk[start...], to: &pending, overflowed: &overflowed, lineLength: &lineLength)
        }

        cursor.tokens = tokens
        // The cursor belongs at the start of the line that was left unfinished,
        // which is the end of what was read minus however much of it arrived.
        let end = handle.offsetInFile
        cursor.offset = end >= UInt64(lineLength) ? end - UInt64(lineLength) : from
        return true
    }

    /// Collects one piece of a line, dropping the bytes once the line has grown
    /// past anything a record could be.
    private func append(_ piece: Data, to pending: inout Data,
                        overflowed: inout Bool, lineLength: inout Int) {
        lineLength += piece.count
        guard lineLength <= Self.longestRecord else {
            if !overflowed {
                overflowed = true
                pending.removeAll(keepingCapacity: false)
            }
            return
        }
        pending.append(piece)
    }

    // MARK: One line

    /// The moment and the increment of a `token_usage_record`, or nil for every
    /// other line — which is nearly all of them.
    ///
    /// The marker and the length are checked before the JSON parser is: a line
    /// is allowed to carry a whole file inside it, and handing one of those to
    /// the parser is the only way this could cost the size of the rollout
    /// rather than the size of its records.
    ///
    /// The moment comes back as the text Codex wrote rather than a `Date`,
    /// because judging it is the one thing a seed does tens of thousands of
    /// times and the formatter is far too expensive for that — see
    /// `moment(of:today:)`. `payload.usage.total_tokens` is the per-response
    /// increment. Deliberately not `event_msg`/`token_count`, whose
    /// `info.total_token_usage.total_tokens` is the session's lifetime figure —
    /// a different question, answered in a number large enough to swamp every
    /// other row on the card.
    private static func record(from line: Data) -> (stamp: String, tokens: Int)? {
        guard line.count <= longestRecord, line.range(of: marker) != nil else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "token_usage_record",
              let stamp = object["timestamp"] as? String,
              let payload = object["payload"] as? [String: Any],
              let usage = payload["usage"] as? [String: Any],
              let total = usage["total_tokens"] as? NSNumber
        else { return nil }
        return (stamp, total.intValue)
    }

    /// Where a record sits relative to the day its file was read for.
    private enum Moment {
        case today
        /// Readable, and before the day began.
        case older
        /// A shape this cannot read, so no answer at all. The two callers need
        /// that third answer: the walk may only stop on a record it *knows* is
        /// older, and the fold may only add one it knows is today's.
        case unknown
    }

    /// Where a record's own timestamp sits relative to the day's beginning.
    ///
    /// **Decided on the text, not through a date formatter**, and that is what
    /// makes seeding a large rollout affordable: `ISO8601DateFormatter` measured
    /// about 38µs a call here — 760 ms for the twenty thousand records in a
    /// 75 MB fixture — and a seed asks the question once per record. Codex
    /// writes UTC ISO-8601, zero-padded to the second, with or without
    /// milliseconds, and every stamp of that shape orders correctly as text
    /// against a boundary formatted the same way. The mixed case holds too: a
    /// stamp without milliseconds sorts *after* its second's `.000`, and so
    /// compares as the boundary instant itself does, which is today's.
    ///
    /// A stamp that is not that shape goes to the formatters, which are the
    /// only thing that could read it correctly.
    private static func moment(of stamp: String, today: Boundary) -> Moment {
        if hasFixedShape(stamp) { return stamp >= today.stamp ? .today : .older }
        guard let date = isoWithMillis.date(from: stamp) ?? isoPlain.date(from: stamp) else {
            return .unknown
        }
        return date >= today.start ? .today : .older
    }

    /// Whether a timestamp is `1970-01-01T00:00:00Z` or the same with `.000`.
    /// The two lengths and the five marks between the fields are enough to tell
    /// Codex's own shape from a string that must not be compared as text.
    private static func hasFixedShape(_ stamp: String) -> Bool {
        guard stamp.count == 20 || stamp.count == 24, stamp.hasSuffix("Z") else { return false }
        func mark(_ offset: Int, _ expected: Character) -> Bool {
            stamp.dropFirst(offset).first == expected
        }
        return mark(4, "-") && mark(7, "-") && mark(10, "T")
            && mark(13, ":") && mark(16, ":")
    }

    // MARK: Files

    /// `(size, inode)` of the rollout, or nil when it is not there or cannot be
    /// read. The inode is what tells a rollout replaced by another from one
    /// that merely grew; without it the second file's bytes would be read as a
    /// continuation of the first's.
    private static func identity(of url: URL) -> (size: UInt64, inode: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return (size.uint64Value, (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    /// How much of the bytes behind a cursor are hashed to prove they are still
    /// the same bytes.
    private static let continuityBytes: UInt64 = 4096

    /// A hash of the bytes a cursor has already consumed, ending at `end`.
    ///
    /// **The inode is not an identity on a copy-on-write filesystem.** APFS
    /// hands a deleted file's number to the next one that asks for one, so a
    /// rollout deleted and replaced at the same path can arrive with the same
    /// inode and a length past the old cursor — and `identity(of:)` above, which
    /// exists precisely to catch a replaced rollout, would wave it through.
    /// Folded in from there, the replacement's bytes are read as a continuation
    /// of a file that is gone, and the difference lands in today's total as
    /// tokens nobody spent. An append-only log makes that the one failure mode
    /// that cannot be noticed afterwards: nothing about the total looks wrong.
    ///
    /// So the last few kilobytes before the offset are hashed, and the cursor
    /// resumes only if they hash the same. It is bounded — four kilobytes
    /// against a scan that already reads the tail — and it proves the ground the
    /// cursor is standing on is still the ground it measured.
    ///
    /// FNV-1a: this guards an accident, not an attack, and the whole point is to
    /// cost less than the read it is deciding about. A false match wants two
    /// different four-kilobyte tails to collide.
    ///
    /// Nil when the bytes cannot be read — the caller treats that as "not the
    /// same file" and seeds again, which is slower and never wrong.
    private static func fingerprint(of url: URL, endingAt end: UInt64) -> UInt64? {
        guard end > 0 else { return 0 }
        let start = end > continuityBytes ? end - continuityBytes : 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Short is fine and still contiguous from `start`: a file that ended
        // early hashes the bytes it has, and a later read of the same range
        // hashes the same ones unless the file changed, which is the question.
        guard let bytes = read(handle, from: start, count: end - start) else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Up to `count` bytes from `start`, or what is there if the file ends
    /// first. A short window is still contiguous from `start`, so the caller's
    /// offsets stay correct; `read(upToCount:)` may legally return less than it
    /// was asked for, which is why this loops.
    private static func read(_ handle: FileHandle, from start: UInt64, count: UInt64) -> Data? {
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        var window = Data()
        window.reserveCapacity(Int(count))
        while window.count < Int(count) {
            guard let chunk = try? handle.read(upToCount: Int(count) - window.count) else { return nil }
            if chunk.isEmpty { break }
            window.append(chunk)
        }
        return window
    }
}
