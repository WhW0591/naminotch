import Foundation
import Network

/// Loopback HTTP transport. Bodies exist only while forwarding a request; no
/// request logging, URL cache, cookies, redirects, or external proxy is used.
///
/// Both halves of every forwarded request are `NWConnection`s. The SwiftNIO
/// pipeline this replaced existed for one job — decoding and re-encoding HTTP —
/// and brought four packages and a compiled event loop with it for a feature
/// that is off by default. What is left is the two decoders below, which only
/// ever see the traffic this relay actually carries: a request with a
/// `Content-Length` body, and a response that is length-delimited, chunked, or
/// ended by the connection closing.
///
/// Every callback is started on `queue`, so the session state below needs no
/// lock and the two sides cannot interleave.
final class OllamaRelayServer: @unchecked Sendable {
    typealias Observer = (UUID, String, Bool) -> Void

    private static let headerEnd = Data([13, 10, 13, 10])
    private static let crlf = Data([13, 10])
    private static let maxHeadBytes = 64 * 1024
    private static let maxBodyBytes = 32 * 1024 * 1024
    private static let hopByHop: Set<String> = ["connection", "keep-alive", "proxy-authenticate",
                                                 "proxy-authorization", "te", "trailer",
                                                 "transfer-encoding", "upgrade"]

