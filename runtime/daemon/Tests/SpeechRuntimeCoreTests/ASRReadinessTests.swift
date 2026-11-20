import Foundation
import XCTest
@testable import SpeechRuntimeCore

final class ASRReadinessTests: XCTestCase {
    private var directory: URL!
    private var worker: WorkerClient?

    override func tearDown() async throws {
        await worker?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func startWorker() async throws -> Router {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("worker")
        let script = #"""
        #!/bin/sh
        cd "${0%/*}" || exit 1
        loaded=false
        while IFS= read -r line; do
            id=${line#*'"id":'}; id=${id%%[!0-9]*}
            op=${line#*'"op":"'}; op=${op%%\"*}
            printf '%s\n' "$op" >> calls
            type=ok
            case $op in
                load)
                    (
                        i=0
                        while [ ! -f release-load ] && [ "$i" -lt 500 ]; do sleep .01; i=$((i+1)); done
                        printf '{"type":"ok","id":%s,"result":{"loaded":"alpha","device":"ane","load_ms":12}}\n' "$id"
                    ) &
                    loaded=loading
                    continue
                    ;;
                unload) loaded=false; result='{"unloaded":"alpha"}' ;;
                stats)
                    rows='[]'
                    if [ "$loaded" != false ] && [ -f release-load ]; then
                        rows='[{"model":"alpha","loaded":true,"device":"ane"}]'
                    fi
                    result='{"sessions":0,"ending_sessions":0,"memory":{},"models":'"$rows"'}'
                    ;;
                transcribe|session_open)
                    if [ "$loaded" = false ] || [ ! -f release-load ]; then
                        type=error; message='cold model'
                    elif [ "$op" = session_open ]; then
                        session=${line#*'"session":"'}; session=${session%%\"*}
                        result='{"session_open":"'"$session"'"}'
                    else
                        if [ -f crash ]; then
                            [ "$(cat crash)" != once ] || rm crash
                            exit 42
                        fi
                        case $line in *'"language":"fail"'*) type=error; message='invalid model language';; esac
                        result='{"text":"ready","asr_ms":1,"queue_ms":0,"tokens":[]}'
                    fi
                    ;;
                *) type=error; message='unexpected operation' ;;
            esac
            if [ "$type" = ok ]; then
                printf '{"type":"ok","id":%s,"result":%s}\n' "$id" "$result"
            else
                printf '{"type":"error","id":%s,"message":"%s"}\n' "$id" "$message"
            fi
        done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = WorkerClient(workerPath: executable.path) { _ in }
        worker = client
        try await client.start()
        let config = RuntimeConfig(jsonObject: ["models": ["alpha": ["path": "/model", "backend": "ane"]]])
        return Router(token: AuthToken(value: "test"), worker: client, config: { config }, idle: IdlePolicy(), log: { _ in })
    }

    private func calls() -> [Substring] {
        let text = try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)
        return (text ?? "").split(separator: "\n")
    }

    private func request(_ path: String, method: String = "POST", language: String? = nil) -> HTTPRequest {
        let audio = path == "/v1/audio/transcriptions"
        var query = audio ? ["model": "alpha", "priority": "interactive"] : [:]
        query["language"] = language
        return HTTPRequest(method: method, path: path, query: query,
                           headers: ["authorization": "Bearer test", "x-sample-format": "s16le"],
                           body: audio ? Data([0, 0]) : Data(#"{"model":"alpha"}"#.utf8))
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testConcurrentColdRequestsShareLoadAndPublishLoading() async throws {
        let router = try await startWorker()
        let release = directory.appendingPathComponent("release-load")
        // Always unblock the fake load on an assertion or thrown decoding error.
        defer { try? Data().write(to: release) }
        let warm = Task { await router.handle(request("/v1/models/load")) }
        let deadline = Date().addingTimeInterval(2)
        while !calls().contains("load"), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(calls().contains("load"))
        let oneShot = Task { await router.handle(request("/v1/audio/transcriptions")) }
        let stream = Task { await router.handle(request("/v1/streams")) }
        let modelList = try await json(router.handle(request("/v1/models", method: "GET")))
        let health = try await json(router.handle(request("/health", method: "GET")))
        let unload = await router.handle(request("/v1/models/unload"))
        XCTAssertEqual(unload.status, 400)
        for source in [modelList, try XCTUnwrap(health["worker"] as? [String: Any])] {
            let row = try XCTUnwrap((source["models"] as? [[String: Any]])?.first)
            XCTAssertEqual(row["model"] as? String, "alpha")
            XCTAssertEqual(row["loading"] as? Bool, true)
            XCTAssertEqual(row["loaded"] as? Bool, false)
        }
        try Data().write(to: release)
        let responses = await [warm.value, oneShot.value, stream.value]
        XCTAssertEqual(responses.map(\.status), [200, 200, 200])
        let beforeHot = calls()
        XCTAssertEqual(beforeHot.filter { $0 == "load" }.count, 1)
        XCTAssertFalse(beforeHot.contains("unload"), "an unload must not overtake a cold load")
        let hot = await router.handle(request("/v1/audio/transcriptions"))
        XCTAssertEqual(hot.status, 200)
        XCTAssertEqual(Array(calls().dropFirst(beforeHot.count)), ["transcribe"])
    }

    func testOneShotRetriesOnlyOnRestartAndAtMostOnce() async throws {
        let router = try await startWorker()
        try Data().write(to: directory.appendingPathComponent("release-load"))
        let crash = directory.appendingPathComponent("crash")
        try Data("once".utf8).write(to: crash)
        let recovered = await router.handle(request("/v1/audio/transcriptions"))
        XCTAssertEqual(recovered.status, 200)
        XCTAssertEqual(try json(recovered)["text"] as? String, "ready")
        XCTAssertEqual(calls(), ["load", "transcribe", "load", "transcribe"])

        let failed = await router.handle(request("/v1/audio/transcriptions", language: "fail"))
        XCTAssertEqual(failed.status, 400)
        XCTAssertEqual(try json(failed)["error"] as? String, "invalid model language")
        XCTAssertEqual(calls().count, 5)

        try Data("always".utf8).write(to: crash)
        let crashed = await router.handle(request("/v1/audio/transcriptions"))
        XCTAssertNotEqual(crashed.status, 200)
        XCTAssertEqual(Array(calls().dropFirst(5)), ["transcribe", "load", "transcribe"])
    }
}
