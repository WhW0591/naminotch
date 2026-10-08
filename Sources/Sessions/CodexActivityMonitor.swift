import AppKit
import Combine
import Darwin
import Foundation

/// The small, stable part of a Codex rollout that is useful for activity.
///
/// `item_completed` is intentionally ignored: commands and other child items
/// emit it too. A turn is complete only after Codex writes `task_complete`.
struct CodexRolloutActivity {
    enum State: Equatable {
        case busy
        case success
    }

    /// One window into the end of the rollout. Rollouts run to hundreds of
    /// megabytes, so the file is walked backwards in slices rather than read
    /// whole — the same `tail` trick the Claude and Antigravity readers use.
    private static let windowBytes: UInt64 = 256 * 1024
    /// How far back a lifecycle event may be before the search gives up. A
    /// mid-turn rollout keeps its `task_started` arbitrarily far behind the
    /// writes streaming in — walking to it would read the whole file on every
    /// tick. A fresh file with no lifecycle event in its last megabyte is a
    /// turn in progress in every realistic case, and the caller maps a miss
    /// to `.busy` — the same answer the full scan would give.
    private static let maxWindows = 4

    static func state(from url: URL) -> State? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var windowEnd = try? handle.seekToEnd() else { return nil }

        // The newest lifecycle event wins, so windows are scanned newest
        // first and the first match is the answer. A window's first line is
        // cut in half by the read; the fragment is carried into the earlier
        // window, where the rest of it lives, rather than parsed half a line.
        var carried = Data()
        var windows = 0
        while windowEnd > 0, windows < maxWindows {
            windows += 1
            let windowStart = windowEnd > windowBytes ? windowEnd - windowBytes : 0
            guard (try? handle.seek(toOffset: windowStart)) != nil else { return nil }

            // `read(upToCount:)` may legally deliver fewer bytes than asked
            // for, and a window that came back short would silently lose the
            // lines its tail never reached — and join `carried` to a stretch
            // of file it does not follow. Read until the window is filled.
            // An error still fails the scan; hitting EOF early means the
            // file shrank between the seek and the read (rotation), and what
            // arrived is still contiguous with `windowStart`.
            var window = Data()
            window.reserveCapacity(Int(windowEnd - windowStart))
            while window.count < Int(windowEnd - windowStart) {
                guard let chunk = try? handle.read(
                    upToCount: Int(windowEnd - windowStart) - window.count
                ) else { return nil }
                if chunk.isEmpty { break }
                window.append(chunk)
            }
            // `carried` continues the line this window's start cut — but only
            // when the read reached `windowEnd`, where the fragment begins. A
            // short window ends somewhere else entirely, and joining the two
            // would fabricate a line out of unrelated bytes.
            if window.count == Int(windowEnd - windowStart) {
                window.append(carried)
            }

            // A window that opens on a newline was not cut mid-line: its first
            // line is whole, and the earlier window's last line is the one
            // missing its newline. Carrying anything back would glue the two.
            let startsOnALineBreak = window.first == UInt8(ascii: "\n")
            var lines = window.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            carried = windowStart > 0 && !startsOnALineBreak && !lines.isEmpty
                ? Data(lines.removeFirst()) : Data()

            for line in lines.reversed() {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      record["type"] as? String == "event_msg",
                      let payload = record["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { continue }

                switch type {
                case "task_started":
                    return .busy
                case "task_complete":
                    return .success
                case "turn_aborted":
                    // An aborted turn is not a successful completion. Returning
                    // nil lets the activity monitor drop it without announcing.
                    return nil
                default:
                    continue
                }
            }
            windowEnd = windowStart
        }
        return nil
    }
}

