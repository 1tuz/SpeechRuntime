import Foundation

/// Supervises `sr-worker`: one child process that owns the models, the per-model queues and the
/// dictation endpointer. The daemon never talks to wavo directly, so a worker crash cannot take
/// the API down; the supervisor restarts it and reports the failure to the client that asked.
public actor WorkerClient {
    public struct SessionEvent: @unchecked Sendable {
        public var name: String
        public var data: [String: Any]
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var reader: Task<Void, Never>?
    private var stderrReader: Task<Void, Never>?
    private nonisolated let pending = PendingReplies()
    private var nextID: UInt64 = 1
    /// Ops whose traffic is per-audio-chunk or periodic: logging them buries real events.
    private static let highFrequency: Set<String> = ["session_audio", "stats"]
    private nonisolated let opNames = OpNames()
    private var sessionBuffers: [String: SessionEventBuffer] = [:]
    private nonisolated let waiters = WaiterTable()
    /// Sessions this daemon has already forgotten. A late event from one must be dropped rather
    /// than resurrect a buffer whose `ended` flag was already accounted for.
    private var retired = RetiredSessions()
    private let workerPath: String
    private let log: @Sendable (String) -> Void
    private var restarts = 0
    private var lastExit: Int32?
    private var startedAt = Date()
    /// Increments on every start/restart so callers can detect that a session belongs to a dead
    /// worker generation and must be reopened instead of reused.
    public private(set) var generation = 0
    /// True while the daemon itself is shutting the worker down: an intentional stop must never
    /// trigger the crash-restart path.
    private var intentionalStop = false
    private var lastStopGeneration = 0

    struct WorkerLoss: Error, CustomStringConvertible {
        let generation: Int
        let description: String
    }

    private struct Resident {
        let device: Any
        var lastUse: ContinuousClock.Instant
    }
    private var residents: [String: Resident] = [:]
    private var loads: [String: Task<[String: Any], Error>] = [:]
    private var unloads: [String: Task<[String: Any], Error>] = [:]
    // A timeout stops waiting, not the worker mutation. Keep its slot until the wire reply.
    private var mutations: Set<String> = []
    private var mutationModels: [UInt64: (model: String, loading: Bool)] = [:]
    private var modelUses: [String: Int] = [:]

    static let loadTimeout: TimeInterval = 180
    static let unloadTimeout: TimeInterval = 30
    static let transcribeTimeout: TimeInterval = 300
    static let openTimeout: TimeInterval = 10
    static let transcribeBudget: TimeInterval = 565

    public init(workerPath: String, log: @escaping @Sendable (String) -> Void) {
        self.workerPath = workerPath
        self.log = log
    }

    public var pid: Int32? { process?.processIdentifier }
    public var restartCount: Int { restarts }
    public var workerLastExit: Int32? { lastExit }
    public var uptime: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Live non-session bookkeeping, exposed for `GET /health` so a leak shows up as a rising
    /// count before it shows up as memory.
    public struct Internals: Sendable {
        public var pendingReplies: Int
        public var eventWaiters: Int
        public var sessionBuffers: Int
        public var retiredSessions: Int
    }

    public func internals() -> Internals {
        Internals(
            pendingReplies: pending.count,
            eventWaiters: waiters.count,
            sessionBuffers: sessionBuffers.count,
            retiredSessions: retired.count
        )
    }

    public func start() throws {
        guard process == nil else { return }
        intentionalStop = false
        let child = Process()
        child.executableURL = URL(fileURLWithPath: workerPath)
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        child.standardInput = inPipe
        child.standardOutput = outPipe
        child.standardError = errPipe
        try child.run()
        generation += 1
        let startedGeneration = generation
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = child
        stdinPipe = inPipe
        startedAt = Date()

        // `FileHandle.bytes.lines` can hold a complete line for tens of seconds on a pipe, which
        // turns into spurious request timeouts. Read the pipe on its own thread and hand ordered
        // lines to the actor through an unbounded stream.
        let (lines, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        let stdoutHandle = outPipe.fileHandleForReading
        let thread = Thread {
            var buffer = Data()
            while true {
                // `availableData` autoreleases a chunk of up to 20 KiB and a bare Foundation
                // `Thread` pops its implicit pool only when the thread ends, so without this the
                // daemon retains one buffer per worker line for its whole lifetime. Measured:
                // +53.7 MiB per 3000 `/health` requests, flat worker (RESEARCH §3.2).
                var ended = false
                autoreleasepool {
                    let chunk = stdoutHandle.availableData
                    if chunk.isEmpty {
                        ended = true
                        return
                    }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        continuation.yield(line)
                    }
                }
                if ended { break }
            }
            continuation.finish()
        }
        thread.stackSize = 1 << 20
        thread.start()
        reader = Task { [weak self] in
            for await line in lines {
                guard let self else { return }
                await self.handle(line: line, generation: startedGeneration)
            }
            await self?.workerExited(generation: startedGeneration)
        }
        stderrReader = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in errPipe.fileHandleForReading.bytes.lines {
                    // Worker stderr is not a trusted log channel: a Rust panic prints the unwrapped
                    // payload, and any future `eprintln!` could carry transcript text. Size plus a
                    // panic marker answers "did the child complain, and how loudly" without copying
                    // the line into the daemon log.
                    let kind = line.contains("panicked at") ? "panic" : "message"
                    await self.log("worker stderr: \(kind) \(line.utf8.count) B")
                }
            } catch {}
        }
    }

    /// Exit status of a child Foundation has not necessarily reaped yet, without ever releasing
    /// a live `Process`. Both `terminationStatus` and the deallocator raise
    /// `NSInvalidArgumentException` ("task still running") while the child is unreaped, and the
    /// last reference is dropped right here — a worker `SIGKILL` used to take the daemon down
    /// through this path. A survivor is terminated and then either reaped inside a short bounded
    /// wait or handed to a background waiter that keeps the object alive until the kernel reaps it.
    static func exitStatus(of task: Process?, waitSeconds: TimeInterval = 1) -> Int32? {
        guard let task else { return nil }
        if !task.isRunning { return task.terminationStatus }
        task.terminate()
        let deadline = Date().addingTimeInterval(waitSeconds)
        while task.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if !task.isRunning { return task.terminationStatus }
        DispatchQueue.global().async { task.waitUntilExit() }
        return nil
    }

    /// Intentional shutdown: kills the child without ever arming the crash-restart path.
    public func stop() {
        intentionalStop = true
        lastStopGeneration = generation
        reader?.cancel()
        stderrReader?.cancel()
        let previous = process
        process = nil
        stdinPipe = nil
        clearReadiness()
        let code = Self.exitStatus(of: previous)
        log("worker stopped intentionally (status \(code.map(String.init) ?? "unreaped"))")
        failPending("worker stopped")
    }

    // MARK: - Protocol

    public func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await request(payload, timeout: timeout, generation: nil)
    }

    private func liveGeneration() throws -> Int {
        if let process, !process.isRunning { workerExited(generation: generation) }
        guard process != nil else { throw RuntimeError.message("worker is not running") }
        return generation
    }

    private func requireGeneration(_ expected: Int) throws {
        guard try liveGeneration() == expected else {
            throw WorkerLoss(generation: expected, description: "worker restarted")
        }
    }

    private func request(
        _ payload: [String: Any], timeout: TimeInterval, generation expected: Int?, mutation: String? = nil
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        let current = try liveGeneration()
        if let expected, current != expected {
            throw WorkerLoss(generation: expected, description: "worker restarted")
        }
        guard let stdinPipe else {
            throw RuntimeError.message("worker is not running")
        }
        let id = nextID
        nextID += 1
        var payload = payload
        payload["id"] = id
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard var line = String(data: data, encoding: .utf8) else {
            throw RuntimeError.message("cannot encode request")
        }
        line += "\n"
        let bytes = Data(line.utf8)

        let op = payload["op"] as? String ?? "?"
        let verbose = !Self.highFrequency.contains(op)
        opNames.insert(id, op)
        if verbose { log("→ [\(id)] \(op) \(bytes.count) B") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                // A cancellation that raced the registration marks the id; refuse it here so the
                // continuation is always resumed exactly once.
                guard pending.insert(id, continuation) else {
                    _ = opNames.take(id)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: bytes)
                } catch {
                    let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError ?? (error as NSError)
                    if process?.isRunning == false || (underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EPIPE)) {
                        workerExited(generation: current)
                    } else {
                        _ = opNames.take(id)
                        pending.take(id)?.resume(throwing: error)
                    }
                    return
                }
                if let mutation {
                    mutations.insert(mutation)
                    mutationModels[id] = (mutation, op == "load")
                }
                let timer = CancelableTimeout(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000)) { [weak self] in
                    guard let self else { return }
                    Task { await self.fireTimeout(id: id, seconds: timeout) }
                }
                pending.arm(id, timer)
            }
        } onCancel: {
            // The caller gave up: drop the waiter so a late reply is logged instead of resumed.
            if let abandoned = pending.abandon(id) {
                _ = opNames.take(id)
                abandoned.resume(throwing: CancellationError())
            }
        }
    }

    /// Timeout path: the timer only fires when the waiter is still registered, so a reply that
    /// won the race cancels the timer instead of racing the reply.
    private func fireTimeout(id: UInt64, seconds: TimeInterval) {
        guard let continuation = pending.take(id) else { return }
        _ = opNames.take(id)
        log("timeout [\(id)] after \(Int(seconds)) s")
        continuation.resume(throwing: RuntimeError.message("worker request timed out after \(Int(seconds)) s"))
    }

    public func ping() async throws -> [String: Any] {
        try await request(["op": "ping"], timeout: 5)
    }

    public func stats() async throws -> [String: Any] {
        try await request(["op": "stats"], timeout: 5)
    }

    public func load(model: String, path: String, backend: String? = nil) async throws -> [String: Any] {
        let generation = try liveGeneration()
        return try await usingModel(model, generation: generation) {
            try await ready(model: model, path: path, backend: backend, generation: generation)
        }
    }

    func loadingModels() -> Set<String> {
        guard process?.isRunning == true else { return [] }
        return Set(loads.keys).union(mutationModels.values.lazy.filter(\.loading).map(\.model))
    }

    private func usingModel<T>(_ model: String, generation: Int, _ body: () async throws -> T) async throws -> T {
        modelUses[model, default: 0] += 1
        defer {
            if self.generation == generation, let uses = modelUses[model] {
                modelUses[model] = uses == 1 ? nil : uses - 1
                residents[model]?.lastUse = .now
            }
        }
        return try await body()
    }

    private func ready(model: String, path: String, backend: String?, generation: Int) async throws -> [String: Any] {
        if let unload = unloads[model] {
            // A rejected unload leaves the model resident; a successful one makes it cold.
            _ = try? await unload.value
            try requireGeneration(generation)
        }
        try Task.checkCancellation()
        if let load = loads[model] { return try await load.value }
        guard !mutations.contains(model) else { throw RuntimeError.message("model \(model) mutation still pending") }
        if let resident = residents[model] {
            return ["model": model, "device": resident.device, "cached": true]
        }
        var payload: [String: Any] = ["op": "load", "model": model, "path": path]
        if let backend { payload["backend"] = backend }
        let flight = Task {
            defer { if self.generation == generation { loads[model] = nil } }
            let result = try await request(payload, timeout: Self.loadTimeout, generation: generation, mutation: model)
            try requireGeneration(generation)
            return result
        }
        loads[model] = flight
        return try await flight.value
    }

    public func unload(model: String) async throws -> [String: Any] {
        let generation = try liveGeneration()
        if let unload = unloads[model] { return try await unload.value }
        guard modelUses[model] == nil, !mutations.contains(model) else {
            throw RuntimeError.message("model \(String(reflecting: model)) is in use")
        }
        let flight = Task {
            defer { if self.generation == generation { unloads[model] = nil } }
            return try await request(["op": "unload", "model": model], timeout: Self.unloadTimeout,
                                     generation: generation, mutation: model)
        }
        unloads[model] = flight
        return try await flight.value
    }

    package func unloadIdleModels(after seconds: Int, keeping busy: Set<String>) async {
        for model in Array(residents.keys) {
            guard !Task.isCancelled else { return }
            guard !busy.contains(model), modelUses[model] == nil, unloads[model] == nil,
                  !mutations.contains(model), let resident = residents[model],
                  resident.lastUse.duration(to: .now) >= .seconds(seconds) else { continue }
            let generation = self.generation
            do {
                _ = try await unload(model: model)
                log("unloaded idle model \(model) after \(seconds) s")
            } catch {
                if self.generation == generation { residents[model]?.lastUse = .now }
                log("idle unload of \(model) failed, will retry: \(error)")
            }
        }
    }

    public func transcribe(
        pcm: [Float],
        model: String,
        language: String?,
        windowMs: Int?,
        maxChunkMs: Int? = nil,
        priority: String
    ) async throws -> [String: Any] {
        try await transcribe(pcm: pcm, model: model, language: language, windowMs: windowMs,
                             maxChunkMs: maxChunkMs, priority: priority, generation: nil, deadline: nil)
    }

    func transcribeReady(
        pcm: [Float], model: String, entry: ModelEntry, language: String?, windowMs: Int?,
        maxChunkMs: Int?, priority: String
    ) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.transcribeBudget))
        let retryReadiness = Duration.seconds(Self.loadTimeout + Self.unloadTimeout)
        for attempt in 0...1 {
            let generation = try liveGeneration()
            do {
                return try await usingModel(model, generation: generation) {
                    _ = try await ready(model: model, path: entry.path, backend: entry.backend, generation: generation)
                    return try await transcribe(pcm: pcm, model: model, language: language, windowMs: windowMs,
                                                maxChunkMs: maxChunkMs, priority: priority, generation: generation,
                                                deadline: deadline)
                }
            } catch let loss as WorkerLoss where attempt == 0 && priority == "interactive" && loss.generation == generation
                && generation > lastStopGeneration && self.generation > generation && process?.isRunning == true
                && ContinuousClock.now.duration(to: deadline) > retryReadiness {
                try Task.checkCancellation()
            }
        }
        preconditionFailure("the second attempt returns or throws")
    }

    private func transcribe(
        pcm: [Float], model: String, language: String?, windowMs: Int?, maxChunkMs: Int?, priority: String,
        generation: Int?, deadline: ContinuousClock.Instant?
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        var payload: [String: Any] = [
            "op": "transcribe",
            "model": model,
            "pcm": Self.encode(pcm),
            "priority": priority,
        ]
        if let language { payload["language"] = language }
        if let windowMs { payload["window_ms"] = windowMs }
        if let maxChunkMs { payload["max_chunk_ms"] = maxChunkMs }
        let timeout = deadline.map { min(Self.transcribeTimeout, Double(ContinuousClock.now.duration(to: $0).components.seconds)) }
            ?? Self.transcribeTimeout
        guard timeout > 0 else { throw RuntimeError.message("transcription deadline exceeded") }
        return try await request(payload, timeout: timeout, generation: generation)
    }

    public func openSession(id: String, model: String, config: [String: Any]) async throws -> [String: Any] {
        try await openSession(id: id, model: model, config: config, generation: nil)
    }

    func openReadySession(id: String, model: String, entry: ModelEntry, config: [String: Any]) async throws
        -> (result: [String: Any], generation: Int) {
        let generation = try liveGeneration()
        return try await usingModel(model, generation: generation) {
            _ = try await ready(model: model, path: entry.path, backend: entry.backend, generation: generation)
            let result = try await openSession(id: id, model: model, config: config, generation: generation)
            try requireGeneration(generation)
            if sessionBuffers[id] == nil { sessionBuffers[id] = SessionEventBuffer() }
            return (result, generation)
        }
    }

    private func openSession(id: String, model: String, config: [String: Any], generation: Int?) async throws -> [String: Any] {
        // The client may reuse an id that this daemon already forgot; it is a fresh session then.
        retired.revive(id)
        return try await request(["op": "session_open", "session": id, "model": model, "config": config],
                                 timeout: Self.openTimeout, generation: generation)
    }

    public func sessionAudio(id: String, pcm: [Float]) async throws {
        _ = try await request(["op": "session_audio", "session": id, "pcm": Self.encode(pcm)], timeout: 30)
    }

    public func endSession(id: String) async throws -> [String: Any] {
        try await request(["op": "session_end", "session": id], timeout: 10)
    }

    public func cancelSession(id: String) async throws {
        _ = try await request(["op": "session_cancel", "session": id], timeout: 10)
    }

    /// Ends the session and blocks until the worker has emitted `ended` for it (which also means
    /// every job has produced its engine response). Throws when the wait times out.
    public func endSessionAndWait(id: String, timeout: TimeInterval = 120) async throws -> [String: Any] {
        let result = try await endSession(id: id)
        cleanup()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if sessionBuffers[id]?.ended == true {
                cleanup()
                return result
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw RuntimeError.message("session \(id) did not end within \(Int(timeout)) s")
            }
            _ = await pollEvents(session: id, since: sessionBuffers[id]?.totalCount ?? 0, timeout: min(remaining, 5))
        }
    }

    /// Drops a session's buffered events without waiting; used by cancel and error paths. The id is
    /// remembered so a late event from the dying worker cannot recreate the buffer.
    public func forgetSession(_ id: String) {
        sessionBuffers.removeValue(forKey: id)
        retired.retire(id)
    }

    /// Reaps ended sessions past their retention window. Called from poll/health paths.
    public func cleanup() {
        let now = Date()
        for (session, buffer) in sessionBuffers where buffer.isExpired(now: now) {
            sessionBuffers.removeValue(forKey: session)
            retired.retire(session, now: now)
        }
        retired.prune(now: now)
    }

    /// Returns buffered events after `since`. Waits up to `timeout` for the first one.
    public func pollEvents(session: String, since: Int, timeout: TimeInterval) async -> (events: [SessionEvent], next: Int) {
        cleanup()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let buffer = sessionBuffers[session] {
                let (events, next) = buffer.slice(since: since)
                if !events.isEmpty || buffer.ended { return (events, next) }
            } else if since > 0 || retired.contains(session) {
                // Forgotten (cancel/crash-reaped) session: report the cursor we have.
                return ([], since)
            }
            if timeout <= 0 { return ([], since) }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return ([], since) }
            // Cap the number of parked long polls: each one holds a continuation for up to
            // `remaining` seconds, and a buggy client could otherwise pin thousands of them.
            if waiters.isFull { return ([], since) }
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard let waiter = waiters.add(session: session, continuation: continuation) else {
                    continuation.resume()  // raced to the cap: fall back to the loop's re-check
                    return
                }
                let seconds = max(remaining, 0.001)
                let timer = CancelableTimeout(nanoseconds: UInt64(seconds * 1_000_000_000)) { [weak self] in
                    guard let self else { return }
                    Task { await self.expireWaiter(waiter) }
                }
                waiters.arm(waiter, timer)
            }
        }
    }

    private func expireWaiter(_ id: UInt64) {
        waiters.expire(id)
    }

    /// Wakes parked long polls: one session's event must not wake clients of other sessions.
    private func wakeWaiters(session: String? = nil) {
        waiters.wake(session: session)
    }

    private func handle(line: String, generation: Int) {
        guard generation == self.generation, process != nil else { return }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            // Never echo a worker line into the log: it can carry transcript text.
            log("worker sent unparsable line: \(line.utf8.count) B")
            return
        }

        switch type {
        case "ok", "error":
            if let id = (object["id"] as? NSNumber)?.uint64Value,
               let (model, loading) = mutationModels.removeValue(forKey: id) {
                mutations.remove(model)
                if type == "ok", let result = object["result"] as? [String: Any] {
                    if loading {
                        residents[model] = Resident(device: result["device"] ?? NSNull(), lastUse: .now)
                    } else {
                        residents[model] = nil
                    }
                }
            }
            guard let id = (object["id"] as? NSNumber)?.uint64Value,
                  let continuation = pending.take(id)
            else {
                // Metadata only: a late or duplicated reply must not leak its payload to the log.
                let id = (object["id"] as? NSNumber)?.uint64Value ?? 0
                log("worker reply without waiter: type=\(type) id=\(id) bytes=\(line.utf8.count)")
                return
            }
            if let op = opNames.take(id), !Self.highFrequency.contains(op) {
                log("← [\(id)] \(type)")
            }
            if type == "error" {
                continuation.resume(throwing: RuntimeError.message(object["message"] as? String ?? "worker error"))
            } else {
                continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
            }
        case "event":
            guard let session = object["session"] as? String,
                  let name = object["event"] as? String
            else { return }
            if retired.contains(session) {
                // Ids are client- and worker-controlled strings; keep them bounded and never
                // print the event payload next to them.
                log("dropped late event for retired session=\(session.prefix(64)) event=\(name.prefix(32))")
                return
            }
            var payload = object
            payload.removeValue(forKey: "type")
            payload.removeValue(forKey: "session")
            payload.removeValue(forKey: "event")
            sessionBuffers[session, default: SessionEventBuffer()].append(SessionEvent(name: name, data: payload))
            wakeWaiters(session: session)
        default:
            log("worker sent unknown message type: \(type.prefix(40))")
        }
    }

    /// Crash path: fail in-flight requests, tell every live session its stream is dead (error +
    /// ended), bump the generation and bring a fresh worker up. An intentional `stop()` never
    /// comes through here.
    private func workerExited(generation: Int) {
        guard generation == self.generation, process != nil, !intentionalStop else { return }
        reader?.cancel()
        stderrReader?.cancel()
        let previous = process
        process = nil
        stdinPipe = nil
        clearReadiness()
        // The pipe closed, so the child is dead or dying; reap it before the reference is dropped
        // (see `exitStatus(of:)`). The exact status is only echoed after it is safe to read.
        let code = Self.exitStatus(of: previous) ?? lastExit ?? -1
        lastExit = code
        for id in pending.failAll(WorkerLoss(generation: generation, description: "worker exited with status \(code)")) {
            _ = opNames.take(id)
        }
        for (session, buffer) in sessionBuffers where !buffer.ended {
            var dead = buffer
            dead.append(SessionEvent(name: "error", data: ["message": "worker exited with status \(code)"]))
            dead.append(SessionEvent(name: "ended", data: ["utterances": 0, "failed": 0]))
            sessionBuffers[session] = dead
        }
        wakeWaiters()
        log("worker exited with status \(code)")
        restarts += 1
        do {
            try start()
            log("worker restarted")
        } catch {
            log("worker restart failed: \(error)")
        }
    }


    private func clearReadiness() {
        residents.removeAll()
        loads.removeAll()
        unloads.removeAll()
        mutations.removeAll()
        mutationModels.removeAll()
        modelUses.removeAll()
    }

    private func failPending(_ message: String) {
        for id in pending.failAll(RuntimeError.message(message)) { _ = opNames.take(id) }
    }

    public static func encode(_ pcm: [Float]) -> String {
        var data = Data(capacity: pcm.count * 4)
        for sample in pcm {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }
}