    private let queue = DispatchQueue(label: "com.whw0591.naminotch.ollama-relay")
    private let upstream: URL
    private let observe: Observer
    private let onPerformance: (String, LocalModelPerformance) -> Void

    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: RelaySession] = [:]
    private var port = 0
    private var stopped = false

    init(upstream: URL,
         onPerformance: @escaping (String, LocalModelPerformance) -> Void = { _, _ in },
         observe: @escaping Observer) {
        self.upstream = upstream
        self.onPerformance = onPerformance
        self.observe = observe
    }

    func start(port: Int = 11435) async throws -> Int {
        let endpoint = try OllamaEndpoint.parse(upstream.absoluteString)
        guard port == 0 || (endpoint.port ?? 80) != port else { throw OllamaError.invalidEndpoint }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                     port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    let bound = Int(listener.port?.rawValue ?? 0)
                    self?.port = bound
                    continuation.resume(returning: bound)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard !self.stopped else { continuation.resume(); return }
                self.stopped = true
                self.listener?.cancel()
                self.listener = nil
                for session in Array(self.sessions.values) { self.close(session) }
                self.sessions.removeAll()
                continuation.resume()
            }
        }
    }

    // MARK: - Client side

    private func accept(_ connection: NWConnection) {
        let session = RelaySession(id: UUID(), client: connection, server: self)
        sessions[ObjectIdentifier(session)] = session
        connection.stateUpdateHandler = { [weak session] state in
            guard let session else { return }
            switch state {
            case .cancelled, .failed:
                session.server?.close(session)
            default:
                break
            }
        }
        connection.start(queue: queue)
        session.readClient()
    }

    fileprivate func clientBytes(_ session: RelaySession, _ data: Data) {
        guard !session.finished, !session.forwarding else { return }
        session.requestBuffer.append(data)

        if let request = session.request {
            if session.requestBuffer.count >= request.contentLength {
                completeBody(session, request)
            }
            return
        }

        guard let separator = session.requestBuffer.range(of: Self.headerEnd) else {
            if session.requestBuffer.count > Self.maxHeadBytes { sendError(session, 400) }
            return
        }
        let headBytes = Data(session.requestBuffer[..<separator.lowerBound])
        let rest = Data(session.requestBuffer[separator.upperBound...])
        guard let request = RelayRequest(headBytes),
              request.contentLength <= Self.maxBodyBytes,
              request.contentLength >= 0 else {
            sendError(session, requestTooLarge(headBytes) ? 413 : 400)
            return
        }
        if let status = request.rejection(port: port) { sendError(session, status); return }
        session.request = request
        session.requestBuffer = rest
        if request.expectContinue { writeContinue(session) }
        if session.requestBuffer.count >= request.contentLength { completeBody(session, request) }
    }

    /// A declared body over the cap is answered 413 rather than 400: the request
    /// is well formed, it is simply more than this loopback relay will buffer.
    private func requestTooLarge(_ head: Data) -> Bool {
        guard let request = RelayRequest(head) else { return false }
        return request.contentLength > Self.maxBodyBytes
    }

    private func completeBody(_ session: RelaySession, _ request: RelayRequest) {
        let body = Data(session.requestBuffer.prefix(request.contentLength))
        session.requestBuffer.removeAll()
        session.forwarding = true
        session.parser = OllamaThinkingStream(path: RelayRequest.path(of: request.target), body: body)
        openUpstream(session, request: request, body: body)
    }

    fileprivate func clientGone(_ session: RelaySession) {
        guard !session.finished else { return }
        session.finished = true
        session.upstream?.cancel()
        session.upstream = nil
        observe(session.id, "", false)
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    /// Server shutdown and a failed client connection share one path: cancel
    /// both halves, tell the observer the turn is over, forget the session.
    private func close(_ session: RelaySession) {
        guard !session.finished else { return }
        session.finished = true
        session.upstream?.cancel()
        session.upstream = nil
        session.client.cancel()
        observe(session.id, "", false)
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    // MARK: - Upstream side

    private func openUpstream(_ session: RelaySession, request: RelayRequest, body: Data) {
        let host = upstream.host ?? "127.0.0.1"
        let number = upstream.port ?? 80
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(number)) else {
            sendError(session, 502)
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                      using: NWParameters(tls: nil, tcp: tcp))
        session.upstream = connection
        connection.stateUpdateHandler = { [weak session] state in
            guard let session, let server = session.server else { return }
            switch state {
            case .ready:
                server.sendUpstreamRequest(session, request: request, body: body)
            case .waiting(let error):
                // A refused loopback port is reported as waiting, not failed:
                // there is no path to wait for, so answer 502 now rather than
                // until the client's own request timeout.
                if case .posix(let code) = error, code == .ECONNREFUSED {
                    server.upstreamGone(session)
                }
            case .failed, .cancelled:
                server.upstreamGone(session)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    fileprivate func sendUpstreamRequest(_ session: RelaySession, request: RelayRequest, body: Data) {
        guard let connection = session.upstream, !session.finished else { return }
        let head = upstreamRequestHead(request, body: body)
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak session] _ in
            guard let session, let connection = session.upstream else { return }
            if body.isEmpty {
                session.readUpstream()
            } else {
                connection.send(content: body, completion: .contentProcessed { [weak session] _ in
                    session?.readUpstream()
                })
            }
        })
    }

    fileprivate func upstreamBytes(_ session: RelaySession, _ data: Data) {
        guard !session.finished else { return }
        for event in session.decoder.append(data) { consume(session, event) }
    }

    fileprivate func upstreamClosed(_ session: RelaySession) {
        guard !session.finished else { return }
        for event in session.decoder.close() { consume(session, event) }
        guard !session.finished else { return }
        if session.responded { finish(session) } else { sendError(session, 502) }
    }

    fileprivate func upstreamGone(_ session: RelaySession) {
        guard !session.finished else { return }
        if session.responded { finish(session) } else { sendError(session, 502) }
    }

    private func consume(_ session: RelaySession, _ event: HTTPResponseDecoder.Event) {
        switch event {
        case .head(let status, let reason, let headers):
            session.responded = true
            writeResponseHead(session, status: status, reason: reason, headers: headers)
        case .body(let data):
            for (model, active) in session.parser?.append(data) ?? [] { observe(session.id, model, active) }
            publishPerformance(session)
            write(session, data)
        case .end:
            finish(session)
        }
    }

    /// The upstream answer is complete. Half-close the client so a body with no
    /// `Content-Length` is delimited the way HTTP/1.1 says it is.
    private func finish(_ session: RelaySession) {
        guard !session.finished else { return }
        session.finished = true
        session.parser?.finish()
        publishPerformance(session)
        observe(session.id, "", false)
        session.client.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak session] _ in session?.client.cancel() })
        session.upstream?.cancel()
        session.upstream = nil
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    private func publishPerformance(_ session: RelaySession) {
        if let measurement = session.parser?.takePerformance(), let model = session.parser?.model {
            onPerformance(model, measurement)
        }
    }

    // MARK: - Encoding

    private func upstreamRequestHead(_ request: RelayRequest, body: Data) -> String {
        let host = upstream.host ?? "127.0.0.1"
        let number = upstream.port ?? 80
        var lines = ["\(request.method) \(request.target) HTTP/1.1", "host: \(host):\(number)"]
        for (name, value) in request.headers {
            let lower = name.lowercased()
            if Self.hopByHop.contains(lower) || lower == "host" || lower == "expect"
                || lower == "content-length" || lower == "accept-encoding" { continue }
            lines.append("\(name): \(value)")
        }
        lines.append("content-length: \(body.count)")
        lines.append("accept-encoding: identity")
        lines.append("connection: close")
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    /// The upstream head, less hop-by-hop headers, with this relay's own
    /// `Connection: close` — so an unknown-length body ends at the close.
    private func writeResponseHead(_ session: RelaySession, status: Int, reason: String,
                                   headers: [(String, String)]) {
        var lines = ["HTTP/1.1 \(status) \(reason.isEmpty ? Self.reason(status) : reason)"]
        for (name, value) in headers where !Self.hopByHop.contains(name.lowercased()) {
            lines.append("\(name): \(value)")
        }
        lines.append("connection: close")
        write(session, Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    }

    private func writeContinue(_ session: RelaySession) {
        session.client.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in })
    }

    private func write(_ session: RelaySession, _ data: Data) {
        guard !session.finished, !data.isEmpty else { return }
        session.client.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendError(_ session: RelaySession, _ status: Int) {
        guard !session.finished else { return }
        session.finished = true
        observe(session.id, "", false)
        session.upstream?.cancel()
        session.upstream = nil
        let text = "HTTP/1.1 \(status) \(Self.reason(status))\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        session.client.send(content: Data(text.utf8), completion: .contentProcessed { [weak session] _ in
            session?.client.cancel()
        })
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

