import Foundation
import XCTest
@testable import SpeechRuntimeCore

final class DiarizationTests: XCTestCase {
    private let words: [[String: Any]] = [
        ["source": "mic", "start_ms": 100, "end_ms": 300, "text": "Кубернетес"],
        ["source": "system", "start_ms": 400, "end_ms": 700, "text": "Kubernetes"],
        ["source": "system", "start_ms": 1000, "end_ms": 1300, "text": "PostgreSQL"],
    ]

    // MARK: - annotate

    func testSourceModeKeepsWordsAndTimesUntouched() throws {
        let result = try Diarization.annotate(words, mode: .source)
        XCTAssertEqual(result.map { $0["speaker_id"] as? String }, ["local", "remote", "remote"])
        for (original, labeled) in zip(words, result) {
            XCTAssertEqual(original["text"] as? String, labeled["text"] as? String)
            XCTAssertEqual(original["start_ms"] as? Int, labeled["start_ms"] as? Int)
            XCTAssertEqual(original["end_ms"] as? Int, labeled["end_ms"] as? Int)
            XCTAssertEqual(original["source"] as? String, labeled["source"] as? String)
        }
    }

    func testNemotronLabelsOnlySystemAudioWithoutRetranscribing() throws {
        let turns = [
            Diarization.Turn(speaker: 1, startMs: 400, endMs: 800),
            Diarization.Turn(speaker: 2, startMs: 900, endMs: 1400),
        ]
        let result = try Diarization.annotate(words, mode: .nemotron, turns: turns)
        XCTAssertEqual(result.map { $0["speaker_id"] as? String }, ["local", "remote:1", "remote:2"])
        XCTAssertEqual(result.map { $0["text"] as? String }, words.map { $0["text"] as? String })
    }

