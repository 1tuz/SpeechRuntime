import CoreFoundation
import Foundation

/// Post-transcription speaker annotation. This module does not run ASR, change text,
/// alter word timestamps, or participate in the low-latency streaming pipeline.
public enum Diarization {
    public enum Mode: String, Sendable {
        case source
        case nemotron
    }

    public struct Turn: Sendable, Equatable {
        public let speaker: Int
        public let startMs: Int
        public let endMs: Int

        public init(speaker: Int, startMs: Int, endMs: Int) {
            self.speaker = speaker
            self.startMs = startMs
            self.endMs = endMs
        }

        public var json: [String: Any] {
            ["speaker_id": "remote:\(speaker)", "source": "system",
             "start_ms": startMs, "end_ms": endMs]
        }
    }

    public static let dayMs = 86_400_000

    /// Both tracks must use the same meeting timeline. Prefer word-sized segments
    /// for Nemotron: a long sentence spanning two speakers cannot be split safely
    /// without the original word alignment.
    public static func annotate(
        _ segments: [[String: Any]],
        mode: Mode,
        turns: [Turn] = [],
        systemAudioOffsetMs: Int = 0
    ) throws -> [[String: Any]] {
        guard (-dayMs...dayMs).contains(systemAudioOffsetMs) else {
            throw RuntimeError.message("system_audio_offset_ms is out of range")
        }
        guard segments.count <= 200_000 else {
            throw RuntimeError.message("too many transcription segments")
        }
        if mode == .source || turns.isEmpty {
            return try segments.map { try labeled($0, mode: mode) }
        }
        let tracks = Dictionary(grouping: turns, by: \.speaker).mapValues(SpeakerTrack.init)
        return try segments.map { original in
            var result = try labeled(original, mode: mode)
            if result["source"] as? String == "system",
               let start = original["start_ms"] as? Int,
               let end = original["end_ms"] as? Int {
                let speaker = speakerFor(start: start - systemAudioOffsetMs,
                                         end: end - systemAudioOffsetMs, tracks: tracks)
                result["speaker_id"] = speaker.map { "remote:\($0)" as Any } ?? NSNull()
            }
            return result
        }
    }

    /// Field checks and `source`-mode labels shared by both modes; `speaker_id`
    /// stays unset for `system` words in nemotron mode so the mapping fills it.
    /// Any `speaker_id` already present in the input is replaced.
    private static func labeled(
        _ original: [String: Any],
        mode: Mode
    ) throws -> [String: Any] {
        guard let source = original["source"] as? String,
              source == "mic" || source == "system" else {
            throw RuntimeError.message("segment requires source mic or system")
        }
        guard let start = jsonInteger(original["start_ms"]),
              let end = jsonInteger(original["end_ms"]) else {
            throw RuntimeError.message("segment start_ms and end_ms must be integers")
        }
        guard start >= 0, end > start, end <= dayMs else {
            throw RuntimeError.message("segment has an invalid start_ms/end_ms range")
        }
        guard original["text"] is String else {
            throw RuntimeError.message("segment requires text")
        }
        var result = original
        if source == "mic" {
            result["speaker_id"] = "local"
        } else if mode == .source {
            result["speaker_id"] = "remote"
        } else {
            result["speaker_id"] = NSNull()
        }
        return result
    }

    public static func parseTurns(_ data: Data) throws -> [Turn] {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            throw RuntimeError.message("Wavo did not return a turns JSON object")
        }
        guard let object = object as? [String: Any],
              let rows = object["turns"] as? [[String: Any]] else {
            throw RuntimeError.message("Wavo did not return a turns JSON object")
        }
        guard rows.count <= 100_000 else {
            throw RuntimeError.message("too many diarization turns")
        }
        return try rows.map { row in
            func integer(_ key: String) throws -> Int {
                guard let value = jsonInteger(row[key]) else {
                    throw RuntimeError.message("Wavo diarization turn \(key) must be an integer")
                }
                return value
            }
            let speaker = try integer("speaker")
            let start = try integer("start_ms")
            let end = try integer("end_ms")
            guard (1...8).contains(speaker), start >= 0, end > start, end <= dayMs else {
                throw RuntimeError.message("invalid Wavo diarization turn")
            }
            return Turn(speaker: speaker, startMs: start, endMs: end)
        }
    }

    private static func jsonInteger(_ raw: Any?) -> Int? {
        guard let raw, CFGetTypeID(raw as AnyObject) != CFBooleanGetTypeID() else { return nil }
        return raw as? Int
    }

    /// The speaker whose turns overlap `start..<end` most, the lower one on a tie;
    /// else the speaker of the nearest turn. Mirrors upstream `wavo` 0.6
    /// `Transcript::utterances` (`src/speakers.rs`), where speakers are bounded
    /// by the diarization model (CLI JSON reports 1-based, at most 8).
    private static func speakerFor(start: Int, end: Int, tracks: [Int: SpeakerTrack]) -> Int? {
        tracks.map { speaker, track in
            let score = track.score(start: start, end: end)
            return (speaker: speaker, overlap: score.overlap, distance: score.distance)
        }.min {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.speaker < $1.speaker
        }?.speaker
    }
}