/// Replies are matched on the caller's thread so a reply can never race the registration of the
/// continuation that is waiting for it. Each entry owns its timeout task, so a reply cancels the
/// timer instead of leaving a stray task asleep for the whole timeout window.
final class PendingReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [UInt64: Entry] = [:]
    /// Ids whose caller was cancelled before the registration landed. Bounded: entries are
    /// consumed by `insert` or by a late `take`.
    private var cancelled: Set<UInt64> = []

    private struct Entry {
        var continuation: CheckedContinuation<[String: Any], Error>
        var timer: CancelableTimeout?
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }

    /// False when the caller already cancelled: the continuation must be resumed by the caller.
    func insert(_ id: UInt64, _ continuation: CheckedContinuation<[String: Any], Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled.remove(id) != nil { return false }
        map[id] = Entry(continuation: continuation, timer: nil)
        return true
    }

    /// Arms the timeout after registration. A reply that raced the registration cancels the timer
    /// immediately instead of leaving a live task behind.
    func arm(_ id: UInt64, _ timer: CancelableTimeout) {
        lock.lock()
        let entry = map[id]
        if map[id] != nil { map[id]!.timer = timer }
        lock.unlock()
        if entry == nil { timer.cancel() }
    }

    func take(_ id: UInt64) -> CheckedContinuation<[String: Any], Error>? {
        lock.lock()
        let entry = map.removeValue(forKey: id)
        cancelled.remove(id)
        lock.unlock()
        entry?.timer?.cancel()
        return entry?.continuation
    }

    /// Cancellation path: returns the waiter to resume, or marks the id for a registration that
    /// has not landed yet.
    func abandon(_ id: UInt64) -> CheckedContinuation<[String: Any], Error>? {
        lock.lock()
        let entry = map.removeValue(forKey: id)
        if entry == nil, cancelled.count < 4096 { cancelled.insert(id) }
        lock.unlock()
        entry?.timer?.cancel()
        return entry?.continuation
    }

    func failAll(_ message: String) {
        _ = failAll(RuntimeError.message(message))
    }

    func failAll(_ error: Error) -> [UInt64] {
        lock.lock()
        let waiting = map
        map.removeAll()
        cancelled.removeAll()
        lock.unlock()
        for (_, entry) in waiting {
            entry.timer?.cancel()
            entry.continuation.resume(throwing: error)
        }
        return Array(waiting.keys)
    }
}

