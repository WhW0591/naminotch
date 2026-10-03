import AppKit
import Combine
import CoreServices
import Darwin
import Foundation

/// Follows running DeepSeek Harness sessions.
///
/// Harness publishes more than any other agent here, and in a form that needs no
/// guessing. Each session directory carries a `session.lock` that the running
/// session holds for exactly its lifetime, and the Host's own projection cache
/// (`storages/session_projcache/sessions/<name>.json`) carries the live turn
/// state. So liveness is a lock rather than a timestamp, and state is one small
/// JSON read — no transcript decompression, no process-tree walking, and none of
/// the recency heuristics the Grok and Kimi monitors have to fall back on.
@MainActor
final class DSHSessionMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let home: URL
    private let interval: TimeInterval
    private var timer: Timer?
    /// How many liveness ticks between two full re-listings of the tree.
    ///
    /// Structure is watched, so this is only a net under a missed event; the
    /// point of the number is that the common tick never lists the tree.
    private static let ticksBetweenDiscoveries = 15

    /// The session directories seen at the last listing.
    ///
    /// The liveness tick walks this rather than the tree. The tree only ever
    /// grows — a finished session keeps its directory for ever — so
    /// re-enumerating it every two seconds was work proportional to every
    /// session ever run.
    private var candidates: [(name: String, directory: URL)] = []
    /// FSEvents for structural changes: a session directory appearing or
    /// disappearing. Process death releases the lock without touching the disk,
    /// which is what the timer is still for.
    private var stream: FSEventStreamRef?
    private var pendingDiscovery: DispatchWorkItem?
    private var tickCount = 0

    init(home: URL = DSHCredentials.homeURL, interval: TimeInterval = 2) {
        self.home = home
        self.interval = interval
    }

    func start() {
        // Not idempotent by construction: a second stream and a second timer
        // would stack on the first pair.
        stop()
        rediscover()
        rescan()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tickCount += 1
                self.rescan(discover: self.tickCount % Self.ticksBetweenDiscoveries == 0)
            }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingDiscovery?.cancel()
        pendingDiscovery = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    /// Re-lists the session directories, and makes sure the watcher exists.
    ///
    /// Only structure needs this, so it runs on an FSEvent or every
    /// `ticksBetweenDiscoveries` ticks rather than on every tick.
    private func rediscover() {
        candidates = DSHSessionActivity.sessionDirectories(home: home)
        startWatching()
    }

    private func rescan(discover: Bool = false) {
        if discover { rediscover() }
        let found = DSHSessionActivity.read(home: home, processID: Self.harnessPID(),
                                            acknowledged: acknowledged,
                                            directories: candidates)
        // Drop directories whose lock has gone, so the net grows only with the
        // sessions actually alive. A session cannot be resumed in place: its
        // lock is taken for the life of one run.
        candidates = candidates.filter {
            DSHSessionActivity.isHeld($0.directory.appendingPathComponent("session.lock"))
        }
        guard found != sessions else { return }
        sessions = found

        // A session is marked read the first time it is seen, whatever it is
        // doing. Without that, everything that finished before NamiNotch
        // launched would arrive unread and the card would open onto a backlog
        // of work nobody was waiting on. A session first seen *busy* is marked
        // at its busy time, so the turn it is in the middle of still counts as
        // one to come back for.
        for session in found where acknowledged[session.id] == nil {
            acknowledged[session.id] = session.since
        }
        // Sessions whose process has gone take their marks with them, or the
        // dictionary grows for the life of the app.
        let live = Set(found.map(\.id))
        acknowledged = acknowledged.filter { live.contains($0.key) }
    }

    /// Watches the sessions directory for the one thing the timer cannot
    /// answer quickly: a session directory that has just appeared.
    private func startWatching() {
        guard stream == nil else { return }
        let root = home.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<DSHSessionMonitor>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in monitor.structureChanged() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context,
                                               [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.2,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// A directory appeared or vanished. Coalesced, because one session start
    /// can produce several events and re-listing is a full walk.
    private func structureChanged() {
        pendingDiscovery?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingDiscovery = nil
                self?.rescan(discover: true)
            }
        }
        pendingDiscovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// The card was open and has closed: everything it was showing has been
    /// read.
    ///
    /// Called when the tooltip goes away rather than when it appears, because
    /// the visit *is* the acknowledgement — moving the pointer off is what says
    /// the look is over, and until then the card keeps showing the same list.
    /// Whatever settles next gets a newer timestamp and comes back on its own;
    /// carrying on a conversation does the same, by way of `busy`.
    func markSeen() {
        for session in sessions { acknowledged[session.id] = session.since }
        rescan()
    }

    /// Per session, the settle time that has been read. A session whose
    /// projection has moved on since — because it settled, or settled again
    /// after another turn — is one to show.
    ///
    /// In memory only, and seeded on first sight, so quitting the app drops the
    /// unread marks rather than persisting a backlog across launches.
    private var acknowledged: [String: Date] = [:]

    /// The application the sessions are running inside.
    ///
    /// Harness publishes no pid per session — the lock is all it leaves behind —
    /// so a session cannot name its own process the way Kimi's or Claude's can.
    /// The app is the useful half regardless: `SessionFocus` raises an
    /// application and never a session, and every Harness session runs inside
    /// this one. Nil when Harness is driven headless, which costs the peek click
    /// and nothing else.
    private static func harnessPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: DSHSessionActivity.bundleID)
            .first?.processIdentifier
    }
}

