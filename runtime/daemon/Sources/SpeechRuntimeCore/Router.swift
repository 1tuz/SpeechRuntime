import CoreFoundation
import Foundation

/// HTTP surface. Kept deliberately small: models, one-shot transcription, streaming sessions and
/// health. Every response is JSON; audio goes in as a body, never in a URL.
public struct Router: Sendable {
    public let token: AuthToken
    public let worker: WorkerClient
    public let config: @Sendable () -> RuntimeConfig
    public let idle: IdlePolicy
    public let tts: TtsHost
    public let voices: VoiceStore
    public let diarization = DiarizationHost()
    public let startedAt = Date()
    public let log: @Sendable (String) -> Void
    private let sessions = SessionTable()

    public init(
        token: AuthToken,
        worker: WorkerClient,
        config: @escaping @Sendable () -> RuntimeConfig,
        idle: IdlePolicy,
        tts: TtsHost = TtsHost(binaryPath: "", log: { _ in }),
        voices: VoiceStore = VoiceStore(),
        log: @escaping @Sendable (String) -> Void
    ) {
        self.token = token
        self.worker = worker
        self.config = config
        self.idle = idle
        self.tts = tts
        self.voices = voices
        self.log = log
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path == "/health" || token.matches(request.headers["authorization"]) else {
            return .error("missing or invalid bearer token", status: 401)
        }
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"): return try await health()
            case ("GET", "/v1/models"): return try await models()
            case ("GET", "/v1/diarization"): return diarizationCapabilities()
            case ("POST", "/v1/models/load"): return try await load(request)
            case ("POST", "/v1/models/unload"): return try await unload(request)
            case ("POST", "/v1/audio/transcriptions"): return try await transcribe(request)
            case ("POST", "/v1/audio/diarization"): return try await diarize(request)
            case ("POST", "/v1/streams"): return try await openStream(request)
            case ("POST", "/v1/streams/audio"): return try await streamAudio(request)
            case ("POST", "/v1/streams/end"): return try await endStream(request)
            case ("GET", "/v1/streams/events"): return try await streamEvents(request)
            case ("DELETE", "/v1/streams"): return try await cancelStream(request)
            case ("GET", "/v1/tts/models"): return try await ttsModels()
            case ("POST", "/v1/tts/models/load"): return try await ttsLoad(request)
            case ("POST", "/v1/tts/models/unload"): return try await ttsUnload(request)
            case ("GET", "/v1/tts/voices"): return .json(["voices": await voices.list()])
            case ("POST", "/v1/tts/voices"): return try await ttsRegisterVoice(request)
            case ("DELETE", "/v1/tts/voices"): return try await ttsDeleteVoice(request)
            case ("POST", "/v1/tts/synthesize"): return try await ttsSynthesize(request)
            case ("POST", "/v1/tts/cancel"): return try await ttsCancel(request)
            case ("POST", "/v1/text/postprocess"): return try await textPostProcess(request)
            default: return .error("no route for \(request.method) \(request.path)", status: 404)
            }
        } catch let error as RuntimeError {
            return .error(error.description, status: 400)
        } catch let loss as WorkerClient.WorkerLoss {
            return .error(loss.description, status: 400)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    // MARK: - Models

    private func health() async throws -> HTTPResponse {
        var workerState: [String: Any] = [
            "pid": await worker.pid ?? -1,
            "restarts": await worker.restartCount,
        ]
        let internals = await worker.internals()
        workerState["pending_replies"] = internals.pendingReplies
        workerState["event_waiters"] = internals.eventWaiters
        workerState["session_buffers"] = internals.sessionBuffers
        workerState["retired_sessions"] = internals.retiredSessions
        do {
            let stats = try await worker.stats()
            workerState["models"] = stats["models"] ?? []
            workerState["sessions"] = stats["sessions"] ?? 0
            workerState["ending_sessions"] = stats["ending_sessions"] ?? 0
            // The worker's own counters are reported by the worker: `task_vm_info` and
            // `rusage` for its pid are not visible from the daemon without a task port, so
            // copying them here is the only way `/health` can show the child's footprint.
            workerState["memory"] = stats["memory"] ?? [:]
            workerState["generation"] = await worker.generation
        } catch {
            workerState["error"] = "\(error)"
        }
        let loading = await worker.loadingModels()
        var rows = workerState["models"] as? [[String: Any]] ?? []
        for index in rows.indices {
            rows[index]["loading"] = (rows[index]["model"] as? String).map(loading.contains) ?? false
        }
        let listed = Set(rows.compactMap { $0["model"] as? String })
        for model in loading.subtracting(listed).sorted() where config().models[model] != nil {
            rows.append(["model": model, "loaded": false, "loading": true])
        }
        if workerState["models"] != nil || !rows.isEmpty { workerState["models"] = rows }
        for id in await sessions.sweep(now: Date()) { await idle.streamClosed(id) }
        await worker.cleanup()
        return .json([
            "ok": true,
            "version": "0.1.0",
            "uptime_s": Int(Date().timeIntervalSince(startedAt)),
            "memory": MemoryReport.capture().json,
            "worker": workerState,
            "streams": await sessions.activeCount(),
            "tts": (try? await tts.stats()) ?? ["loaded": false],
        ])
    }

    /// Honest capability set of every declared model. It describes what the runtime already
    /// does, not a roadmap: batch one-shots and streaming sessions exist, finals arrive only
    /// after the endpointer decides the utterance is over (no interim hypotheses), tokens
    /// carry `start_ms`, and there is no diarization. Apps read this from the listing instead
    /// of discovering the gaps by failure.
    static let capabilities: [String: Any] = [
        "batch_transcription": true,
        "streaming_sessions": true,
        "interim_results": false,
        "word_timestamps": true,
        "diarization": false,
    ]

    /// Per-route cap for POST /v1/audio/diarization only. A meeting WAV is sent as base64
    /// inside JSON, so 4/3 expansion applies: 128 MiB of raw body allows ~96 MiB WAV, about
    /// 50 minutes of 16 kHz mono 16-bit PCM (32 KiB/s). The global 256 MiB body cap and the
    /// timeouts of every other route stay untouched.
    static let diarizationBodyBytes = 128 * 1024 * 1024

    // MARK: - Text postprocess

    /// Shared transcript cleanup and exact dictionary substitution. The client sends only the
    /// ASR transcript and its effective enabled rules; the runtime owns the algorithm so apps
    /// do not each carry a second substituter. Response is exactly `{"text": ...}`.
    private func textPostProcess(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try Self.body(request)
        guard let text = body["text"] as? String else {
            throw RuntimeError.message("field \"text\" is required")
        }
        guard text.count <= TextPostProcess.Limits.textCharacters else {
            throw RuntimeError.message("text is \(text.count) characters; the limit is \(TextPostProcess.Limits.textCharacters)")
        }
        let cleanup = (body["cleanup"] as? Bool) ?? false
        let rawRules = body["rules"] as? [[String: Any]] ?? []
        guard rawRules.count <= TextPostProcess.Limits.rules else {
            throw RuntimeError.message("rules count \(rawRules.count) exceeds the limit of \(TextPostProcess.Limits.rules)")
        }
        var rules: [TextPostProcess.Rule] = []
        rules.reserveCapacity(rawRules.count)
        for (index, raw) in rawRules.enumerated() {
            guard let spoken = raw["spoken"] as? String, let replacement = raw["replacement"] as? String else {
                throw RuntimeError.message("rule \(index) requires string fields \"spoken\" and \"replacement\"")
            }
            guard spoken.count <= TextPostProcess.Limits.ruleCharacters,
                  replacement.count <= TextPostProcess.Limits.ruleCharacters else {
                throw RuntimeError.message("rule \(index) exceeds \(TextPostProcess.Limits.ruleCharacters) characters per side")
            }
            let words = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            guard words <= TextPostProcess.Limits.ruleWords else {
                throw RuntimeError.message("rule \(index) spoken side has \(words) words; the limit is \(TextPostProcess.Limits.ruleWords)")
            }
            rules.append(TextPostProcess.Rule(spoken: spoken, replacement: replacement))
        }
        let started = Date()
        let result = TextPostProcess.apply(text, rules: rules, cleanup: cleanup)
        log("text postprocess rules=\(rules.count) cleanup=\(cleanup) chars_in=\(text.count) chars_out=\(result.count) wall_ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return .json(["text": result])
    }

    private func models() async throws -> HTTPResponse {
        let configured = config().models
        let stats = (try? await worker.stats())?["models"] as? [[String: Any]] ?? []
        let loading = await worker.loadingModels()
        var loadedBy: [String: [String: Any]] = [:]
        for entry in stats {
            if let name = entry["model"] as? String { loadedBy[name] = entry }
        }
        var rows: [[String: Any]] = []
        for (name, entry) in configured.sorted(by: { $0.key < $1.key }) {
            var row: [String: Any] = [
                "model": name,
                "path": entry.path,
                "backend": entry.backend ?? "auto",
                "languages": entry.languages ?? [],
                "capabilities": Self.capabilities,
                "loading": loading.contains(name),
            ]
            if let live = loadedBy[name] {
                row["loaded"] = live["loaded"] ?? false
                row["device"] = live["device"] ?? NSNull()
                row["queued_interactive"] = live["queued_interactive"] ?? 0
                row["queued_batch"] = live["queued_batch"] ?? 0
                row["done"] = live["done"] ?? 0
            } else {
                row["loaded"] = false
            }
            rows.append(row)
        }
        return .json(["models": rows])
    }

    private func load(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try Self.body(request)
        guard let model = body["model"] as? String else {
            throw RuntimeError.message("field \"model\" is required")
        }
        guard let entry = config().models[model] else {
            throw RuntimeError.message("unknown model \(model); declared models: \(config().models.keys.sorted())")
        }
        let backend = body["backend"] as? String ?? entry.backend
        let result = try await worker.load(model: model, path: entry.path, backend: backend)
        return .json(["model": model, "result": result])
    }

    private func unload(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try Self.body(request)
        guard let model = body["model"] as? String else {
            throw RuntimeError.message("field \"model\" is required")
        }
        guard config().models[model] != nil else {
            throw RuntimeError.message("unknown model \(model)")
        }
        return .json(["model": model, "result": try await worker.unload(model: model)])
    }

    // MARK: - One-shot

    private func transcribe(_ request: HTTPRequest) async throws -> HTTPResponse {
        let model = request.query["model"] ?? ((try? Self.body(request))?["model"] as? String)
        guard let model else { throw RuntimeError.message("query parameter \"model\" is required") }
        guard let entry = config().models[model] else {
            throw RuntimeError.message("unknown model \(model)")
        }
        let audio = try Audio.decode(body: request.body, rawFormat: request.headers["x-sample-format"])
        if abs(audio.sampleRate - Audio.sampleRate) > 1 {
            throw RuntimeError.message("audio is \(Int(audio.sampleRate)) Hz; send 16000 Hz")
        }
        guard !audio.samples.isEmpty else { throw RuntimeError.message("empty audio") }
        let priority = request.query["priority"] ?? "batch"
        let window = request.query["window_ms"].flatMap(Int.init)
        // Only batch transcriptions are split, so only they carry the limit;
        // interactive requests keep the single-job path.
        let batchChunkMs: Int? = priority == "batch" ? config().batchChunkMs : nil
        let started = Date()
        let result = try await worker.transcribeReady(
            pcm: audio.samples,
            model: model,
            entry: entry,
            language: request.query["language"],
            windowMs: window,
            maxChunkMs: batchChunkMs,
            priority: priority
        )
        log("transcribe model=\(model) audio_ms=\(audio.samples.count * 1000 / 16_000) priority=\(priority)")
        var payload = result
        payload["wall_ms"] = Int(Date().timeIntervalSince(started) * 1000)
        payload["audio_ms"] = audio.samples.count * 1000 / 16_000
        return .json(payload)
    }

    // MARK: - Post-transcription diarization (never on the ASR/streaming path)

    /// Resolves the Wavo 0.6 CLI and model for post-transcription Nemotron.
    /// `env` wins, then an explicit `diarization.binary`/`model`, then the managed
    /// optional components. Returns the lock URL whenever a managed path is in play,
    /// so publish/remove/invocation serialize on one flock file.
    private func diarizationToolchain() -> (binary: String, model: String, backend: String, lockURL: URL?) {
        let settings = config()
        let envBinary = ProcessInfo.processInfo.environment["SPEECH_RUNTIME_WAVO_BINARY"]
        let managedBinary = Paths.diarizationBinaryPath.path
        let binary = envBinary
            ?? (settings.diarizationBinary.isEmpty ? managedBinary : settings.diarizationBinary)
        let model = settings.diarizationModel.isEmpty ? Paths.diarizationModelPath.path : settings.diarizationModel
        let usesManaged = binary == managedBinary || model == Paths.diarizationModelPath.path
        return (binary, model, settings.diarizationBackend, usesManaged ? Paths.diarizationLock : nil)
    }

    private func diarizationCapabilities() -> HTTPResponse {
        let toolchain = diarizationToolchain()
        return .json([
            "post_transcription_only": true,
            "modes": [
                "source": ["available": true],
                "nemotron": [
                    "available": DiarizationHost.isExecutable(toolchain.binary),
                    "model": "nemotron-diarization",
                    "model_available": DiarizationHost.isModelAvailable(toolchain.model),
                    "engine": "wavo 0.6",
                    "backend": toolchain.backend,
                ] as [String: Any],
            ] as [String: Any],
        ])
    }

    private func diarize(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.body.count <= Self.diarizationBodyBytes else {
            throw RuntimeError.message(
                "diarization request body is \(request.body.count) bytes; the limit is \(Self.diarizationBodyBytes)")
        }
        let body = try Self.body(request)
        guard let name = body["mode"] as? String,
              let mode = Diarization.Mode(rawValue: name) else {
            throw RuntimeError.message("mode must be source or nemotron")
        }
        guard let segments = body["segments"] as? [[String: Any]] else {
            throw RuntimeError.message("segments must be an array")
        }
        let offset: Int
        if let rawOffset = body["system_audio_offset_ms"] {
            guard CFGetTypeID(rawOffset as AnyObject) != CFBooleanGetTypeID(),
                  let value = rawOffset as? Int else {
                throw RuntimeError.message("system_audio_offset_ms must be an integer")
            }
            offset = value
        } else {
            offset = 0
        }
        // Validate every segment (and the offset) before any costly model load.
        // `annotate` never redecodes or reorders transcript content.
        let bySource = try Diarization.annotate(
            segments, mode: .source, systemAudioOffsetMs: offset
        )
        var turns: [Diarization.Turn] = []
        if mode == .nemotron && segments.contains(where: { $0["source"] as? String == "system" }) {
            guard let encoded = body["system_audio_base64"] as? String,
                  let wav = Data(base64Encoded: encoded),
                  wav.count >= 44,
                  wav.prefix(4) == Data("RIFF".utf8),
                  wav[8..<12] == Data("WAVE".utf8) else {
                throw RuntimeError.message("nemotron requires system_audio_base64 containing a WAV file")
            }
            let toolchain = diarizationToolchain()
            turns = try await diarization.diarize(
                wav: wav, binary: toolchain.binary, model: toolchain.model,
                backend: toolchain.backend, lock: toolchain.lockURL
            )
        }
        let annotated = mode == .source ? bySource : try Diarization.annotate(
            segments, mode: .nemotron, turns: turns, systemAudioOffsetMs: offset
        )
        log("diarization mode=\(mode.rawValue) segments=\(segments.count) turns=\(turns.count)")
        return .json([
            "mode": mode.rawValue,
            "segments": annotated,
            "turns": turns.map { turn in
                Diarization.Turn(speaker: turn.speaker, startMs: turn.startMs + offset,
                                 endMs: turn.endMs + offset).json
            },
        ])
    }

    // MARK: - TTS

    private func ttsEntry(_ body: [String: Any]) throws -> (String, TtsModelEntry) {
        guard let model = body["model"] as? String else {
            throw RuntimeError.message("field \"model\" is required")
        }
        guard let entry = config().ttsModels[model] else {
            throw RuntimeError.message(
                "unknown TTS model \(model); declared models: \(config().ttsModels.keys.sorted())")
        }
        return (model, entry)
    }

    private func ttsModels() async throws -> HTTPResponse {
        var rows: [[String: Any]] = []
        let loaded = await tts.loaded
        for (name, entry) in config().ttsModels.sorted(by: { $0.key < $1.key }) {
            var row: [String: Any] = [
                "model": name,
                "engine": entry.engine,
                "modelId": entry.modelId,
                "displayName": entry.displayName ?? name,
                "sampleRate": entry.sampleRate,
                "variants": entry.variants,
                "requiresReferenceAudio": true,
                "loaded": loaded.modelId == entry.modelId,
                "loadedVariant": loaded.modelId == entry.modelId
                    ? (await tts.residentVariant ?? NSNull()) : NSNull(),
                "memory": await tts.memoryReport ?? NSNull(),
            ]
            if let info = try? await tts.info(model: name, entry: entry) {
                row["artifact"] = info
                row["exists"] = info["exists"] ?? false
                row["bytes"] = info["bytes"] ?? 0
            }
            rows.append(row)
        }
        return .json([
            "models": rows,
            "pid": await tts.pid ?? -1,
            "loadedModel": loaded.modelId ?? NSNull(),
            "loadedVariant": await tts.residentVariant ?? NSNull(),
            "restarts": await tts.restartCount,
        ])
    }

    private func ttsLoad(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (model, entry) = try ttsEntry(try Self.body(request))
        let variant = (try? Self.body(request))?["variant"] as? String
        let result = try await tts.load(model: model, entry: entry, variant: variant)
        log("tts load model=\(model) engine=\(entry.engine)")
        return .json(["model": model, "result": result])
    }

    private func ttsUnload(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (model, _) = try ttsEntry(try Self.body(request))
        let result = try await tts.unload(model: model)
        log("tts unload model=\(model)")
        return .json(["model": model, "result": result])
    }

    private func ttsRegisterVoice(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try Self.body(request)
        guard let name = body["name"] as? String,
              let referenceText = body["referenceText"] as? String,
              let encoded = body["audioBase64"] as? String,
              let wav = Data(base64Encoded: encoded)
        else {
            throw RuntimeError.message("name, referenceText and audioBase64 are required")
        }
        let voice = try await voices.register(
            name: name,
            language: body["language"] as? String,
            referenceText: referenceText,
            wav: wav)
        log("tts voice registered name=\(name)")
        return .json(["voice": voice])
    }

    private func ttsDeleteVoice(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let id = request.query["id"], !id.isEmpty else {
            throw RuntimeError.message("query parameter \"id\" is required")
        }
        return .json(["id": id, "deleted": try await voices.delete(id)])
    }

    private func ttsSynthesize(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try Self.body(request)
        let (model, entry) = try ttsEntry(body)
        guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError.message("field \"text\" is required")
        }
        var audioPath = body["referenceAudioPath"] as? String
        var referenceText = body["referenceText"] as? String
        // True only for the temp WAV this request itself wrote: caller-supplied
        // `referenceAudioPath` (and voice profiles) are never deleted.
        var ownsTempAudio = false
        if let voiceId = body["voiceId"] as? String, !voiceId.isEmpty {
            guard let voice = await voices.get(voiceId) else {
                throw RuntimeError.message("unknown voice \(voiceId)")
            }
            audioPath = voice.audioPath
            referenceText = voice.referenceText
        } else if let encoded = body["referenceAudioBase64"] as? String,
                  let wav = Data(base64Encoded: encoded)
        {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("runtime-tts-\(UUID().uuidString).wav")
            try wav.write(to: url)
            audioPath = url.path
            ownsTempAudio = true
        }
        defer {
            if ownsTempAudio, let audioPath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
        }
        let started = Date()
        let result = try await tts.synthesize(
            model: model,
            entry: entry,
            text: text,
            language: body["language"] as? String,
            seed: (body["seed"] as? NSNumber)?.uint64Value,
            referenceAudioPath: audioPath,
            referenceText: referenceText,
            requestId: body["requestId"] as? String,
            variant: body["variant"] as? String)
        var payload = result
        payload["wallMs"] = Int(Date().timeIntervalSince(started) * 1000)
        log("tts synthesize model=\(model) chars=\(text.count)")
        return .json(payload)
    }

    private func ttsCancel(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let requestId = (try Self.body(request))["requestId"] as? String else {
            throw RuntimeError.message("field \"requestId\" is required")
        }
        let count = await tts.cancel(requestId: requestId)
        return .json(["requestId": requestId, "cancelled": count > 0, "pending": count])
    }

    // MARK: - Streaming

    private func openStream(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try Self.body(request)
        guard let model = body["model"] as? String else {
            throw RuntimeError.message("field \"model\" is required")
        }
        guard let entry = self.config().models[model] else {
            throw RuntimeError.message("unknown model \(model)")
        }
        var config: [String: Any] = [:]
        for (key, value) in (body["config"] as? [String: Any]) ?? [:] { config[key] = value }
        if let language = body["language"] as? String { config["language"] = language }
        // Client channel tag ("system"/"mic"): stored once at open, echoed by the
        // worker in every final/cancelled/error event of this session.
        if let source = body["source"] as? String { config["source"] = source }
        let id = UUID().uuidString
        let (result, generation) = try await worker.openReadySession(id: id, model: model, entry: entry, config: config)
        await sessions.insert(id, model: model, config: config, generation: generation)
        await idle.streamOpened(id, model: model, generation: generation)
        return .json(["stream": id, "model": model, "result": result])
    }

    private func streamAudio(_ request: HTTPRequest) async throws -> HTTPResponse {
        let id = try streamID(request)
        try await guardGeneration(id)
        let audio = try Audio.decode(body: request.body, rawFormat: request.headers["x-sample-format"])
        guard !audio.samples.isEmpty else { throw RuntimeError.message("empty audio") }
        try await worker.sessionAudio(id: id, pcm: audio.samples)
        let total = await sessions.addedSamples(id, count: audio.samples.count)
        await worker.cleanup()
        return .json(["stream": id, "samples": total, "audio_ms": total * 1000 / 16_000])
    }

    private func endStream(_ request: HTTPRequest) async throws -> HTTPResponse {
        let id = try streamID(request)
        try await guardGeneration(id)
        do {
            let result = try await worker.endSessionAndWait(id: id)
            await sessions.markEnded(id)
            await idle.streamClosed(id)
            await worker.cleanup()
            return .json(["stream": id, "ended": true, "result": result])
        } catch {
            // A failed end must still release the stream slot; otherwise a dead worker keeps
            // its model "in use" forever and idle unload can never run.
            await sessions.markEnded(id)
            await idle.streamClosed(id)
            throw error
        }
    }

    private func cancelStream(_ request: HTTPRequest) async throws -> HTTPResponse {
        let id = try streamID(request)
        try await guardGeneration(id)
        do {
            try await worker.cancelSession(id: id)
        } catch {
            // The worker may have restarted; the session is dead either way.
        }
        await worker.forgetSession(id)
        await sessions.remove(id)
        await idle.streamClosed(id)
        return .json(["stream": id, "cancelled": true])
    }

    private func streamEvents(_ request: HTTPRequest) async throws -> HTTPResponse {
        let id = try streamID(request)
        let since = Int(request.query["since"] ?? "0") ?? 0
        let timeout = min(Double(request.query["wait"] ?? "0") ?? 0, 25)
        let (events, next) = await worker.pollEvents(session: id, since: since, timeout: timeout)
        let ended = await sessions.isEnded(id) || (events.contains { $0.name == "ended" })
        if ended {
            await sessions.markEnded(id)
            await idle.streamClosed(id)
        }
        for reaped in await sessions.sweep(now: Date()) { await idle.streamClosed(reaped) }
        await worker.cleanup()
        return .json([
            "stream": id,
            "next": next,
            "ended": ended,
            "events": events.map { ["event": $0.name, "data": $0.data] },
        ])
    }

    private func guardGeneration(_ id: String) async throws {
        let sessionGeneration = await sessions.generation(of: id)
        let workerGeneration = await worker.generation
        guard sessionGeneration == workerGeneration else {
            throw RuntimeError.message("worker restarted; reopen stream")
        }
    }

    private func streamID(_ request: HTTPRequest) throws -> String {
        if let id = request.query["stream"] { return id }
        if let id = (try? Self.body(request))?["stream"] as? String { return id }
        throw RuntimeError.message("query parameter \"stream\" is required")
    }

    static func body(_ request: HTTPRequest) throws -> [String: Any] {
        guard !request.body.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            throw RuntimeError.message("request body must be a JSON object")
        }
        return object
    }
}