/// One-shot timer whose cancellation is guaranteed not to fall through into the timeout action.
/// `Task.sleep` throws on cancellation, so a cancelled timer's action never runs.
final class CancelableTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var fired = false

    init(nanoseconds: UInt64, action: @escaping @Sendable () -> Void) {
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, self.claim() else { return }
            action()
        }
    }

    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}

/// Parked long polls, keyed by session so an event for one session does not wake every client, and
/// bounded so abandoned polls cannot pin unbounded continuations.
final class WaiterTable: @unchecked Sendable {
    let cap: Int
    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private var next: UInt64 = 1

    private struct Entry {
        let session: String
        var continuation: CheckedContinuation<Void, Never>
        var timer: CancelableTimeout?
    }

    init(cap: Int = 256) {
        self.cap = cap
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    var isFull: Bool { count >= cap }

    /// Registers a waiter; returns nil when the table is at its cap (caller must resume at once).
    func add(session: String, continuation: CheckedContinuation<Void, Never>) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard entries.count < cap else { return nil }
        let id = next
        next += 1
        entries[id] = Entry(session: session, continuation: continuation, timer: nil)
        return id
    }

    func arm(_ id: UInt64, _ timer: CancelableTimeout) {
        lock.lock()
        let known = entries[id] != nil
        if known { entries[id]!.timer = timer }
        lock.unlock()
        if !known { timer.cancel() }
    }