/// What Harness is doing, read off the Host's own state.
enum DSHSessionActivity {
    /// The desktop app that hosts a session, as the shipped build declares it.
    static let bundleID = "com.deepseek.dsh"

    /// One outstanding question.
    ///
    /// A distinct type rather than a bare `String?` because "a question is
    /// outstanding and named nothing we read" and "nothing is being asked" are
    /// different states, and a single optional collapses them into one — which
    /// would draw a session that is blocked on you as merely idle.
    struct Question: Equatable {
        /// What it asks, when the seam put that in a field we read.
        let summary: String?
    }

    /// One live session, folded down to what the notch draws.
    struct Reading: Equatable {
        var title: String?
        var cwd: String?
        var question: Question?
        var isBusy: Bool
        var modified: Date
    }

    // MARK: - Discovery

    /// Every running session, newest first.
    ///
    /// Only sessions whose lock is still held: a finished session keeps its
    /// directory and its transcript forever, and the notch is a view of what is
    /// happening now, not of what happened.
    static func read(home: URL = DSHCredentials.homeURL,
                     processID: pid_t? = nil,
                     now: Date = Date(),
                     acknowledged: [String: Date] = [:],
                     directories: [(String, URL)]? = nil) -> [AgentSession] {
        (directories ?? sessionDirectories(home: home)).compactMap { name, directory in
            guard isHeld(directory.appendingPathComponent("session.lock")) else { return nil }
            return session(name: name,
                           reading: reading(home: home, session: name),
                           processID: processID,
                           acknowledgedAt: acknowledged[sessionID(name)],
                           now: now)
        }
        .sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// The id a session is published under. One place, because the monitor's
    /// acknowledgement marks are keyed by it.
    static func sessionID(_ name: String) -> String { "dsh.\(name)" }

    /// `sessions/<workspace>/<session>`, as `(session name, directory)`.
    ///
    /// The workspace level is a sanitised working directory and carries nothing
    /// this needs — the session's own `identity.cwd` is the readable form — so
    /// only the leaf name is kept. The leaf name is also the projection cache's
    /// file stem, which is what pairs the two halves.
    static func sessionDirectories(home: URL) -> [(String, URL)] {
        let root = home.appendingPathComponent("sessions")
        let manager = FileManager.default
        guard let workspaces = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var found: [(String, URL)] = []
        for workspace in workspaces {
            guard let sessions = try? manager.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for session in sessions where isDirectory(session) {
                found.append((session.lastPathComponent, session))
            }
        }
        return found.sorted { $0.0 < $1.0 }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // MARK: - Liveness

    /// Whether the session's own lock is still held.
    ///
    /// Harness takes an exclusive `flock` on `session.lock` for the life of the
    /// session and the kernel drops it when the process exits, so "is this
    /// session running" is answered by the kernel rather than by a timestamp a
    /// long think would age out. Taking the lock is the measurement; it is
    /// released again immediately, so this never blocks the owner.
    static func isHeld(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    // MARK: - State

    /// Where the Host caches one session's folded projection state.
    static func projectionURL(home: URL, session: String) -> URL {
        home.appendingPathComponent("storages/session_projcache/sessions/\(session).json")
    }

    static func reading(home: URL, session: String) -> Reading? {
        let url = projectionURL(home: home, session: session)
        guard let data = try? Data(contentsOf: url),
              let modified = (try? FileManager.default
                  .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        return reading(fromJSON: data, modified: modified)
    }

    /// The projection cache's own record, or nil when it is not written yet.
    ///
    /// A session that has just started has a lock and no cache; that is a
    /// running session with nothing known about it yet, not an absent one.
    static func reading(fromJSON data: Data, modified: Date) -> Reading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any]
        else { return nil }
        let identity = record["identity"] as? [String: Any] ?? [:]
        let rows = record["rows"] as? [String: Any] ?? [:]
        return Reading(
            title: text(rows["title"]),
            cwd: (identity["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            question: question(in: rows["userQuestions"]),
            isBusy: isBusy(stats: rows["sessionStats"]),
            modified: modified
        )
    }

    /// A row's value. Every projection row is `{ver, seq, val}`.
    private static func value(_ row: Any?) -> Any? { (row as? [String: Any])?["val"] }

    private static func text(_ row: Any?) -> String? {
        guard let raw = value(row) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the agent is mid-step.
    ///
    /// `pendingCalls` holds tool dispatch times by call id and is non-empty
    /// exactly while tools are out; `openStep` is the open step's boundary
    /// facts, "closed by its `assistant/message`". Either one alone means the
    /// turn has not finished. Both are the Host's own fold state, so neither
    /// needs the transcript to be read.
    static func isBusy(stats row: Any?) -> Bool {
        guard let stats = value(row) as? [String: Any] else { return false }
        if let pending = stats["pendingCalls"] as? [String: Any], !pending.isEmpty { return true }
        if let open = stats["openStep"], !(open is NSNull) { return true }
        return false
    }

    /// The outstanding question, when the session is waiting on you.
    ///
    /// `userQuestions` is the seam behind the model-facing `ask_user_question`
    /// tool; `questions.active` is non-empty while a question is outstanding and
    /// moves to `settled` once answered.
    static func question(in row: Any?) -> Question? {
        guard let payload = value(row) as? [String: Any],
              let groups = payload["questions"] as? [String: Any],
              let active = groups["active"] as? [Any],
              !active.isEmpty
        else { return nil }
        return Question(summary: summary(ofQuestion: active[0]))
    }

    /// What one active entry is asking, in whichever field the seam put it.
    ///
    /// The tool asks a *set* of questions, so an entry is sometimes the header
    /// for the set and sometimes one question inside it — hence the one level of
    /// unwrapping, and the several key spellings. Nothing is invented: an entry
    /// that names nothing leaves the tooltip saying only that Harness wants an
    /// answer.
    private static func summary(ofQuestion entry: Any) -> String? {
        if let raw = entry as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let object = entry as? [String: Any] else { return nil }
        if let nested = object["questions"] as? [Any], let first = nested.first,
           let text = summary(ofQuestion: first) {
            return text
        }
        for key in ["question", "prompt", "header", "title", "text", "label"] {
            if let raw = object[key] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    // MARK: - Display model

    private static func session(name: String, reading: Reading?, processID: pid_t?,
                                acknowledgedAt: Date?, now: Date) -> AgentSession {
        let state: AgentSession.State
        var waitingFor: String?
        if let question = reading?.question {
            // A question holds until it is answered, however long that takes —
            // the same rule Kimi's approvals get, and for the same reason: the
            // session is not stalled, it is waiting on a person.
            state = .waiting
            waitingFor = question.summary
        } else if reading?.isBusy == true {
            state = .busy
        } else if let settled = reading?.modified, let acknowledgedAt, settled > acknowledgedAt {
            // Finished, and not looked at since.
            //
            // There is deliberately no time limit here. A completion waits to
            // be read rather than fading on a timer: the card is looked at
            // *because* something just finished, so a window would have to
            // guess how quickly somebody notices, and would drop the very case
            // it exists for whenever they were slower than the guess. It stays
            // `success` — green, and ranked just under working — until the card
            // closes over it. See `markSeen()`.
            //
            // `reading?.modified` and not `since`: a session that has a lock
            // and no projection written yet is *starting*, and its `since`
            // falls back to `now`, which would make it look settled on every
            // scan.
            state = .success
        } else {
            state = .idle
        }

        // The session's own title once it has one — the model's one-line summary
        // of the work, which is what somebody scanning the tooltip is after —
        // and the folder it was started in until then.
        let folder = reading?.cwd.flatMap { path -> String? in
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? nil : name
        }

        return AgentSession(
            id: sessionID(name),
            name: reading?.title ?? folder ?? L10n.t("Harness session"),
            detail: reading?.cwd ?? L10n.t("DeepSeek Harness"),
            state: state,
            waitingFor: waitingFor,
            since: reading?.modified ?? now,
            processID: processID
        )
    }
}