    func testExtraFieldsAndOrderPreserved() throws {
        let segments: [[String: Any]] = [
            ["source": "system", "start_ms": 10, "end_ms": 40, "text": "deploy",
             "confidence": 0.9, "custom": [1, 2, 3]],
        ]
        let result = try Diarization.annotate(
            segments, mode: .nemotron,
            turns: [Diarization.Turn(speaker: 3, startMs: 0, endMs: 100)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["confidence"] as? Double, 0.9)
        XCTAssertEqual((result[0]["custom"] as? [Int]) ?? [], [1, 2, 3])
        XCTAssertEqual(result[0]["speaker_id"] as? String, "remote:3")
    }

    func testSystemAudioOffsetAndTieAreStable() throws {
        let result = try Diarization.annotate(
            [["source": "system", "start_ms": 1250, "end_ms": 1450, "text": "CI/CD"]],
            mode: .nemotron,
            turns: [Diarization.Turn(speaker: 2, startMs: 200, endMs: 300),
                    Diarization.Turn(speaker: 1, startMs: 400, endMs: 500)],
            systemAudioOffsetMs: 1000
        )
        XCTAssertEqual(result[0]["speaker_id"] as? String, "remote:1")
    }

    func testNegativeSystemAudioOffset() throws {
        let result = try Diarization.annotate(
            [["source": "system", "start_ms": 150, "end_ms": 350, "text": "kubectl"]],
            mode: .nemotron,
            turns: [Diarization.Turn(speaker: 1, startMs: 1000, endMs: 1400)],
            systemAudioOffsetMs: -1000
        )
        XCTAssertEqual(result[0]["speaker_id"] as? String, "remote:1")
        XCTAssertThrowsError(try Diarization.annotate(
            [[:]], mode: .source, systemAudioOffsetMs: -86_400_001))
    }

    func testMissingTurnsDoNotFabricateSpeaker() throws {
        let result = try Diarization.annotate(words, mode: .nemotron)
        XCTAssertEqual(result[0]["speaker_id"] as? String, "local")
        XCTAssertTrue(result[1]["speaker_id"] is NSNull)
        XCTAssertTrue(result[2]["speaker_id"] is NSNull)
    }

    func testNearestTurnWhenNoOverlapAndLowerSpeakerTie() throws {
        // No overlap: nearest turn wins (upstream speakers.rs gap policy).
        let result = try Diarization.annotate(
            [["source": "system", "start_ms": 3000, "end_ms": 3100, "text": "helm"]],
            mode: .nemotron,
            turns: [Diarization.Turn(speaker: 2, startMs: 0, endMs: 100),
                    Diarization.Turn(speaker: 1, startMs: 2900, endMs: 2950)])
        XCTAssertEqual(result[0]["speaker_id"] as? String, "remote:1")
        // Equal gap from two speakers: lower speaker id wins.
        let tied = try Diarization.annotate(
            [["source": "system", "start_ms": 1500, "end_ms": 1600, "text": "argo"]],
            mode: .nemotron,
            turns: [Diarization.Turn(speaker: 4, startMs: 0, endMs: 100),
                    Diarization.Turn(speaker: 2, startMs: 2000, endMs: 2100)])
        XCTAssertEqual(tied[0]["speaker_id"] as? String, "remote:2")
    }

    func testOverlappingSpeakersGoToLongestOverlap() throws {
        let result = try Diarization.annotate(
            [["source": "system", "start_ms": 0, "end_ms": 1000, "text": "docker"]],
            mode: .nemotron,
            turns: [Diarization.Turn(speaker: 2, startMs: 0, endMs: 200),
                    Diarization.Turn(speaker: 1, startMs: 100, endMs: 1000)])
        XCTAssertEqual(result[0]["speaker_id"] as? String, "remote:1")
        // Equal total overlap: lower speaker id wins.
        let tie = try Diarization.annotate(
            [["source": "system", "start_ms": 0, "end_ms": 1000, "text": "podman"]],
            mode: .nemotron,
            turns: [Diarization.Turn(speaker: 5, startMs: 0, endMs: 500),
                    Diarization.Turn(speaker: 3, startMs: 500, endMs: 1000)])
        XCTAssertEqual(tie[0]["speaker_id"] as? String, "remote:3")
    }

    /// Words with turns only for a subset: non-overlapping words still map to
    /// the nearest turn, and mapping stays linear enough for 20k words.
    func testLargeMappingStaysCorrect() throws {
        let turns = (0..<8).map { speaker in
            Diarization.Turn(speaker: speaker + 1, startMs: speaker * 25_000,
                             endMs: speaker * 25_000 + 20_000)
        }
        var segments: [[String: Any]] = []
        segments.reserveCapacity(20_000)
        for i in 0..<20_000 {
            segments.append(["source": "system", "start_ms": i * 10, "end_ms": i * 10 + 8,
                             "text": "w\(i)"])
        }
        let result = try Diarization.annotate(segments, mode: .nemotron, turns: turns)
        XCTAssertEqual(result.count, 20_000)
        // Word at 10 ms is fully inside speaker 1's turn (0...20_000).
        XCTAssertEqual(result[1]["speaker_id"] as? String, "remote:1")
        // Word at 190_000 ms is fully inside speaker 8's turn (175_000...195_000).
        XCTAssertEqual(result[19_000]["speaker_id"] as? String, "remote:8")
        // At 172_000 ms, speaker 7's turn is closer than speaker 8's.
        XCTAssertEqual(result[17_200]["speaker_id"] as? String, "remote:7")
    }

    func testRejectsUntrustedSourceAndInvalidTiming() {
        XCTAssertThrowsError(try Diarization.annotate([
            ["source": "other", "start_ms": 0, "end_ms": 10, "text": "x"]
        ], mode: .source))
        XCTAssertThrowsError(try Diarization.annotate([
            ["source": "system", "start_ms": 10, "end_ms": 10, "text": "x"]
        ], mode: .nemotron))
        XCTAssertThrowsError(try Diarization.annotate([
            ["source": "system", "start_ms": 0, "end_ms": 10]
        ], mode: .source))
        XCTAssertThrowsError(try Diarization.annotate(
            words, mode: .source, systemAudioOffsetMs: Int(1e9)))
    }

    // MARK: - parseTurns

    func testParsesWavoSixTurnsAndRejectsInvalidSpeaker() throws {
        let json = Data(#"{"turns":[{"speaker":1,"start_ms":100,"end_ms":300},{"speaker":2,"start_ms":400,"end_ms":600}]}"#.utf8)
        XCTAssertEqual(try Diarization.parseTurns(json), [
            Diarization.Turn(speaker: 1, startMs: 100, endMs: 300),
            Diarization.Turn(speaker: 2, startMs: 400, endMs: 600),
        ])
        XCTAssertThrowsError(try Diarization.parseTurns(
            Data(#"{"turns":[{"speaker":9,"start_ms":0,"end_ms":10}]}"#.utf8)))
    }

    func testTurnJSONShape() {
        let turn = Diarization.Turn(speaker: 2, startMs: 40, endMs: 90)
        let json = turn.json
        XCTAssertEqual(json["speaker_id"] as? String, "remote:2")
        XCTAssertEqual(json["source"] as? String, "system")
        XCTAssertEqual(json["start_ms"] as? Int, 40)
        XCTAssertEqual(json["end_ms"] as? Int, 90)
    }

    func testRejectsBooleanAndFloatTurnFields() {
        XCTAssertThrowsError(try Diarization.parseTurns(
            Data(#"{"turns":[{"speaker":true,"start_ms":0,"end_ms":10}]}"#.utf8)))
        XCTAssertThrowsError(try Diarization.parseTurns(
            Data(#"{"turns":[{"speaker":1,"start_ms":0.5,"end_ms":10}]}"#.utf8)))
        XCTAssertThrowsError(try Diarization.parseTurns(
            Data(#"{"turns":[{"speaker":1,"start_ms":0,"end_ms":true}]}"#.utf8)))
    }

    func testRejectsMalformedTurnsPayload() {
        XCTAssertThrowsError(try Diarization.parseTurns(Data("[]".utf8)))
        XCTAssertThrowsError(try Diarization.parseTurns(Data("not json".utf8)))
        XCTAssertThrowsError(try Diarization.parseTurns(
            Data(#"{"other":[{"speaker":1,"start_ms":0,"end_ms":10}]}"#.utf8)))
        XCTAssertThrowsError(try Diarization.parseTurns(
            Data(#"{"turns":[{"speaker":"1","start_ms":0,"end_ms":10}]}"#.utf8)))
    }

    func testEmptyTurnsIsNotAnError() throws {
        let turns = try Diarization.parseTurns(Data(#"{"turns":[]}"#.utf8))
        XCTAssertTrue(turns.isEmpty)
    }

    // MARK: - DiarizationHost

    private func makeFakeWavo(
        directory: URL,
        body: String
    ) throws -> String {
        let script = directory.appendingPathComponent("fake-wavo")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func makeModel(directory: URL) throws -> String {
        let model = directory.appendingPathComponent("model.gguf")
        try Data(repeating: 1, count: 1024).write(to: model)
        return model.path
    }

    private func withScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarization-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testIsExecutableRequiresAbsoluteRegularExecutableFile() throws {
        let directory = try withScratchDirectory()
        let binary = try makeFakeWavo(directory: directory, body: "exit 0")
        XCTAssertTrue(DiarizationHost.isExecutable(binary))
        XCTAssertFalse(DiarizationHost.isExecutable("fake-wavo"))       // relative
        XCTAssertFalse(DiarizationHost.isExecutable("/nonexistent/wavo"))
        XCTAssertFalse(DiarizationHost.isExecutable(directory.path))    // directory
        let plain = directory.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plain)
        XCTAssertFalse(DiarizationHost.isExecutable(plain.path))        // not executable
    }

    func testNemotronRunsOnlyAnExplicitSeparateExecutableAndModel() async throws {
        let directory = try withScratchDirectory()
        // The mock verifies upstream argument order: model first, audio second,
        // --json present, and a valid cpu/gpu/auto backend.
        let binary = try makeFakeWavo(directory: directory, body: """
[ "$1" = "run" ] || { echo "expected run: $1" >&2; exit 2; }
[ "$2" = "\(directory.path)/model.gguf" ] || { echo "expected model: $2" >&2; exit 2; }
[ -f "$3" ] || { echo "expected audio file: $3" >&2; exit 2; }
case "$*" in *--json*) ;; *) echo "expected --json" >&2; exit 2;; esac
printf '%s\\n' '{"turns":[{"speaker":1,"start_ms":20,"end_ms":200}]}'
""")
        let model = try makeModel(directory: directory)
        let host = DiarizationHost()
        let turns = try await host.diarize(
            wav: Data([0, 1, 2]), binary: binary, model: model, backend: "cpu")
        XCTAssertEqual(turns, [Diarization.Turn(speaker: 1, startMs: 20, endMs: 200)])
    }

    func testMissingModelFailsExplicitly() async throws {
        let directory = try withScratchDirectory()
        let binary = try makeFakeWavo(directory: directory, body: "exit 0")
        let host = DiarizationHost()
        do {
            _ = try await host.diarize(
                wav: Data([0, 1, 2]), binary: binary,
                model: directory.appendingPathComponent("missing.gguf").path,
                backend: "cpu")
            XCTFail("missing model must throw")
        } catch let error as RuntimeError {
            XCTAssertFalse(String(describing: error).contains("transcript"))
        }
        do {
            _ = try await host.diarize(
                wav: Data([0, 1, 2]), binary: binary, model: "", backend: "cpu")
            XCTFail("empty model must throw")
        } catch {}
    }

    func testMissingOrInvalidBinaryFailsExplicitly() async throws {
        let directory = try withScratchDirectory()
        let model = try makeModel(directory: directory)
        let host = DiarizationHost()
        do {
            _ = try await host.diarize(wav: Data([0, 1]), binary: "", model: model, backend: "cpu")
            XCTFail("empty binary must throw")
        } catch {}
        do {
            _ = try await host.diarize(
                wav: Data([0, 1]), binary: "/nonexistent/wavo", model: model, backend: "cpu")
            XCTFail("missing binary must throw")
        } catch {}
        do {
            _ = try await host.diarize(
                wav: Data([0, 1]), binary: "fake-wavo", model: model, backend: "cpu")
            XCTFail("relative binary must throw")
        } catch {}
        do {
            _ = try await host.diarize(
                wav: Data([0, 1]), binary: try makeFakeWavo(directory: directory, body: "exit 0"),
                model: model, backend: "metal")
            XCTFail("invalid backend must throw")
        } catch {}
    }

    func testCLIErrorMessageIsSanitized() async throws {
        let directory = try withScratchDirectory()
        let secretPath = directory.path
        let binary = try makeFakeWavo(directory: directory, body: """
echo "secret path \(secretPath) and secret transcript текст" >&2
exit 3
""")
        let model = try makeModel(directory: directory)
        let host = DiarizationHost()
        do {
            _ = try await host.diarize(wav: Data([0, 1]), binary: binary, model: model, backend: "cpu")
            XCTFail("failing CLI must throw")
        } catch let error as RuntimeError {
            let text = String(describing: error)
            XCTAssertFalse(text.contains(secretPath), "error leaks paths: \(text)")
            XCTAssertFalse(text.contains("текст"), "error leaks transcript: \(text)")
        }
    }

    func testCancellationTerminatesSubprocess() async throws {
        let directory = try withScratchDirectory()
        let binary = try makeFakeWavo(directory: directory, body: """
sleep 300
""")
        let model = try makeModel(directory: directory)
        let host = DiarizationHost()
        let task = Task {
            try await host.diarize(wav: Data([0, 1]), binary: binary, model: model, backend: "cpu")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled run must throw")
        } catch {}
    }

    func testConcurrentRunsAreRejectedNotQueued() async throws {
        let directory = try withScratchDirectory()
        let ready = directory.appendingPathComponent("ready")
        let binary = try makeFakeWavo(directory: directory, body: """
printf '%s\\n' '{"turns":[{"speaker":1,"start_ms":0,"end_ms":10}]}'
touch "\(ready.path)"
sleep 300
""")
        let model = try makeModel(directory: directory)
        let host = DiarizationHost()
        let first = Task {
            try await host.diarize(wav: Data([0, 1]), binary: binary, model: model, backend: "cpu")
        }
        // Wait until the first subprocess has actually started.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        do {
            _ = try await host.diarize(wav: Data([0, 1]), binary: binary, model: model, backend: "cpu")
            XCTFail("second concurrent run must be rejected")
        } catch is RuntimeError {}
        first.cancel()
        _ = try? await first.value
    }

    func testTemporaryFilesAreCleanedUpAfterSuccessAndFailure() async throws {
        let directory = try withScratchDirectory()
        let model = try makeModel(directory: directory)

        func tempDiarizationPaths() -> [String] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                atPath: FileManager.default.temporaryDirectory.path)) ?? []
            return contents.filter { $0.hasPrefix("speech-runtime-diarization-") }
        }

        let good = try makeFakeWavo(directory: directory, body: """
printf '%s\\n' '{"turns":[{"speaker":1,"start_ms":0,"end_ms":10}]}'
""")
        _ = try await DiarizationHost().diarize(
            wav: Data([0, 1]), binary: good, model: model, backend: "cpu")
        XCTAssertTrue(tempDiarizationPaths().isEmpty, "success leaked temp files")

        let bad = try makeFakeWavo(directory: directory, body: "exit 4")
        _ = try? await DiarizationHost().diarize(
            wav: Data([0, 1]), binary: bad, model: model, backend: "cpu")
        XCTAssertTrue(tempDiarizationPaths().isEmpty, "failure leaked temp files")
    }

    func testLargeOutputIsBoundedAndParsed() throws {
        // 20_000 turns is far beyond any real meeting (67 turns on a 172 s
        // fixture) but must parse, map and not blow up.
        var rows: [String] = []
        rows.reserveCapacity(20_000)
        for i in 0..<20_000 {
            rows.append(#"{"speaker":\#(i % 8 + 1),"start_ms":\#(i),"end_ms":\#(i + 1)}"#)
        }
        let payload = #"{"turns":[\#(rows.joined(separator: ","))]}"#
        let turns = try Diarization.parseTurns(Data(payload.utf8))
        XCTAssertEqual(turns.count, 20_000)
        XCTAssertEqual(turns.first, Diarization.Turn(speaker: 1, startMs: 0, endMs: 1))
        // Map a word into the middle of the payload.
        let annotated = try Diarization.annotate(
            [["source": "system", "start_ms": 10_000, "end_ms": 10_050, "text": "nix"]],
            mode: .nemotron, turns: turns)
        // Overlaps turn 10000 entirely; speaker is (10000 % 8) + 1 = 1... verify
        // against the rule directly instead of hardcoding arithmetic.
        let expected = 10_000 % 8 + 1
        XCTAssertEqual(annotated[0]["speaker_id"] as? String, "remote:\(expected)")
    }

    func testLockHeldDuringManagedInvocation() async throws {
        let directory = try withScratchDirectory()
        let lock = directory.appendingPathComponent("nemotron-diarization.lock")
        let binary = try makeFakeWavo(directory: directory, body: """
printf '%s\\n' '{"turns":[{"speaker":1,"start_ms":0,"end_ms":10}]}'
""")
        let model = try makeModel(directory: directory)
        let host = DiarizationHost()

        // Successful lock use: runs normally.
        let turns = try await host.diarize(
            wav: Data([0, 1]), binary: binary, model: model, backend: "cpu", lock: lock)
        XCTAssertEqual(turns.count, 1)

        // A lock already held exclusively elsewhere is refused, not bypassed.
        let holder = open(lock.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { close(holder) }
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        defer { flock(holder, LOCK_UN) }
        do {
            _ = try await host.diarize(
                wav: Data([0, 1]), binary: binary, model: model, backend: "cpu", lock: lock)
            XCTFail("contended lock must be refused")
        } catch is RuntimeError {}
    }
}