// MARK: - Session

/// One client connection, and at most one upstream connection serving it.
private final class RelaySession {
    let id: UUID
    let client: NWConnection
    weak var server: OllamaRelayServer?
    var requestBuffer = Data()
    var request: RelayRequest?
    var parser: OllamaThinkingStream?
    var upstream: NWConnection?
    var decoder = HTTPResponseDecoder()
    var forwarding = false
    var responded = false
    var finished = false

    init(id: UUID, client: NWConnection, server: OllamaRelayServer) {
        self.id = id
        self.client = client
        self.server = server
    }

    func readClient() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let server = self.server else { return }
            if let data, !data.isEmpty { server.clientBytes(self, data) }
            if error != nil || isComplete { server.clientGone(self); return }
            if !self.finished { self.readClient() }
        }
    }

    func readUpstream() {
        guard let connection = upstream, !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let server = self.server else { return }
            if let data, !data.isEmpty { server.upstreamBytes(self, data) }
            if error != nil { server.upstreamGone(self); return }
            if isComplete { server.upstreamClosed(self); return }
            if !self.finished { self.readUpstream() }
        }
    }
}

// MARK: - Request decoding

private struct RelayRequest {
    let method: String
    let target: String
    let headers: [(name: String, value: String)]
    let lower: [String: [String]]
    let contentLength: Int
    let expectContinue: Bool

    init?(_ head: Data) {
        guard let text = String(data: head, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        method = String(parts[0])
        target = String(parts[1])

        var headers: [(name: String, value: String)] = []
        var lower: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            lower[name.lowercased(), default: []].append(value)
        }
        self.headers = headers
        self.lower = lower
        contentLength = Int(lower["content-length"]?.first ?? "0") ?? 0
        expectContinue = (lower["expect"] ?? []).contains { $0.lowercased() == "100-continue" }
    }

    static func path(of target: String) -> String {
        String(target.split(separator: "?", maxSplits: 1).first ?? "")
    }

    /// 400 for a request this loopback port will not carry at all, 403 for one
    /// a browser could be made to send from another origin.
    func rejection(port: Int) -> Int? {
        guard method != "CONNECT", target.hasPrefix("/"), !target.hasPrefix("//"),
              !target.contains("\\"), (lower["upgrade"] ?? []).isEmpty else { return 400 }
        let hosts = lower["host"] ?? []
        guard hosts.count == 1,
              ["127.0.0.1:\(port)", "localhost:\(port)"].contains(hosts[0].lowercased()) else { return 400 }
        let origins = lower["origin"] ?? []
        let crossSite = (lower["sec-fetch-site"] ?? []).contains {
            $0.caseInsensitiveCompare("cross-site") == .orderedSame
        }
        guard !crossSite, origins.count <= 1, origins.allSatisfy(isLoopbackOrigin) else { return 403 }
        return nil
    }
}

// MARK: - Response decoding

/// Incremental HTTP/1.1 response decoder: length-delimited, chunked, or ended
/// by the connection closing. It yields the head once and body bytes as they
/// arrive, so a client never waits for a model's whole answer to see the first
/// token.
struct HTTPResponseDecoder {
    enum Event {
        case head(status: Int, reason: String, headers: [(String, String)])
        case body(Data)
        case end
    }

