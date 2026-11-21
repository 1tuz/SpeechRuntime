# Post-transcription speaker annotation (optional)

This API is for a future meeting client, **not** for SpeechCast/Handy dictation. It does
not change the existing `wavo 0.4` ASR worker, Parakeet, VAD/endpointing, streaming events,
text normalization, or term substitutions. The pre-existing stream `source: mic/system`
contract is unchanged.

## Modes

`POST /v1/audio/diarization` (Bearer token, JSON):

- `mode: "source"`: label `mic` as `local` and `system` as `remote`. **No model is loaded**.
- `mode: "nemotron"`: keep `mic` as `local`, assign `system` words to
  `remote:1`...`remote:8` based on Nemotron 3 speaker turns. A separate Wavo **0.6.0**
  executable runs *after* ASR and exits on completion. It must never run for live dictation.

Example of a source-only request:

```json
{
  "mode": "source",
  "segments": [
    {"source":"mic", "start_ms":100, "end_ms":450, "text":"Проверим Kubernetes"},
    {"source":"system", "start_ms":500, "end_ms":1000, "text":"Проверим деплой"}
  ]
}
```

Response:

```json
{
  "mode": "source",
  "segments": [
    {"source":"mic", "start_ms":100, "end_ms":450, "text":"Проверим Kubernetes", "speaker_id":"local"},
    {"source":"system", "start_ms":500, "end_ms":1000, "text":"Проверим деплой", "speaker_id":"remote"}
  ],
  "turns": []
}
```

For `nemotron`, add `system_audio_base64` containing a complete WAV recording of the
system channel and, if it starts later than the meeting timeline, its
`system_audio_offset_ms` (integer, default `0`). All segments must already be
synchronized to the **meeting** timeline. Runtime shifts Nemotron turns by the
system audio offset both for matching and in the returned `turns`. The mic track
is never sent to Nemotron. Use word-sized segments (`start_ms`, `end_ms`, `text`,
`source`); Runtime does not split sentences without word timings. It preserves
input text, timings, order, and extra fields and adds or replaces `speaker_id`.
When no turns are found, system segments have `speaker_id: null`.

The JSON body is limited to 128 MiB, including base64 and segment data. This fits
roughly 50 minutes at 16 kHz, 16-bit mono PCM; higher-rate audio or large segment
metadata reduce that duration. Use one system track and keep the mic track separate.

Both modes are opt-in. The authenticated `GET /v1/diarization` reports the
Nemotron executable as `modes.nemotron.available` and local weights as
`modes.nemotron.model_available`. These checks do not load or run the model.

## Optional component

Install or remove **Nemotron 3 Diarization** in Speech Runtime's optional components.
The app verifies the pin for each download before publishing the pair under
`~/Library/Application Support/SpeechRuntime/OptionalModels/nemotron-diarization/`.
Neither Wavo nor its weights ship in the app bundle or load at service startup.

For a manually managed installation, set the paths in the daemon JSON config:

```json
{
  "diarization": {
    "binary": "/absolute/path/to/wavo-v0.6.0",
    "model": "/absolute/path/to/nemotron-3-diarization-q8_0.gguf",
    "backend": "cpu"
  }
}
```

`SPEECH_RUNTIME_WAVO_BINARY` overrides the configured binary. Runtime invokes
Wavo **0.6.0 or compatible** as `wavo run /path/to/model.gguf FILE --json --backend cpu`.
Inference does not download assets. If the executable or local weights are
missing, a request that needs Nemotron fails explicitly; `source` still works
offline. The default is `cpu`; `gpu` and `auto` are optional. Only one Nemotron
subprocess runs at a time. It is bounded by a deadline and never stays resident.

The optional component uses the [Wavo 0.6.0 release](https://github.com/vladkens/wavo/releases/tag/v0.6.0)
and the [Nemotron GGUF conversion](https://huggingface.co/mudler/Nemotron-3-Diarization-GGUF)
of [NVIDIA Nemotron 3 Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization).

This estimates speaker turns within one system-audio channel; it does not replace
mic/system capture. `local` labels the mic input, not a verified human identity:
other nearby people may also be picked up by the mic. Store speaker names, raw
recordings, summaries and UI state in the meeting client, not Speech Runtime.

## Acceptance checks

- `cd runtime/daemon && swift test` on macOS.
- `cd runtime/worker && cargo test` on macOS; existing wavo 0.4 dependency unchanged.
- Source-only annotation works without Wavo or internet access and leaves input unchanged.
- A mocked Wavo 0.6 process proves correct turn JSON and separate-process execution.
- Existing SpeechCast/Handy stream events (`source`, `final`, `cancelled`, `error`),
  Parakeet text, timestamps, and term substitutions are unchanged.
- Do **not** claim improved DER on Russian IT meetings without measured reference audio.
