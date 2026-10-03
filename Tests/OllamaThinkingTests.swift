import XCTest
import SwiftUI
import Network
@testable import Codenotch

final class OllamaThinkingStreamTests: XCTestCase {
    func testFragmentedNativeThinkingStopsAtAnswerAndCompletion() {
        var parser = OllamaThinkingStream(path: "/api/chat", body: Data(#"{"model":"qwen3"}"#.utf8))
        let stream = #"{"model":"qwen3:latest","message":{"thinking":"생각"}}"# + "\n"
            + #"{"message":{"thinking":" more"}}"# + "\n"
            + #"{"message":{"content":"answer"}}"# + "\n"
            + #"{"done":true}"# + "\n"
        var changes: [(String, Bool)] = []
        for byte in stream.utf8 { changes += parser.append(Data([byte])) }
        XCTAssertEqual(changes.map(\.0), ["qwen3:latest", "qwen3:latest"])
        XCTAssertEqual(changes.map(\.1), [true, false])
        XCTAssertFalse(parser.isThinking)
        XCTAssertTrue(parser.append(Data((#"{"thinking":"late"}"# + "\n").utf8)).isEmpty)
    }

    func testGenerateAndOpenAIStreamFields() {
        var native = OllamaThinkingStream(path: "/api/generate", body: Data(#"{"model":"gemma4:e4b","stream":true}"#.utf8))
        XCTAssertEqual(native.append(Data((#"{"thinking":"reason"}"# + "\n" + #"{"response":"4"}"# + "\n").utf8)).map(\.1), [true, false])
        var openAI = OllamaThinkingStream(path: "/v1/chat/completions", body: Data(#"{"model":"deepseek-r1:1.5b","stream":true}"#.utf8))
        let payload = "data: " + #"{"choices":[{"delta":{"reasoning":"reason"}}]}"# + "\n\n"
            + "data: " + #"{"choices":[{"delta":{"reasoning_content":"more"}}]}"# + "\n\n"
            + "data: " + #"{"choices":[{"delta":{"content":"4"}}]}"# + "\n\n"
            + "data: [DONE]\n\n"
        XCTAssertEqual(openAI.append(Data(payload.utf8)).map(\.1), [true, false])
    }

    func testNoInferenceFromNonStreamingResponsesOrAnswerOnlyModels() {
        for (path, request) in [("/api/chat", #"{"model":"qwen3","stream":false}"#),
                                ("/v1/chat/completions", #"{"model":"qwen3"}"#),
                                ("/api/ps", #"{"model":"qwen3"}"#)] {
            var parser = OllamaThinkingStream(path: path, body: Data(request.utf8))
            XCTAssertTrue(parser.append(Data((#"{"thinking":"finished","done":true}"# + "\n").utf8)).isEmpty)
        }
        var parser = OllamaThinkingStream(path: "/api/generate", body: Data(#"{"model":"llama3.2:1b"}"#.utf8))
        XCTAssertTrue(parser.append(Data((#"{"response":"answer"}"# + "\n").utf8)).isEmpty)
    }

    func testTerminalErrorsToolCallsAndOversizeFramesClearThinking() {
        for end in [#"{"error":"failed"}"# + "\n", #"{"done":true,"thinking":"last"}"# + "\n",
                    #"{"message":{"tool_calls":[{}]}}"# + "\n", "malformed\n", String(repeating: "x", count: 1_048_577)] {
            var parser = OllamaThinkingStream(path: "/api/chat", body: Data(#"{"model":"qwen3"}"#.utf8))
            XCTAssertEqual(parser.append(Data((#"{"thinking":"reason"}"# + "\n").utf8)).map(\.1), [true])
            XCTAssertEqual(parser.append(Data(end.utf8)).map(\.1), [false])
            XCTAssertFalse(parser.isThinking)
        }
    }

    func testNamesKeepNamespacesAndDefaultTags() {
        XCTAssertEqual(OllamaThinkingStream.modelKey(" qwen3 "), "qwen3:latest")
        XCTAssertEqual(OllamaThinkingStream.modelKey("user/model:q4"), "user/model:q4")
        XCTAssertEqual(OllamaThinkingStream.modelKey("host:443/user/model"), "host:443/user/model:latest")
    }
}

@MainActor
final class OllamaThinkingActivityTests: XCTestCase {
    func testConcurrentRequestsAreCountedPerModelAndClearedOnDisable() {
        let relay = OllamaActivityRelay()
        let first = UUID(), second = UUID(), other = UUID()
        relay.observe(id: first, model: "qwen3", thinking: true, now: Date(timeIntervalSince1970: 10))
        relay.observe(id: second, model: "qwen3:latest", thinking: true, now: Date(timeIntervalSince1970: 20))
        relay.observe(id: other, model: "gemma4:e4b", thinking: true)
        XCTAssertEqual(relay.thinkingModels.count, 2)
        relay.observe(id: first, model: "", thinking: false)
        XCTAssertEqual(relay.thinkingModels["qwen3:latest"], Date(timeIntervalSince1970: 20))
        relay.observe(id: second, model: "", thinking: false)
        XCTAssertEqual(Set(relay.thinkingModels.keys), ["gemma4:e4b"])
        relay.configure(enabled: false, endpoint: OllamaEndpoint.defaultAddress)
        XCTAssertTrue(relay.thinkingModels.isEmpty)
        XCTAssertFalse(relay.ready)
    }

    func testOnlyMatchingModelUsesExistingActivityArcOnEveryEdge() throws {
        let reading = try OllamaLocalUsage.parse(Data(#"{"models":[{"name":"gemma4:e4b","size":9610000000},{"name":"qwen3:0.6b","size":675576545}]}"#.utf8))
        let snapshot = ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollama,
            fidelity: .official, status: .ok, windows: [], kind: .localRuntime, localRuntime: reading)
        let model = NotchViewModel()
        model.updateSnapshots([snapshot])
        let gemma = model.snapshots[0], qwen = model.snapshots[1]
        model.thinkingModels = ["gemma4:e4b": Date()]
        XCTAssertEqual(model.activity(for: gemma)?.state, .working)
        XCTAssertNil(model.activity(for: qwen))
        XCTAssertNil(model.activity(for: "ollama-local"))
        let directory = ProcessInfo.processInfo.environment["OLLAMA_THINKING_RENDER_DIRECTORY"]
        for edge in NotchEdge.allCases {
            let renderer = ImageRenderer(content: TooltipCard(snapshot: gemma, activity: model.activity(for: gemma),
                now: Date(), direction: edge.tooltipDirection))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            if let directory {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("thinking-\(edge.rawValue).png"))
            }
        }
    }
}

private final class RelayEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, Bool)] = []
    private var speedStorage: [(String, LocalModelPerformance)] = []
    func record(_ model: String, _ active: Bool) { lock.lock(); storage.append((model, active)); lock.unlock() }
    func recordSpeed(_ model: String, _ reading: LocalModelPerformance) { lock.lock(); speedStorage.append((model, reading)); lock.unlock() }
    var speeds: [(String, LocalModelPerformance)] { lock.lock(); defer { lock.unlock() }; return speedStorage }
    var events: [(String, Bool)] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class OllamaRelayTransportTests: XCTestCase {
    func testNativeStreamAndSingleResponsePublishMetricsWithoutChangingBytes() async throws {
        for streaming in [true, false] {
            let json = #"{"model":"gemma4:e4b","response":"4","done":true,"eval_count":90,"eval_duration":3000000000}"#
            let payload = Data((json + (streaming ? "\n" : "")).utf8)
            let stub = try await RelayStub.start(payload: payload)
            let evidence = RelayEvidence()
            let server = OllamaRelayServer(upstream: stub.url, onPerformance: evidence.recordSpeed) { _, model, active in
                evidence.record(model, active)
            }
            let port = try await server.start(port: 0)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/generate")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gemma4:e4b", "stream": streaming])
            let (data, _) = try await URLSession.shared.data(for: request)
            XCTAssertEqual(data, payload)
            XCTAssertEqual(evidence.speeds.count, 1)
            XCTAssertEqual(evidence.speeds.first?.0, "gemma4:e4b")
            XCTAssertEqual(evidence.speeds.first?.1.tokensPerSecond, 30)
            XCTAssertFalse(evidence.events.contains { $0.1 })
            await server.stop()
            await stub.stop()
        }
    }

    func testForwardsStreamingBytesAndTracksThinkingWithoutChangingPayload() async throws {
        let stream = #"{"model":"qwen3:0.6b","thinking":"reason"}"# + "\n"
            + #"{"response":"answer"}"# + "\n" + #"{"done":true}"# + "\n"
        let stub = try await RelayStub.start(payload: Data(stream.utf8))
        let evidence = RelayEvidence()
        let server = OllamaRelayServer(upstream: stub.url) { _, model, active in evidence.record(model, active) }
        let port = try await server.start(port: 0)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/generate?test=1")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"qwen3:0.6b","prompt":"public fixture","stream":true}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(data, Data(stream.utf8))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Fixture"), "kept")
        XCTAssertTrue(evidence.events.contains { $0.0 == "qwen3:0.6b" && $0.1 })
        XCTAssertFalse(evidence.events.last?.1 ?? true)
        await server.stop()
        await stub.stop()
    }

    func testClientCancellationAndRelayStopClearActiveThinking() async throws {
        let stub = try await RelayStub.start(payload: Data((#"{"thinking":"reason"}"# + "\n").utf8), holdOpen: true)
        let evidence = RelayEvidence()
        let server = OllamaRelayServer(upstream: stub.url) { _, model, active in evidence.record(model, active) }
        let port = try await server.start(port: 0)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/generate")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"qwen3"}"#.utf8)
        let task = URLSession.shared.dataTask(with: request)
        task.resume()
        for _ in 0..<100 {
            if evidence.events.contains(where: { $0.1 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(evidence.events.contains { $0.1 })
        task.cancel()
        for _ in 0..<100 {
            if evidence.events.last?.1 == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(evidence.events.last?.1, false)
        await server.stop()
        await stub.stop()
    }

    func testUpstreamFailureAndInvalidHostsAreHonestHTTPFailures() async throws {
        let stub = try await RelayStub.start(payload: Data())
        let url = stub.url
        await stub.stop()
        let server = OllamaRelayServer(upstream: url) { _, _, _ in }
        let port = try await server.start(port: 0)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/ps")!)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        request.setValue("attacker.example", forHTTPHeaderField: "Host")
        let (_, rejected) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        await server.stop()
    }

    func testCrossOriginAndCSRFRequestsAreForbidden() async throws {
        let payload = Data(#"{"status":"ok"}"#.utf8)
        let stub = try await RelayStub.start(payload: payload)
        let server = OllamaRelayServer(upstream: stub.url) { _, _, _ in }
        let port = try await server.start(port: 0)

        var untrusted = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/tags")!)
        untrusted.setValue("https://malicious.example", forHTTPHeaderField: "Origin")
        let (_, untrustedResponse) = try await URLSession.shared.data(for: untrusted)
        XCTAssertEqual((untrustedResponse as? HTTPURLResponse)?.statusCode, 403)

        var crossSite = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/tags")!)
        crossSite.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        let (_, crossSiteResponse) = try await URLSession.shared.data(for: crossSite)
        XCTAssertEqual((crossSiteResponse as? HTTPURLResponse)?.statusCode, 403)

        var loopback = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/tags")!)
        loopback.setValue("http://127.0.0.1:11435", forHTTPHeaderField: "Origin")
        let (loopbackData, loopbackResponse) = try await URLSession.shared.data(for: loopback)
        XCTAssertEqual((loopbackResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(loopbackData, payload)

        var noOrigin = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/tags")!)
        let (noOriginData, noOriginResponse) = try await URLSession.shared.data(for: noOrigin)
        XCTAssertEqual((noOriginResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(noOriginData, payload)

        var nullOrigin = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/tags")!)
        nullOrigin.setValue("null", forHTTPHeaderField: "Origin")
        let (_, nullResponse) = try await URLSession.shared.data(for: nullOrigin)
        XCTAssertEqual((nullResponse as? HTTPURLResponse)?.statusCode, 403)

        var multipleOrigins = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/tags")!)
        multipleOrigins.setValue("http://localhost:3000", forHTTPHeaderField: "Origin")
        multipleOrigins.addValue("http://127.0.0.1:11435", forHTTPHeaderField: "Origin")
        let (_, multipleResponse) = try await URLSession.shared.data(for: multipleOrigins)
        XCTAssertEqual((multipleResponse as? HTTPURLResponse)?.statusCode, 403)

        await server.stop()
        await stub.stop()
    }

    func testIsLoopbackOrigin() {
        XCTAssertTrue(isLoopbackOrigin("http://127.0.0.1:48666"))
        XCTAssertTrue(isLoopbackOrigin("http://localhost:5173"))
        XCTAssertTrue(isLoopbackOrigin("http://127.0.0.1"))
        XCTAssertTrue(isLoopbackOrigin("http://localhost"))
        XCTAssertTrue(isLoopbackOrigin("https://127.0.0.1:48666"))
        XCTAssertTrue(isLoopbackOrigin("https://localhost:3000"))
        XCTAssertTrue(isLoopbackOrigin("http://[::1]:8080"))
        XCTAssertTrue(isLoopbackOrigin("http://[::1]"))
        XCTAssertTrue(isLoopbackOrigin("http://LOCALHOST:3000"))

        XCTAssertFalse(isLoopbackOrigin("null"))
        XCTAssertFalse(isLoopbackOrigin("NULL"))
        XCTAssertFalse(isLoopbackOrigin(""))
        XCTAssertFalse(isLoopbackOrigin("   "))
        XCTAssertFalse(isLoopbackOrigin("https://evil.com"))
        XCTAssertFalse(isLoopbackOrigin("http://attacker.com:8080"))
        XCTAssertFalse(isLoopbackOrigin("https://evil-localhost.com"))
        XCTAssertFalse(isLoopbackOrigin("https://localhost.attacker.com"))
        XCTAssertFalse(isLoopbackOrigin("http://127.0.0.1.attacker.com"))
        XCTAssertFalse(isLoopbackOrigin("http://attacker.com:127.0.0.1"))
        XCTAssertFalse(isLoopbackOrigin("http://localhost@attacker.com"))
        XCTAssertFalse(isLoopbackOrigin("http://attacker.com/localhost"))
        XCTAssertFalse(isLoopbackOrigin("http://attacker.com?localhost"))
        XCTAssertFalse(isLoopbackOrigin("http://attacker.com#localhost"))
        XCTAssertFalse(isLoopbackOrigin("file:///etc/passwd"))
        XCTAssertFalse(isLoopbackOrigin("javascript:alert(1)"))
        XCTAssertFalse(isLoopbackOrigin("http://localhost:abc"))
        XCTAssertFalse(isLoopbackOrigin("http://localhost:70000"))
        XCTAssertFalse(isLoopbackOrigin("http://localhost:0"))
        XCTAssertFalse(isLoopbackOrigin("http://localhost:"))
        XCTAssertFalse(isLoopbackOrigin("http://localhost:/"))
        XCTAssertFalse(isLoopbackOrigin("http://localhost#evil"))
        XCTAssertFalse(isLoopbackOrigin("http://localhost?evil=1"))
    }
}

/// A one-answer HTTP server for the relay tests, on Network.framework so the
/// test target no longer drags SwiftNIO in behind the app.
private final class RelayStub {
    let listener: NWListener
    let queue = DispatchQueue(label: "codenotch.relay-stub")
    private var connections: [NWConnection] = []
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }

    private init(listener: NWListener) { self.listener = listener }

    static func start(payload: Data, holdOpen: Bool = false) async throws -> RelayStub {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let stub = RelayStub(listener: listener)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak stub] connection in
                stub?.accept(connection, payload: payload, holdOpen: holdOpen)
            }
            listener.start(queue: stub.queue)
        }
        return stub
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                for connection in self.connections { connection.cancel() }
                self.connections.removeAll()
                self.listener.cancel()
                continuation.resume()
            }
        }
    }

    private func accept(_ connection: NWConnection, payload: Data, holdOpen: Bool) {
        connections.append(connection)
        connection.start(queue: queue)
        pump(connection, buffer: Data(), payload: payload, holdOpen: holdOpen)
    }

    /// Read the request before answering: closing on a client still writing its
    /// body would surface as a reset instead of a response.
    private func pump(_ connection: NWConnection, buffer: Data, payload: Data, holdOpen: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || isComplete { connection.cancel(); return }
            if Self.requestComplete(buffer) {
                self.respond(connection, payload: payload, holdOpen: holdOpen)
            } else {
                self.pump(connection, buffer: buffer, payload: payload, holdOpen: holdOpen)
            }
        }
    }

    private static func requestComplete(_ buffer: Data) -> Bool {
        let marker = Data([13, 10, 13, 10])
        guard let separator = buffer.range(of: marker) else { return false }
        let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
        var contentLength = 0
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "content-length",
               let value = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                contentLength = value
            }
        }
        return buffer.count >= separator.upperBound + contentLength
    }

    /// No `Content-Length` and no chunking: the body is delimited by the close,
    /// which is exactly what a real streaming runtime does.
    private func respond(_ connection: NWConnection, payload: Data, holdOpen: Bool) {
        let head = "HTTP/1.1 200 OK\r\ncontent-type: application/x-ndjson\r\nx-fixture: kept\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            self?.sendChunks(connection, payload: payload, index: 0, holdOpen: holdOpen)
        })
    }

    /// Split inside UTF-8/JSON boundaries just as a real TCP stream can.
    private func sendChunks(_ connection: NWConnection, payload: Data, index: Int, holdOpen: Bool) {
        guard index < payload.count else {
            guard !holdOpen else { return }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let end = min(index + 7, payload.count)
        connection.send(content: Data(payload[index..<end]), completion: .contentProcessed { [weak self] _ in
            self?.sendChunks(connection, payload: payload, index: end, holdOpen: holdOpen)
        })
    }
}