    private enum State {
        case head
        case fixed(Int)
        case chunkSize
        case chunkData(Int)
        case chunkCRLF
        case trailers
        case untilClose
        case done
    }

    private static let crlf = Data([13, 10])
    private static let headerEnd = Data([13, 10, 13, 10])

    private var state: State = .head
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while true {
            switch state {
            case .done:
                return events

            case .head:
                guard let separator = buffer.range(of: Self.headerEnd) else { return events }
                let headBytes = Data(buffer[..<separator.lowerBound])
                buffer.removeFirst(separator.upperBound)
                guard let parsed = Self.parseHead(headBytes) else {
                    state = .done
                    events.append(.end)
                    return events
                }
                // A 1xx is not the answer; keep waiting for the real head.
                if parsed.status < 200 { continue }
                events.append(.head(status: parsed.status, reason: parsed.reason, headers: parsed.headers))
                if let length = parsed.contentLength {
                    if length == 0 { state = .done; events.append(.end) }
                    else { state = .fixed(length) }
                } else if parsed.chunked {
                    state = .chunkSize
                } else {
                    state = .untilClose
                }

            case .fixed(let remaining):
                guard !buffer.isEmpty else { return events }
                let take = min(remaining, buffer.count)
                events.append(.body(Data(buffer.prefix(take))))
                buffer.removeFirst(take)
                if take == remaining { state = .done; events.append(.end) }
                else { state = .fixed(remaining - take) }

            case .chunkSize:
                guard let separator = buffer.range(of: Self.crlf) else { return events }
                let line = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
                buffer.removeFirst(separator.upperBound)
                let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    state = .done
                    events.append(.end)
                    return events
                }
                state = size == 0 ? .trailers : .chunkData(size)

            case .chunkData(let remaining):
                guard !buffer.isEmpty else { return events }
                let take = min(remaining, buffer.count)
                events.append(.body(Data(buffer.prefix(take))))
                buffer.removeFirst(take)
                state = take == remaining ? .chunkCRLF : .chunkData(remaining - take)

            case .chunkCRLF:
                guard buffer.count >= 2 else { return events }
                buffer.removeFirst(2)
                state = .chunkSize

            case .trailers:
                guard let separator = buffer.range(of: Self.crlf) else { return events }
                let line = buffer[..<separator.lowerBound]
                buffer.removeFirst(separator.upperBound)
                if line.isEmpty { state = .done; events.append(.end) }

            case .untilClose:
                guard !buffer.isEmpty else { return events }
                events.append(.body(buffer))
                buffer.removeAll()
                return events
            }
        }
    }

    /// The upstream closed. An un-terminated body is simply over.
    mutating func close() -> [Event] {
        switch state {
        case .head, .done:
            return []
        case .untilClose, .fixed, .chunkSize, .chunkData, .chunkCRLF, .trailers:
            state = .done
            return [.end]
        }
    }

    private static func parseHead(_ data: Data)
    -> (status: Int, reason: String, headers: [(String, String)], contentLength: Int?, chunked: Bool)? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        let reason = parts.count >= 3 ? String(parts[2]) : ""

        var headers: [(String, String)] = []
        var contentLength: Int?
        var chunked = false
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            switch name.lowercased() {
            case "content-length":
                contentLength = Int(value.split(separator: ",").first.map(String.init) ?? "")
            case "transfer-encoding":
                if value.lowercased().contains("chunked") { chunked = true }
            default:
                break
            }
        }
        return (status, reason, headers, contentLength, chunked)
    }
}

// Browser requests from third-party websites must not reach the loopback relay (CSRF / drive-by attacks).
// Sandboxed iframes (`<iframe sandbox="allow-scripts">`) and data: URLs serialize origin as "null".
// Rejecting "null" prevents drive-by CSRF attacks from untrusted web pages; native CLI callers do not send Origin at all.
func isLoopbackOrigin(_ origin: String) -> Bool {
    let trimmed = origin.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.caseInsensitiveCompare("null") == .orderedSame { return false }
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.user == nil, url.password == nil,
          url.path.isEmpty || url.path == "/",
          url.query == nil,
          url.fragment == nil,
          let host = url.host?.lowercased(),
          ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else {
        return false
    }
    if let port = url.port { return (1...65535).contains(port) }
    if trimmed.hasSuffix(":") || trimmed.hasSuffix(":/") { return false }
    return true
}