/// Disjoint intervals and cumulative duration per speaker give two binary searches per word.
private struct SpeakerTrack {
    private struct Interval {
        let start: Int
        var end: Int
        let elapsed: Int
    }

    private var intervals: [Interval] = []

    init(_ turns: [Diarization.Turn]) {
        for turn in turns.sorted(by: { $0.startMs < $1.startMs }) {
            if let last = intervals.last {
                if turn.startMs <= last.end {
                    intervals[intervals.count - 1].end = max(last.end, turn.endMs)
                    continue
                }
                intervals.append(Interval(start: turn.startMs, end: turn.endMs,
                                          elapsed: last.elapsed + last.end - last.start))
            } else {
                intervals.append(Interval(start: turn.startMs, end: turn.endMs, elapsed: 0))
            }
        }
    }

    func score(start: Int, end: Int) -> (overlap: Int, distance: Int) {
        let left = firstStart(atOrAfter: start)
        let right = firstStart(atOrAfter: end)
        let overlap = duration(before: end, index: right) - duration(before: start, index: left)
        if overlap > 0 { return (overlap, 0) }
        let previous = left > 0 ? start - intervals[left - 1].end : Int.max
        let next = right < intervals.count ? intervals[right].start - end : Int.max
        return (0, min(previous, next))
    }

    private func duration(before time: Int, index: Int) -> Int {
        guard index > 0 else { return 0 }
        let interval = intervals[index - 1]
        return interval.elapsed + min(time, interval.end) - interval.start
    }

