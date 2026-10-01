import XCTest
@testable import Codenotch

/// Harness answers both halves of the notch's question from its own state: the
/// session lock says whether it is running, and the Host's projection cache
/// says what it is doing. These pin that reading, including the two states that
/// are easy to collapse into each other.
final class DSHSessionActivityTests: XCTestCase {
    private var home: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-home-\(UUID().uuidString)")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: home)
    }

    // MARK: - Fixtures

    /// A session directory with its lock, and the projection cache when the
    /// Host has written one.
    @discardableResult
    private func session(_ name: String, projection: String? = nil) throws -> URL {
        let directory = home.appendingPathComponent("sessions/--workspace--/\(name)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        manager.createFile(atPath: directory.appendingPathComponent("session.lock").path,
                           contents: nil)
        if let projection {
            let cache = home.appendingPathComponent("storages/session_projcache/sessions")
            try manager.createDirectory(at: cache, withIntermediateDirectories: true)
            try projection.data(using: .utf8)!
                .write(to: cache.appendingPathComponent("\(name).json"))
        }
        return directory
    }

    /// Holds a session's lock the way a running session does.
    ///
    /// A separate `open` is a separate open-file-description, so `flock` treats
    /// it as a different holder even inside this process — which is exactly what
    /// makes the measurement testable.
    private func hold(_ directory: URL) -> Int32 {
        let descriptor = open(directory.appendingPathComponent("session.lock").path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        return descriptor
    }

    private func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// One projection record in the shape the Host writes.
    private func projection(title: String? = nil,
                            cwd: String? = nil,
                            pendingCalls: [String: Any] = [:],
                            openStep: Any? = nil,
                            active: [Any] = [],
                            settled: [Any] = []) -> String {
        func row(_ value: Any) -> [String: Any] { ["ver": 1, "seq": 1, "val": value] }
        var rows: [String: Any] = [
            "sessionStats": row(["pendingCalls": pendingCalls,
                                 "openStep": openStep ?? NSNull()]),
            "userQuestions": row(["questions": ["active": active, "settled": settled]]),
        ]
        if let title { rows["title"] = row(title) }
        let root: [String: Any] = [
            "version": 7,
            "record": [
                "identity": ["formatVersion": 4, "cwd": cwd ?? "/Users/someone/project"],
                "rows": rows,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: root)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Liveness

    func testOnlyASessionHoldingItsLockIsRunning() throws {
        let running = try session("session-a")
        try session("session-b")
        let descriptor = hold(running)
        defer { release(descriptor) }

        let live = DSHSessionActivity.read(home: home)
        XCTAssertEqual(live.map(\.id), ["dsh.session-a"])
    }

    func testAFinishedSessionIsNotListed() throws {
        // A finished session keeps its directory and transcript forever, so
        // discovery has to be the lock rather than the folder.
        let finished = try session("session-a", projection: projection(title: "Old work"))
        let descriptor = hold(finished)
        release(descriptor)

        XCTAssertTrue(DSHSessionActivity.read(home: home).isEmpty)
    }

    func testARunningSessionWithNoProjectionStillAppears() throws {
        // Just started: the lock exists and the Host has not folded a cache yet.
        let running = try session("session-a")
        let descriptor = hold(running)
        defer { release(descriptor) }

        let live = DSHSessionActivity.read(home: home)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.state, .idle)
    }

    // MARK: - State

    func testAPendingToolCallIsBusy() throws {
        let running = try session("session-a", projection: projection(
            pendingCalls: ["call_00_abc": 1_790_857_304_245]))
        let descriptor = hold(running)
        defer { release(descriptor) }

        XCTAssertEqual(DSHSessionActivity.read(home: home).first?.state, .busy)
    }

    func testAnOpenStepIsBusy() throws {
        // No tool out, but the step has not been closed by its assistant
        // message — the agent is still generating.
        let running = try session("session-a", projection: projection(
            openStep: ["kind": "start", "seq": 300]))
        let descriptor = hold(running)
        defer { release(descriptor) }

        XCTAssertEqual(DSHSessionActivity.read(home: home).first?.state, .busy)
    }

    func testAClosedStepWithNoCallsIsIdle() throws {
        let running = try session("session-a", projection: projection(
            pendingCalls: [:], openStep: NSNull()))
        let descriptor = hold(running)
        defer { release(descriptor) }

        XCTAssertEqual(DSHSessionActivity.read(home: home).first?.state, .idle)
    }

    /// The question, not the header.
    ///
    /// `ask_user_question` gives each question a short `header` ("Which
    /// database?") and the question itself ("Postgres or SQLite?"). The tooltip
    /// is answering "what does it want from me", and the question is the half
    /// that says so; the header is a category, and reading it back would make
    /// every cell look alike.
    func testAnActiveQuestionIsWaiting() throws {
        let running = try session("session-a", projection: projection(
            active: [["header": "Which database?", "question": "Postgres or SQLite?"]]))
        let descriptor = hold(running)
        defer { release(descriptor) }

        let live = try XCTUnwrap(DSHSessionActivity.read(home: home).first)
        XCTAssertEqual(live.state, .waiting)
        XCTAssertEqual(live.waitingFor, "Postgres or SQLite?")
    }

    /// A question that names itself in no field we read is still a session
    /// blocked on a person — the state must not collapse to idle just because
    /// the label is missing.
    func testAQuestionThatNamesNothingStillWaits() throws {
        let running = try session("session-a", projection: projection(
            active: [["id": "q-1", "kind": "tool"]]))
        let descriptor = hold(running)
        defer { release(descriptor) }

        let live = try XCTUnwrap(DSHSessionActivity.read(home: home).first)
        XCTAssertEqual(live.state, .waiting)
        XCTAssertNil(live.waitingFor)
    }

    func testASettledQuestionIsNoLongerWaiting() throws {
        let running = try session("session-a", projection: projection(
            active: [], settled: [["header": "Which database?"]]))
        let descriptor = hold(running)
        defer { release(descriptor) }

        XCTAssertEqual(DSHSessionActivity.read(home: home).first?.state, .idle)
    }

    /// Waiting outranks busy: a session with a tool still out that has stopped
    /// to ask something is waiting on you, not working.
    func testWaitingOutranksBusy() throws {
        let running = try session("session-a", projection: projection(
            pendingCalls: ["call_00_abc": 1],
            active: [["question": "Continue?"]]))
        let descriptor = hold(running)
        defer { release(descriptor) }

        let live = try XCTUnwrap(DSHSessionActivity.read(home: home).first)
        XCTAssertEqual(live.state, .waiting)
        XCTAssertEqual(live.waitingFor, "Continue?")
    }

    // MARK: - Display model

    func testTheTitleNamesTheSessionAndTheFolderIsTheDetail() throws {
        let running = try session("session-a", projection: projection(
            title: "检查已安装的 skill", cwd: "/Users/someone/Documents/deepseek-harness/untitled folder"))
        let descriptor = hold(running)
        defer { release(descriptor) }

        let live = try XCTUnwrap(DSHSessionActivity.read(home: home).first)
        XCTAssertEqual(live.name, "检查已安装的 skill")
        XCTAssertEqual(live.detail, "/Users/someone/Documents/deepseek-harness/untitled folder")
        XCTAssertEqual(live.id, "dsh.session-a")
    }

    func testTheFolderNamesASessionWithNoTitleYet() throws {
        let running = try session("session-a", projection: projection(
            cwd: "/Users/someone/Documents/deepseek-harness/untitled folder"))
        let descriptor = hold(running)
        defer { release(descriptor) }

        XCTAssertEqual(DSHSessionActivity.read(home: home).first?.name, "untitled folder")
    }

    func testTheOwningAppIsTheProcessARaiseWouldUse() throws {
        let running = try session("session-a")
        let descriptor = hold(running)
        defer { release(descriptor) }

        let live = DSHSessionActivity.read(home: home, processID: 4242)
        XCTAssertEqual(live.first?.processID, 4242)
    }

    func testANewerSessionComesFirst() throws {
        let older = try session("session-a", projection: projection(title: "First"))
        let newer = try session("session-b", projection: projection(title: "Second"))
        let a = hold(older), b = hold(newer)
        defer { release(a); release(b) }

        // Written in this order, so the caches' modification dates order them.
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                  ofItemAtPath: DSHSessionActivity
                                      .projectionURL(home: home, session: "session-a").path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)],
                                  ofItemAtPath: DSHSessionActivity
                                      .projectionURL(home: home, session: "session-b").path)

        XCTAssertEqual(DSHSessionActivity.read(home: home).map(\.name), ["Second", "First"])
    }
}