private actor SessionTable {
    struct Entry {
        var model: String
        var samples: Int
        var ended: Bool
        var endedAt: Date?
        /// Worker generation the session was opened against; mismatch means the worker died.
        var generation: Int
    }

    /// Ended/cancelled sessions live this much longer so late event polls can still read them.
    static let endedGrace: TimeInterval = 300

    private var entries: [String: Entry] = [:]

    func insert(_ id: String, model: String, config: [String: Any], generation: Int) {
        entries[id] = Entry(model: model, samples: 0, ended: false, endedAt: nil, generation: generation)
    }

    func generation(of id: String) -> Int? {
        entries[id]?.generation
    }

    func addedSamples(_ id: String, count: Int) -> Int {
        guard var entry = entries[id] else { return count }
        entry.samples += count
        entries[id] = entry
        return entry.samples
   }

    func markEnded(_ id: String) {
        guard entries[id] != nil else { return }
        entries[id]!.ended = true
        entries[id]!.endedAt = Date()
    }

    func isEnded(_ id: String) -> Bool {
        entries[id]?.ended ?? true
   }

    func remove(_ id: String) {
        entries.removeValue(forKey: id)
    }

    func count() -> Int {
        entries.count
    }

    func activeCount() -> Int {
        entries.values.filter { !$0.ended }.count
    }

    /// Drops ended sessions retained past the grace period so health counts and memory fall.
    /// Returns the removed ids so the caller can release their idle-policy slots.
    func sweep(now: Date = Date(), grace: TimeInterval = SessionTable.endedGrace) -> [String] {
        var removed: [String] = []
        entries = entries.filter { entry in
            guard entry.value.ended, let endedAt = entry.value.endedAt else { return true }
            let keep = now.timeIntervalSince(endedAt) < grace
            if !keep { removed.append(entry.key) }
            return keep
        }
        return removed
    }
}
