import os

/// An agent app has no window to print into, so anything worth diagnosing has
/// to go somewhere you can read it:
///
///     log stream --predicate 'subsystem == "com.whw0591.naminotch"' --level debug
enum Log {
    static let usage = Logger(subsystem: AppIdentity.bundleID, category: "usage")
    static let sessions = Logger(subsystem: AppIdentity.bundleID, category: "sessions")
}