/// Reports whether Codex is mid-turn.
///
/// Codex does not publish a live status field, but its rollout includes
/// lifecycle events. `task_started` and `task_complete` are used when present;
/// the file's recent modification time remains the activity fallback.
///
/// **That is a heuristic, and it is labelled as one.** It cannot tell a turn
/// that is thinking from one that finished a second ago, so it errs short: the
/// ring stops spinning `staleAfter` seconds after the last write rather than
/// claiming activity it cannot see. A stale rollout is deliberately not
/// converted into `.success` or `.idle`, because inactivity is not evidence
/// that a Codex turn completed — a long-running command can be quiet too.
/// If Codex grows a real status field this should be replaced by it.
@MainActor
final class CodexActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let stateStore: URL
    private let desktopStore: URL
    private let profile: CodexProfile
    private let interval: TimeInterval
    /// How long after the last write a turn is still considered in flight.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        profile: CodexProfile = .default(),
        stateStore: URL? = nil,
        desktopStore: URL? = nil,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 8
    ) {
        self.profile = profile
        self.stateStore = stateStore ?? profile.stateURL
        self.desktopStore = desktopStore ?? profile.desktopStoreURL
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private let storeCache = CodexStoreCache()

    /// Today's token increments per rollout. Held for the monitor's whole life
    /// on purpose: the reader is incremental, and a fresh one per tick would
    /// re-walk every open rollout from its end twice a second.
    private let rolloutUsage = CodexRolloutUsage()

    /// When each row entered the state it is in, by session id. See `settled`.
    private var entered: [String: (state: AgentSession.State, at: Date)] = [:]

    private func rescan() {
        let read = Self.read(stateStore: stateStore, desktopStore: desktopStore,
                             staleAfter: staleAfter, profile: profile, cache: storeCache,
                             usage: rolloutUsage)
        let found = Self.settled(read, entered: &entered)
        guard found != sessions else { return }
        // Only on a change, as the Claude monitor does, and for the same
        // reason: it is the one way to see what the notch thinks is running
        // without hovering over it.
        let summary = found.map { "\($0.name)=\($0.state)" }.joined(separator: " ")
        Log.sessions.debug("\(self.profile.id, privacy: .public): \(summary, privacy: .public)")
        sessions = found
    }

    /// Every Codex conversation working right now, each under its own name.
    ///
    /// This used to be one row at most, called "Codex": the newest rollout or
    /// the newest desktop thread, whichever moved last. Two conversations
    /// running at once drew as one, and nothing on the notch said which
    /// request was being worked on — while the Claude rows beside it named
    /// every session. Codex does name its conversations; the name is in the
    /// same `threads` row the rollout path was already being read from.
    static func read(stateStore: URL, desktopStore: URL,
                     staleAfter: TimeInterval, now: Date = Date(),
                     profile: CodexProfile = .default(),
                     cache: CodexStoreCache = CodexStoreCache(),
                     usage: CodexRolloutUsage = CodexRolloutUsage(),
                     openRollouts: Set<String>? = nil,
                     rolloutOwners: [String: pid_t]? = nil) -> [AgentSession] {
        var found: [AgentSession] = []
        // Every thread id that is part of a conversation drawn below, so the
        // desktop app's copy of the same conversation is not drawn again.
        var drawn: Set<String> = []
        // The rollouts behind each drawn row, in the order they will be read.
        // Kept beside the rows rather than inside them: which files hold a
        // conversation's day is the monitor's business, not the card's.
        var files: [String: [URL]] = [:]

        // "Codex" is two programs that record their work in different places:
        // the CLI and the VS Code extension append to a rollout, and the
        // desktop app writes to its own catalogue.
        let owners: [String: pid_t]
        if let rolloutOwners {
            owners = rolloutOwners
        } else if let openRollouts {
            owners = Dictionary(uniqueKeysWithValues: openRollouts.map { ($0, 0) })
        } else {
            owners = CodexOpenRollouts.owners(
                under: profile.configDirectory.appendingPathComponent("sessions"))
        }
        let openRollouts = Set(owners.keys)
        for conversation in liveConversations(cache.recentThreads(in: stateStore),
                                              staleAfter: staleAfter, now: now, cache: cache,
                                              openRollouts: openRollouts) {
            let root = conversation.root
            // The id the single row always had, so a conversation that is not
            // a sub-agent's keeps it and nothing keyed on it moves.
            let handle = root.rollout?.lastPathComponent ?? root.id
            // The process reading this conversation's rollout is the one to
            // walk up to a terminal when its cell is clicked.
            let pid = conversation.rollouts.compactMap { owners[$0.path] }.first { $0 > 0 }
            guard let session = session(id: "\(profile.id).\(handle)",
                                        name: root.label(fallback: profile.displayName),
                                        modified: conversation.at, state: conversation.state,
                                        staleAfter: staleAfter, now: now,
                                        allowStale: conversation.isOpen,
                                        processID: pid)
            else { continue }
            found.append(session)
            files[session.id] = conversation.rollouts
            drawn.formUnion(conversation.members)
        }

        if let desktop = cache.newestDesktopThread(in: desktopStore),
           desktop.threadID.isEmpty || !drawn.contains(desktop.threadID),
           let session = session(id: "\(profile.id).desktop", name: desktop.title,
                                 modified: desktop.updatedAt, state: .busy,
                                 staleAfter: staleAfter, now: now,
                                 appBundleID: "com.openai.codex") {
            found.append(session)
        }

        // Newest first, with the id breaking ties so two ticks that read the
        // same thing cannot draw the rows in a different order.
        return withTokenShares(found, files: files, usage: usage, now: now)
            .sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// The rows with every Codex conversation's second line rewritten to its
    /// share of today's tokens.
    ///
    /// **The denominator is the rows in this reading**, not the account-wide
    /// "Today" the card prints further up. That figure comes from the usage
    /// endpoint and counts work no rollout on this machine recorded — another
    /// machine, a rotated file — so dividing by it would make every share a
    /// fraction of something the reader cannot see. What the shares are for is
    /// ranking these rows against each other, and over these rows they add up
    /// to a hundred.
    ///
    /// **Codex only.** The other monitors write their own `detail` and are not
    /// asked for a share; a row with no rollouts of its own — the desktop app's
    /// — is returned exactly as it was built.
    ///
    /// A row whose rollouts cannot be read keeps the line it already had. That
    /// is what omitting the share means here: calling an unreadable file zero
    /// would rank it last with the same confidence as a reading, which is the
    /// one answer worse than saying nothing.
    static func withTokenShares(_ sessions: [AgentSession], files: [String: [URL]],
                                usage: CodexRolloutUsage, now: Date) -> [AgentSession] {
        var spent: [String: (tokens: Int, readable: Bool)] = [:]
        var day = 0
        var asked: Set<String> = []
        for session in sessions {
            guard let owned = files[session.id], !owned.isEmpty else { continue }
            asked.formUnion(owned.map(\.path))
            var tokens = 0
            var readable = false
            for url in owned {
                guard let counted = usage.tokensToday(in: url, now: now) else { continue }
                readable = true
                tokens += counted
            }
            spent[session.id] = (tokens, readable)
            day += tokens
        }
        // Rollouts nothing asks about any more are forgotten, so a long-lived
        // app does not hold a cursor per conversation it has ever drawn.
        usage.forget(keeping: asked)

        return sessions.map { session in
            guard let known = spent[session.id], known.readable,
                  let detail = tokenDetail(tokens: known.tokens, of: day)
            else { return session }
            return AgentSession(id: session.id, name: session.name, detail: detail,
                                state: session.state, waitingFor: session.waitingFor,
                                since: session.since, processID: session.processID,
                                appBundleID: session.appBundleID)
        }
    }

    /// What a Codex row says under its name: this conversation's share of the
    /// day's tokens, and the count behind the share.
    ///
    /// `42% · 128.4M` is the shape. The share is what ranks the rows at a
    /// glance, which is the whole point of the line, and the absolute is beside
    /// it so a share of a quiet day is not read as a quiet session.
    ///
    /// A conversation that has spent nothing today says so as a count rather
    /// than as `0%`: on a card of idle rows that is a line of zeroes saying
    /// nothing, where "No tokens today" is a fact. Nothing reaches here for a
    /// file that could not be read — the caller keeps the row's own line for
    /// that case, since zero would be a claim the reading does not support.
    static func tokenDetail(tokens: Int, of day: Int) -> String? {
        guard tokens > 0 else { return L10n.t("No tokens today") }
        guard day > 0 else { return nil }
        // As a string, so the localized shape stays the `%@ · %@` the catalog
        // already has a translation for rather than a `%lld%%` of its own.
        let share = "\(Int((Double(tokens) / Double(day) * 100).rounded()))%"
        return L10n.t("\(share) · \(UsageFormat.tokens(tokens))")
    }

    /// One working conversation: the thread it started from, when any of it
    /// last moved, what it is doing, and every thread id that is part of it.
    struct Conversation {
        let root: CodexThread
        let at: Date
        let state: AgentSession.State
        let members: Set<String>
        /// Every rollout the conversation owns — the root's and its helpers',
        /// sorted. What a request spends is mostly spent by the helpers it
        /// spawned, so crediting only the root's own file would rank the
        /// conversation that did the most work near the bottom of the card.
        let rollouts: [URL]
        let isOpen: Bool
    }

    /// Every conversation with a rollout written inside the window, each once.
    ///
    /// A sub-agent is folded into the conversation that spawned it rather than
    /// drawn as a row of its own. Codex can run half a dozen for one request,
    /// each with a rollout, and a row per helper would bury the one thing the
    /// person asked for — while the parent, waiting on them, may write nothing
    /// at all for minutes. So the work is credited to the root, under the
    /// root's name, for as long as any of it is moving.
    static func liveConversations(_ threads: [CodexThread],
                                  staleAfter: TimeInterval,
                                  now: Date,
                                  cache: CodexStoreCache = CodexStoreCache(),
                                  openRollouts: Set<String> = []) -> [Conversation] {
        let byID = Dictionary(threads.filter { !$0.id.isEmpty }.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })

        func root(of thread: CodexThread) -> CodexThread {
            var current = thread
            var seen: Set<String> = [thread.key]
            while let parent = current.parentID, let next = byID[parent],
                  seen.insert(next.key).inserted {
                current = next
            }
            return current
        }

        var newest: [String: Date] = [:]
        var roots: [String: CodexThread] = [:]
        var members: [String: Set<String>] = [:]
        var owned: [String: Set<String>] = [:]
        var busyRoots: Set<String> = []
        var openRoots: Set<String> = []
        let rollouts = Set(threads.compactMap { $0.rollout?.path })
        for thread in threads {
            guard let rollout = thread.rollout,
                  let modified = (try? FileManager.default
                      .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date
            else { continue }
            let activity = cache.rolloutState(of: rollout, keeping: rollouts)
            let isRecent = now.timeIntervalSince(modified) <= staleAfter
            let root = root(of: thread)
            // A helper whose conversation cannot be found is not drawn at all.
            // Drawing it as a conversation of its own is the one wrong answer:
            // a row named after a prompt the person never wrote, announcing
            // "Complete" for a review while the real request is still working.
            guard !root.isHelper else { continue }
            // The conversation owns this rollout whether or not the thread is
            // moving now: today's spending is the conversation's, and a helper
            // that finished an hour ago still spent today's tokens on its
            // behalf. Nothing is read for a rollout no row draws from — the
            // reader is asked only about the rows built below.
            owned[root.key, default: []].insert(rollout.path)
            guard isRecent || (openRollouts.contains(rollout.path) && activity == .busy)
            else { continue }
            roots[root.key] = root
            members[root.key, default: []].formUnion([thread.id, root.id].filter { !$0.isEmpty })
            if activity == .busy || thread.key != root.key { busyRoots.insert(root.key) }
            if openRollouts.contains(rollout.path), activity == .busy {
                openRoots.insert(root.key)
            }
            if newest[root.key].map({ $0 < modified }) ?? true { newest[root.key] = modified }
        }

        let live = Set(roots.values.compactMap { $0.rollout?.path })
        return roots.compactMap { key, root in
            guard let at = newest[key] else { return nil }
            return Conversation(root: root, at: at,
                                state: busyRoots.contains(key) ? .busy
                                    : state(of: root, staleAfter: staleAfter, now: now,
                                            cache: cache, live: live),
                                members: members[key] ?? [],
                                // Sorted so two ticks reading the same set ask
                                // for the files in the same order.
                                rollouts: (owned[key] ?? []).sorted()
                                    .map(URL.init(fileURLWithPath:)),
                                isOpen: openRoots.contains(key))
        }
    }

    /// The rows with `since` meaning what `AgentSession` says it means: when
    /// the row entered its current state.
    ///
    /// What `read` can see is a rollout's last write, which moves every
    /// second while a conversation works. As `since` that sorted two busy
    /// conversations by whichever wrote last, so they swapped places every
    /// few seconds, showed an elapsed time of about nothing, and made every
    /// tick look like a change. So the first sighting of a row in a state is
    /// kept until the state changes, and rows no longer present are
    /// forgotten.
    static func settled(_ sessions: [AgentSession],
                        entered: inout [String: (state: AgentSession.State, at: Date)])
    -> [AgentSession] {
        var next: [String: (state: AgentSession.State, at: Date)] = [:]
        let settled = sessions.map { session -> AgentSession in
            let held = entered[session.id]
            let at = held.flatMap { $0.state == session.state ? $0.at : nil } ?? session.since
            next[session.id] = (session.state, at)
            return AgentSession(id: session.id, name: session.name, detail: session.detail,
                                state: session.state, waitingFor: session.waitingFor,
                                since: at, processID: session.processID)
        }
        entered = next
        return settled.sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// The conversation's own answer when its root is writing, and busy when
    /// only its helpers are.
    ///
    /// Never a helper's answer. A sub-agent finishing writes `task_complete`
    /// into *its* rollout while the request it was helping with is still
    /// under way, and reading that as the conversation's state would announce
    /// "Complete" for work that is not.
    ///
    /// A stale rollout is not parsed at all — the parse is the expensive part,
    /// and a file that has stopped moving has nothing current to say.
    static func state(of root: CodexThread, staleAfter: TimeInterval, now: Date,
                      cache: CodexStoreCache, live: Set<String>) -> AgentSession.State {
        guard let rollout = root.rollout,
              let modified = (try? FileManager.default
                  .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) <= staleAfter
        else { return .busy }
        switch cache.rolloutState(of: rollout, keeping: live) {
        case .success: return .success
        case .busy, .none: return .busy
        }
    }

    /// Only work recorded within the window counts. Anything older is a
    /// finished turn, and reporting it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        id: String, name: String, modified: Date,
        state: AgentSession.State = .busy,
        staleAfter: TimeInterval, now: Date,
        allowStale: Bool = false,
        processID: pid_t? = nil,
        appBundleID: String? = nil
    ) -> AgentSession? {
        guard allowStale || now.timeIntervalSince(modified) <= staleAfter else { return nil }

        return AgentSession(
            id: id,
            name: name,
            detail: state == .success ? L10n.t("Complete") : L10n.t("Working"),
            state: state,
            waitingFor: nil,
            since: modified,
            processID: processID,
            appBundleID: appBundleID
        )
    }
}

enum CodexOpenRollouts {
    static func paths(under root: URL, pids suppliedPIDs: [pid_t]? = nil) -> Set<String> {
        Set(owners(under: root, pids: suppliedPIDs).keys)
    }

    /// The same scan, keeping *which* process holds each rollout. A click on a
    /// session's cell turns this into the terminal the agent runs in.
    static func owners(under root: URL, pids suppliedPIDs: [pid_t]? = nil) -> [String: pid_t] {
        let pids: [pid_t]
        if let suppliedPIDs {
            pids = suppliedPIDs
        } else {
            var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard count > 0 else { return [:] }
            var listed = [pid_t](repeating: 0,
                                 count: Int(count) / MemoryLayout<pid_t>.stride + 16)
            count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &listed,
                                  Int32(listed.count * MemoryLayout<pid_t>.stride))
            guard count > 0 else { return [:] }
            pids = listed.prefix(Int(count) / MemoryLayout<pid_t>.stride).filter(isCodex)
        }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var resolvedPrefix = prefix
        if let resolved = realpath(root.path, nil) {
            let path = String(cString: resolved)
            free(resolved)
            resolvedPrefix = path.hasSuffix("/") ? path : path + "/"
        }
        var found: [String: pid_t] = [:]
        for pid in pids where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(),
                                    count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
            let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                    Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
            guard read > 0 else { continue }
            for fd in fds.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride)
                where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO,
                                     &info, infoSize) == infoSize else { continue }
                let path = withUnsafePointer(to: &info.pvip.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                        String(cString: $0)
                    }
                }
                guard path.hasSuffix(".jsonl") else { continue }
                if path.hasPrefix(prefix) {
                    found[path] = pid
                } else if path.hasPrefix(resolvedPrefix) {
                    found[prefix + path.dropFirst(resolvedPrefix.count)] = pid
                }
            }
        }
        return found
    }

    private static func isCodex(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size)
        else { return false }
        return withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0) == "codex"
            }
        }
    }
}