    private func firstStart(atOrAfter time: Int) -> Int {
        var low = 0, high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].start < time { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// One on-demand Wavo 0.6 diarization subprocess at a time. The resident
/// wavo 0.4 ASR worker is never reconfigured, unloaded or addressed here.
public actor DiarizationHost {
    /// Hard ceiling on one Nemotron run: a long meeting still ends, and a hung
    /// process is escalated from SIGTERM to SIGKILL before the request dies.
    public static let timeoutSeconds: TimeInterval = 570
    /// Grace after SIGTERM before SIGKILL.
    private static let termGraceSeconds: TimeInterval = 10
    /// Output above this many bytes is treated as a runaway child and stopped.
    private static let maxOutputBytes = 32 * 1024 * 1024

    private var busy = false

    public init() {}

    public static nonisolated func isExecutable(_ path: String) -> Bool {
        Self.isRegularExecutable(path)
    }

    public static nonisolated func isModelAvailable(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0).map { $0 > 0 } ?? false
    }

    private static nonisolated func isRegularExecutable(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        return true
    }

    /// `wav` is a complete WAV file; `binary` an absolute executable; `model` a
    /// local GGUF file; `lock`, when the assets are managed by the installer,
    /// is the sibling `nemotron-diarization.lock` held (LOCK_EX|LOCK_NB) for the
    /// whole invocation so a publish or remove cannot race the subprocess.
    public func diarize(
        wav: Data,
        binary: String,
        model: String,
        backend: String,
        lock: URL? = nil
    ) async throws -> [Diarization.Turn] {
        guard !busy else { throw RuntimeError.message("diarization is already running") }
        busy = true
        defer { busy = false }

        guard Self.isRegularExecutable(binary) else {
            throw RuntimeError.message("Nemotron requires an executable Wavo 0.6 binary")
        }
        guard !model.isEmpty, model.hasPrefix("/"), model.hasSuffix(".gguf") else {
            throw RuntimeError.message("Nemotron requires a diarization.model GGUF path")
        }
        guard Self.isModelAvailable(model) else {
            throw RuntimeError.message("Nemotron diarization model is missing")
        }
        guard ["cpu", "gpu", "auto"].contains(backend) else {
            throw RuntimeError.message("diarization.backend must be cpu, gpu or auto")
        }

        // Model path is explicit: run reads the local GGUF directly (no downloads).
        return try await withLock(at: lock) {
            try await Self.run(wav: wav, binary: binary, model: model, backend: backend)
        }
    }

    /// Holds `LOCK_EX|LOCK_NB` on the managed asset lock for the duration of `body`.
    /// A lock currently held by a publish/remove fails fast instead of queueing,
    /// and a configured lock is never bypassed: an unusable lock file is an error.
    private func withLock<T: Sendable>(at url: URL?, _ body: @Sendable () async throws -> T) async throws -> T {
        guard let url else { return try await body() }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw RuntimeError.message("could not open the diarization asset lock")
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw RuntimeError.message("diarization assets are being updated")
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    private nonisolated static func run(
        wav: Data,
        binary: String,
        model: String,
        backend: String
    ) async throws -> [Diarization.Turn] {
        // Private directory, removed however the run ends.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-runtime-diarization-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let wavPath = root.appendingPathComponent("audio.wav")
            guard FileManager.default.createFile(
                atPath: wavPath.path, contents: wav, attributes: [.posixPermissions: 0o600]
            ) else {
                throw RuntimeError.message("could not create temporary diarization audio")
            }

            // stdout to a regular file: no reader task, no pipe buffer limit, and
            // a growing output is visible while the process runs. stderr is null:
            // CLI diagnostics never leave the child process.
            let outputPath = root.appendingPathComponent("turns.json")
            guard FileManager.default.createFile(
                atPath: outputPath.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else {
                throw RuntimeError.message("could not create temporary diarization output")
            }
            let outputFD = open(outputPath.path, O_WRONLY)
            guard outputFD >= 0 else {
                throw RuntimeError.message("could not open temporary diarization output")
            }
            let outputHandle = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            // Upstream 0.6 `run`: model path first, audio second, `--json` prints
            // {"turns":[...]} with 1-based speakers; a local .gguf path is read
            // directly, so nothing is downloaded and `-y` is not needed.
            process.arguments = ["run", model, wavPath.path, "--json", "--backend", backend]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputHandle
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                throw RuntimeError.message("could not launch Wavo diarization")
            }

            // Bounded lifetime: the deadline, and cancellation of the caller's
            // task, both SIGTERM the subprocess and SIGKILL a survivor after the
            // grace period; output beyond the cap ends the run as a timeout.
            do {
                try await poll(process: process, outputPath: outputPath)
            } catch is CancellationError {
                await Self.terminate(process)
                throw CancellationError()
            } catch {
                await Self.terminate(process)
                throw RuntimeError.message("Wavo diarization timed out")
            }
            guard process.terminationReason == .exit else {
                throw RuntimeError.message("Wavo diarization was terminated")
            }
            guard process.terminationStatus == 0 else {
                throw RuntimeError.message(
                    "Wavo Nemotron failed (status \(process.terminationStatus))")
            }
            let reader = try FileHandle(forReadingFrom: outputPath)
            defer { try? reader.close() }
            guard let output = try reader.read(upToCount: maxOutputBytes + 1),
                  output.count <= maxOutputBytes else {
                throw RuntimeError.message("Wavo diarization output is too large")
            }
            return try Diarization.parseTurns(output)
        } catch let error as RuntimeError {
            throw error
        } catch is CancellationError {
            throw RuntimeError.message("diarization was cancelled")
        } catch {
            throw RuntimeError.message("Wavo diarization did not finish cleanly")
        }
    }

    /// Polls the subprocess while honoring the caller's task cancellation and the
    /// deadline; checks the output size with `stat` so a runaway child is stopped.
    private nonisolated static func poll(
        process: Process,
        outputPath: URL
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while true {
            try Task.checkCancellation()
            guard process.isRunning else { return }
            if ContinuousClock.now > deadline { throw DiarizationDeadline() }
            var st = stat()
            if stat(outputPath.path, &st) == 0, st.st_size > maxOutputBytes {
                throw DiarizationDeadline()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// SIGTERM, then SIGKILL after the grace period if it is ignored. Reaping
    /// happens on a detached task so this never blocks the caller's lane.
    private nonisolated static func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        await Task.detached(priority: .utility) {
            let grace = ContinuousClock.now.advanced(by: .seconds(termGraceSeconds))
            while process.isRunning, ContinuousClock.now < grace {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }.value
    }
}

private struct DiarizationDeadline: Error {}