    /// Wakes waiters for one session, or all of them when `session` is nil.
    func wake(session: String?) {
        lock.lock()
        var woken: [Entry] = []
        for (id, entry) in entries where session == nil || entry.session == session {
            woken.append(entry)
            entries.removeValue(forKey: id)
        }
        lock.unlock()
        for entry in woken {
            entry.timer?.cancel()
            entry.continuation.resume()
        }
    }

    /// Timer path: the waiter must be released even though no event arrived.
    func expire(_ id: UInt64) {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        entry?.timer?.cancel()
        entry?.continuation.resume()
    }
}

/// Session ids this daemon has already forgotten. Late events from a retired session are dropped:
/// a recreated buffer would never be reaped, because its `ended` event had already been consumed.
struct RetiredSessions {
    static let ttl: TimeInterval = 900
    static let cap = 4096

    private var retired: [String: Date] = [:]

    var count: Int { retired.count }

    mutating func retire(_ id: String, now: Date = Date()) {
        retired[id] = now
        prune(now: now)
    }

    mutating func revive(_ id: String) {
        retired.removeValue(forKey: id)
    }

    func contains(_ id: String) -> Bool {
        retired[id] != nil
    }

    /// Keeps the table bounded and drops ids old enough that no worker event can still arrive.
    mutating func prune(now: Date = Date()) {
        for (id, at) in retired where now.timeIntervalSince(at) >= Self.ttl {
            retired.removeValue(forKey: id)
        }
        guard retired.count > Self.cap else { return }
        let ordered = retired.sorted { $0.value < $1.value }
        for (id, _) in ordered.prefix(ordered.count - Self.cap) {
            retired.removeValue(forKey: id)
        }
    }
}

