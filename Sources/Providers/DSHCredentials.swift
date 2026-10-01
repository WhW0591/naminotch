import Foundation

/// The account grant DeepSeek Harness keeps in `~/.dsh/.credentials.yaml`.
///
/// Harness signs in through a browser PKCE flow
/// (`@deepseek-ai/dsh-deepseek-account-platform`) and files the resulting grant
/// under `deepseek-account-platform/default`. The file is YAML, and Swift ships
/// no YAML reader, so this reads the one shape it needs — nested block mappings
/// of plain scalars — rather than adding a parser dependency for four keys. A
/// file it cannot read is `needsAuth`, never a crash.
///
/// Read-only, like every borrowed credential here. The grant carries no expiry
/// and no refresh flow of its own — the owning package documents it that way —
/// so there is nothing to renew, and writing the file would only race the app
/// that owns it.
struct DSHCredentials {
    /// The credential record Harness files for the Platform account.
    ///
    /// Named rather than positional: the same store holds the browser session
    /// and a device identity, and reading whichever record came first would
    /// hand the wrong secret to the request.
    static let recordKey = "deepseek-account-platform/default"

    /// `DSH_HOME` moves the whole data root, so the path honours it — the same
    /// bargain `KIMI_CODE_HOME` gets in `KimiCredentials`.
    static var homeURL: URL {
        let override = ProcessInfo.processInfo.environment["DSH_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
        return override.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh")
    }

    static var credentialsURL: URL { homeURL.appendingPathComponent(".credentials.yaml") }

    let token: String
    /// The origin that issued the grant.
    ///
    /// A grant is only good on its issuer — Harness deletes a mismatched one at
    /// startup rather than sending it — so this, and not a constant, is what
    /// decides where the request may go. Pinning the origin in code instead
    /// would break every private deployment the same package supports.
    let issuer: URL

    static func account(from url: URL = credentialsURL) -> ProviderAccount? {
        guard let credentials = try? load(from: url) else { return nil }
        return ProviderAccount(
            label: nil,   // the grant carries no address
            plan: nil,
            source: "DeepSeek Harness",
            manageURL: credentials.issuer.appendingPathComponent("usage")
        )
    }

    static func load(from url: URL = credentialsURL) throws -> DSHCredentials {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw UsageProviderError.needsAuth
        }
        guard let payload = DSHScalarYAML.payload(ofRecord: recordKey, in: text),
              let token = payload["token"], !token.isEmpty,
              let issuerText = payload["issuer"],
              let issuer = URL(string: issuerText),
              // The owning provider accepts HTTPS, or loopback HTTP only when a
              // development patch opts in. Sending a grant to a plaintext
              // origin because a file said so is the one case worth refusing
              // outright.
              issuer.scheme == "https", issuer.host != nil
        else { throw UsageProviderError.needsAuth }

        return DSHCredentials(token: token, issuer: issuer)
    }
}

/// Just enough YAML for `~/.dsh/.credentials.yaml`.
///
/// Deliberately not a YAML implementation: no anchors, no flow collections, no
/// block scalars, no tags, no multi-line values. It reads one named record's
/// `payload` mapping out of a file whose shape the owning package controls, and
/// returns nil for anything it does not recognise — which surfaces as "no
/// credential" rather than as a wrong one.
enum DSHScalarYAML {
    /// The `key: value` scalars under `records.<name>.payload`.
    ///
    /// Returns nil when the record is absent or carries no scalars, so an empty
    /// or truncated file is a failure rather than an empty credential.
    static func payload(ofRecord name: String, in text: String) -> [String: String]? {
        var scalars: [String: String] = [:]
        var recordIndent: Int?
        var inPayload = false
        var payloadIndent = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let body = raw.drop { $0 == " " || $0 == "\t" }
            let indent = raw.count - body.count
            guard !body.isEmpty, !body.hasPrefix("#") else { continue }

            guard let record = recordIndent else {
                if body == "\(name):" { recordIndent = indent }
                continue
            }
            // A line back at the record's own indent ends it: either the next
            // record, or the end of `records`. Everything after is somebody
            // else's credential.
            if indent <= record { break }

            if body == "payload:" {
                inPayload = true
                payloadIndent = indent
                continue
            }
            guard inPayload else { continue }
            // Anything at or above the `payload:` key closes the mapping.
            if indent <= payloadIndent {
                inPayload = false
                continue
            }
            if let (key, value) = scalar(body) { scalars[key] = value }
        }

        return scalars.isEmpty ? nil : scalars
    }

    /// One `key: value` pair of plain scalars, or nil for a nested mapping
    /// header, a list item, or anything else this does not claim to read.
    static func scalar(_ body: Substring) -> (String, String)? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let key = body[body.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        var value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        // A nested mapping's own header (`payload:`) ends in a colon and names
        // no value; a list item starts with a dash. Neither is a scalar.
        guard !value.hasSuffix(":"), !key.hasPrefix("-") else { return nil }
        if value.count >= 2,
           let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return nil }
        return (key, value)
    }
}
