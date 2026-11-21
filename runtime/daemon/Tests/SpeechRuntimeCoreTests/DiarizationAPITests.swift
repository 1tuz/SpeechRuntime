import Foundation
import Network
import XCTest
@testable import SpeechRuntimeCore

/// End-to-end API tests for post-transcription diarization over the Router,
/// using a stub Wavo CLI. They exercise auth, failure modes, source
/// independence, transcript field/offset preservation, and limits.
/// Pure annotate/parse cases live in DiarizationTests.swift.
final class DiarizationAPITests: XCTestCase {
    private var workDir: URL!

    override func setUp() {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diar-api-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Writes a stub Wavo binary that echoes fixed turns JSON.
    private func stubWavo(turnsJSON: String, delaySeconds: Double = 0) throws -> String {
        let script = workDir.appendingPathComponent("stub-wavo")
        try """
        #!/bin/sh
        sleep \(delaySeconds)
        printf '%s' '\(turnsJSON)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func makeRouter(binary: String, model: String = "/nonexistent/model.gguf") -> Router {
        let spec: [String: Any] = [
            "models": [:],
            "diarization": ["binary": binary, "model": model, "backend": "cpu"],
        ]
        let snapshot = RuntimeConfig(jsonObject: spec)
        return Router(
            token: AuthToken(value: "test-token"),
            worker: WorkerClient(workerPath: "/nonexistent/sr-worker") { _ in },
            config: { snapshot },
            idle: IdlePolicy(),
            voices: VoiceStore(),
            log: { _ in }
        )
    }

    private func request(
        _ method: String, _ path: String, body: Any? = nil,
        token: String = "test-token", rawBody: Data? = nil
    ) -> HTTPRequest {
        HTTPRequest(
            method: method, path: path, query: [:],
            headers: ["authorization": "Bearer \(token)"],
            body: rawBody ?? body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data())
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private let segments: [[String: Any]] = [
        ["source": "mic", "start_ms": 100, "end_ms": 300, "text": "Деплой в кубернетес"],
        ["source": "system", "start_ms": 400, "end_ms": 700, "text": "kubernetes rollout"],
        ["source": "system", "start_ms": 1000, "end_ms": 1300, "text": "PostgreSQL"],
    ]

    private func wavBody(_ wav: Data, offset: Int, segments input: [[String: Any]]? = nil) -> [String: Any] {
        [
            "mode": "nemotron",
            "segments": input ?? segments,
            "system_audio_offset_ms": offset,
            "system_audio_base64": wav.base64EncodedString(),
        ]
    }

    /// Small valid 16-bit mono RIFF/WAVE container (44-byte canonical header).
    private func stubWAV(pcmBytes: Int = 16) -> Data {
        var wav = Data()
        let dataBytes = pcmBytes
        let total = 36 + dataBytes
        func append(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        append("RIFF"); appendU32(UInt32(total)); append("WAVE")
        append("fmt "); appendU32(16); appendU16(1); appendU16(1)
        appendU32(16_000); appendU32(32_000); appendU16(2); appendU16(16)
        append("data"); appendU32(UInt32(dataBytes))
        wav.append(Data(repeating: 0, count: dataBytes))
        return wav
    }

    private func presentModel() throws -> String {
        let model = workDir.appendingPathComponent("model.gguf")
        try Data([1]).write(to: model)
        return model.path
    }

    // MARK: - Auth

    func testDiarizationRoutesRequireBearerToken() async throws {
        let router = makeRouter(binary: "/nonexistent/wavo")
        for (method, path) in [("GET", "/v1/diarization"), ("POST", "/v1/audio/diarization")] {
            let response = await router.handle(request(method, path, body: ["mode": "source"], token: "wrong"))
            XCTAssertEqual(response.status, 401, "\(method) \(path)")
        }
    }

    // MARK: - GET availability truthfulness

    func testGetDiarizationReportsBinaryAndModelAvailability() async throws {
        let binary = try stubWavo(turnsJSON: "{}")
        let router = makeRouter(binary: binary, model: try presentModel())
        let payload = try json(await router.handle(request("GET", "/v1/diarization")))
        let modes = try XCTUnwrap(payload["modes"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(modes["source"] as? [String: Any])["available"] as? Bool == true)
        let nemotron = try XCTUnwrap(modes["nemotron"] as? [String: Any])
        XCTAssertEqual(nemotron["available"] as? Bool, true)
        XCTAssertEqual(nemotron["model"] as? String, "nemotron-diarization")
        XCTAssertEqual(nemotron["model_available"] as? Bool, true)
    }

    func testGetDiarizationReportsMissingBinaryAndModel() async throws {
        let router = makeRouter(binary: "/nonexistent/wavo", model: "/nonexistent/model.gguf")
        let payload = try json(await router.handle(request("GET", "/v1/diarization")))
        let nemotron = try XCTUnwrap((payload["modes"] as? [String: Any])?["nemotron"] as? [String: Any])
        XCTAssertEqual(nemotron["available"] as? Bool, false)
        XCTAssertEqual(nemotron["model_available"] as? Bool, false)
    }

    // MARK: - nemotron explicit errors

    func testNemotronFailsExplicitlyWithoutExecutable() async throws {
        let router = makeRouter(binary: "/nonexistent/wavo")
        let response = await router.handle(
            request("POST", "/v1/audio/diarization", body: wavBody(stubWAV(), offset: 0)))
        XCTAssertEqual(response.status, 400)
        let message = try XCTUnwrap(try json(response)["error"] as? String)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("wavo"), message)
    }

    // MARK: - stub Wavo end-to-end

    func testNemotronEndToEndPreservesTranscriptAndShiftsTurns() async throws {
        let binary = try stubWavo(turnsJSON:
            #"{"turns":[{"speaker":1,"start_ms":400,"end_ms":800},{"speaker":2,"start_ms":900,"end_ms":1400}]}"#)
        let router = makeRouter(binary: binary, model: try presentModel())
        let meetingSegments = [segments[0],
                               ["source": "system", "start_ms": 1400, "end_ms": 1700,
                                "text": "kubernetes rollout", "confidence": 0.9],
                               ["source": "system", "start_ms": 2000, "end_ms": 2300,
                                "text": "PostgreSQL"]]
        let payload = try json(await router.handle(
            request("POST", "/v1/audio/diarization", body: wavBody(stubWAV(), offset: 1000, segments: meetingSegments))))
        let annotated = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        // Word-segment text, order and timestamps are never rewritten.
        XCTAssertEqual(annotated.map { $0["text"] as? String }, meetingSegments.map { $0["text"] as? String })
        XCTAssertEqual(annotated.map { $0["start_ms"] as? Int }, meetingSegments.map { $0["start_ms"] as? Int })
        XCTAssertEqual(annotated.map { $0["end_ms"] as? Int }, meetingSegments.map { $0["end_ms"] as? Int })
        XCTAssertEqual(annotated[1]["confidence"] as? Double, 0.9)
        // Mic stays local regardless of Nemotron; system words get remote IDs.
        XCTAssertEqual(annotated.map { $0["speaker_id"] as? String }, ["local", "remote:1", "remote:2"])
        // Response turns are on the meeting timeline: offset added exactly once.
        let turns = try XCTUnwrap(payload["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.map { $0["speaker_id"] as? String }, ["remote:1", "remote:2"])
        XCTAssertEqual(turns.map { $0["start_ms"] as? Int }, [1400, 1900])
        XCTAssertEqual(turns.map { $0["end_ms"] as? Int }, [1800, 2400])
    }

    func testNegativeOffsetIsAcceptedOnceApplied() async throws {
        let binary = try stubWavo(turnsJSON:
            #"{"turns":[{"speaker":1,"start_ms":400,"end_ms":800}]}"#)
        let router = makeRouter(binary: binary, model: try presentModel())
        let payload = try json(await router.handle(
            request("POST", "/v1/audio/diarization", body: wavBody(stubWAV(), offset: -300))))
        let turns = try XCTUnwrap(payload["turns"] as? [[String: Any]])
        XCTAssertEqual(turns[0]["start_ms"] as? Int, 100)
        XCTAssertEqual(turns[0]["end_ms"] as? Int, 500)
    }

    func testSourceModeIsIndependentOfWavoAndAudio() async throws {
        // No binary, no WAV: source mode must work fully offline.
        let router = makeRouter(binary: "/nonexistent/wavo")
        let payload = try json(await router.handle(
            request("POST", "/v1/audio/diarization",
                    body: ["mode": "source", "segments": segments])))
        let annotated = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        XCTAssertEqual(annotated.map { $0["speaker_id"] as? String }, ["local", "remote", "remote"])
        XCTAssertEqual(payload["turns"] as? [AnyHashable], [])
    }

    func testNemotronWithOnlyMicSegmentsNeverInvokesCLI() async throws {
        // The stub would fail the request if invoked with a broken script.
        let binary = try stubWavo(turnsJSON: "not-json")
        let router = makeRouter(binary: binary, model: try presentModel())
        let payload = try json(await router.handle(
            request("POST", "/v1/audio/diarization",
                    body: ["mode": "nemotron", "segments": [segments[0]]])))
        let annotated = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        XCTAssertEqual(annotated[0]["speaker_id"] as? String, "local")
    }

    func testNemotronWithoutModelYieldsClearErrorForSystemAudio() async throws {
        let binary = try stubWavo(turnsJSON: #"{"turns":[]}"#)
        let router = makeRouter(binary: binary, model: "/nonexistent/model.gguf")
        let response = await router.handle(
            request("POST", "/v1/audio/diarization", body: wavBody(stubWAV(), offset: 0)))
        XCTAssertEqual(response.status, 400)
        let message = try XCTUnwrap(try json(response)["error"] as? String)
        // Clear explicit error about the missing model, not a silent switch.
        XCTAssertTrue(message.localizedCaseInsensitiveContains("model"), message)
    }

    func testNemotronRejectsMissingOrInvalidWAV() async throws {
        let binary = try stubWavo(turnsJSON: #"{"turns":[]}"#)
        let router = makeRouter(binary: binary, model: try presentModel())
        for bad in [
            ["mode": "nemotron", "segments": segments],
            ["mode": "nemotron", "segments": segments, "system_audio_base64": "bm90LXdhdiE="],
            ["mode": "nemotron", "segments": segments, "system_audio_offset_ms": "0"],
        ] {
            let response = await router.handle(request("POST", "/v1/audio/diarization", body: bad))
            XCTAssertEqual(response.status, 400)
        }
    }

    func testCLIFailureSurfacesAsError() async throws {
        let script = workDir.appendingPathComponent("failing-wavo")
        try "#!/bin/sh\necho boom >&2\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let router = makeRouter(binary: script.path, model: try presentModel())
        let response = await router.handle(
            request("POST", "/v1/audio/diarization", body: wavBody(stubWAV(), offset: 0)))
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(try json(response)["error"] as? String != nil)
    }

    func testBodyLimitAppliesOnlyToDiarizationRoute() async throws {
        let router = makeRouter(binary: "/nonexistent/wavo")
        let oversized = Data(repeating: 0, count: Router.diarizationBodyBytes + 1)
        let response = await router.handle(
            request("POST", "/v1/audio/diarization", rawBody: oversized))
        XCTAssertEqual(response.status, 400)
        let message = try XCTUnwrap(try json(response)["error"] as? String)
        XCTAssertTrue(message.contains("limit"), message)
    }

    func testConcurrentNemotronRequestsAreSerializedOrRefusedNotCorrupted() async throws {
        let binary = try stubWavo(turnsJSON:
            #"{"turns":[{"speaker":1,"start_ms":400,"end_ms":800}]}"#, delaySeconds: 0.2)
        let router = makeRouter(binary: binary, model: try presentModel())
        let body = wavBody(stubWAV(), offset: 0)
        async let a = router.handle(request("POST", "/v1/audio/diarization", body: body))
        async let b = router.handle(request("POST", "/v1/audio/diarization", body: body))
        let (first, second) = await (a, b)
        // Both must be well-formed JSON; one may legitimately be refused as busy.
        for response in [first, second] {
            XCTAssertTrue(response.status == 200 || response.status == 400)
            _ = try json(response)
        }
        XCTAssertTrue(first.status == 200 || second.status == 200)
    }

    // MARK: - client surface

    func testClientDiarizationStatusFailsCleanlyWithoutDaemon() async throws {
        let client = RuntimeClient(baseURL: URL(string: "http://127.0.0.1:1")!, token: "t")
        do {
            _ = try await client.diarizationStatus()
            XCTFail("unreachable daemon must fail")
        } catch let RuntimeClient.Failure.transport(message) {
            XCTAssertTrue(message.contains("cannot reach"), message)
        }
    }

    func testClientDiarizeWireFormatAgainstLocalStubServer() async throws {
        // Real loopback HTTP: proves diarize() sends Bearer auth, POST path and
        // the exact body the Router accepts (mode/segments/offset/base64 WAV).
        let stub = try StubHTTPServer.start { request in
            XCTAssertEqual(request.path, "/v1/audio/diarization")
            XCTAssertEqual(request.headers["authorization"], "Bearer test-token")
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            XCTAssertEqual(body["mode"] as? String, "nemotron")
            XCTAssertEqual(body["system_audio_offset_ms"] as? Int, 1000)
            XCTAssertEqual((body["segments"] as? [[String: Any]])?.count, 3)
            XCTAssertTrue(body["system_audio_base64"] is String)
            return (try? JSONSerialization.data(withJSONObject: [
                "mode": "nemotron", "segments": [], "turns": []])) ?? Data()
        }
        defer { stub.stop() }
        let client = RuntimeClient(baseURL: stub.baseURL, token: "test-token")
        let payload = try await client.diarize(
            segments: segments, mode: "nemotron", systemWAV: stubWAV(), systemAudioOffsetMs: 1000)
        XCTAssertEqual(payload["mode"] as? String, "nemotron")
    }
}

/// One-shot loopback HTTP stub: one request per connection, `Content-Length`
/// framing, canned JSON answers. Only used by client wire-format tests.
final class StubHTTPServer: @unchecked Sendable {
    private(set) var baseURL: URL!
    private let listener: NWListener
    private let answer: @Sendable (HTTPRequest) -> Data

    static func start(answer: @escaping @Sendable (HTTPRequest) -> Data) throws -> StubHTTPServer {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let stub = StubHTTPServer(listener: listener, answer: answer)
        let ready = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "stub-http")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw NSError(domain: "stub-http", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no port"])
        }
        stub.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        return stub
    }

    private init(listener: NWListener, answer: @escaping @Sendable (HTTPRequest) -> Data) {
        self.listener = listener
        self.answer = answer
        let queue = DispatchQueue(label: "stub-http", attributes: .concurrent)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: queue)
            self.read(connection, into: Data())
        }
    }

    func stop() { listener.cancel() }

    private func read(_ connection: NWConnection, into buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil else { connection.cancel(); return }
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.read(connection, into: buffer) }
                return
            }
            let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first ?? ""
            lines.removeFirst()
            var contentLength = 0
            var headers: [String: String] = [:]
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key == "content-length" { contentLength = Int(value) ?? 0 }
                headers[key] = value
            }
            let available = buffer.distance(from: headEnd.upperBound, to: buffer.endIndex)
            guard available >= contentLength else {
                self.read(connection, into: buffer)
                return
            }
            let body = buffer.subdata(
                in: headEnd.upperBound..<buffer.index(headEnd.upperBound, offsetBy: contentLength))
            let parts = requestLine.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let path = target.split(separator: "?").first.map(String.init) ?? target
            let response = self.answer(HTTPRequest(
                method: parts.first.map(String.init) ?? "GET", path: path,
                query: [:], headers: headers, body: body))
            var out = Data("HTTP/1.1 200 OK\r\nContent-Length: \(response.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(response)
            connection.send(content: out, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