/// Bounded per-session event history: at most `cap` events are retained and an ended session is
/// reaped after `endedTTL`. Pure bookkeeping, so it is unit-tested directly.
struct SessionEventBuffer {
    static let cap = 20_000
    static let endedTTL: TimeInterval = 300

    private(set) var events: [WorkerClient.SessionEvent] = []
    private(set) var ended = false
    private(set) var endedAt: Date?

    /// Events dropped by the cap; `since` cursors below this index can no longer be honored.
    private(set) var droppedCount = 0

    var totalCount: Int { droppedCount + events.count }

    mutating func append(_ event: WorkerClient.SessionEvent) {
        events.append(event)
        if events.count > Self.cap {
            let overflow = events.count - Self.cap
            events.removeFirst(overflow)
            droppedCount += overflow
        }
        if event.name == "ended" { markEnded() }
    }

    mutating func markEnded(at date: Date = Date()) {
        if !ended {
            ended = true
            endedAt = date
        }
    }

    /// Events after `since`. A cursor that fell off the cap yields everything still retained.
    func slice(since: Int) -> (events: [WorkerClient.SessionEvent], next: Int) {
        if since < droppedCount {
            return (events, totalCount)
        }
        let index = since - droppedCount
        guard index < events.count else { return ([], totalCount) }
        return (Array(events[index...]), totalCount)
    }

    /// True once an ended session has been retained past its TTL and can be forgotten.
    func isExpired(now: Date = Date(), ttl: TimeInterval = SessionEventBuffer.endedTTL) -> Bool {
        guard ended, let endedAt else { return false }
        return now.timeIntervalSince(endedAt) >= ttl
    }
}

/// Op names live outside the actor so the request-timeout task can clear them without a hop.
final class OpNames: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [UInt64: String] = [:]

    func insert(_ id: UInt64, _ op: String) {
        lock.lock()
        map[id] = op
        lock.unlock()
    }

    func take(_ id: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return map.removeValue(forKey: id)
    }
}
