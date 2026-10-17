# MurmurEngine (local dictation engine)

Swift executable that speaks `shared/protocol/ENGINE.md` on `127.0.0.1:18798` (no auth). It is the
"Local (this Mac)" engine and the fallback when the a6000 server is unreachable.

## How the app launches it

```
MurmurEngine --port 18798
```

- Binds loopback only. The process exits when its stdin closes, so the Electron app spawns it with a
  pipe on stdin and owns its lifetime. Pass `--no-stdin-watch` to run it standalone.
- Logs go to stderr. Transcripts and audio are never logged.
- Ship the `MurmurEngine_MurmurEngine.bundle` directory next to the binary (it holds the shared prompts).
- First start downloads Parakeet TDT v3 into `~/Library/Application Support/Murmur/models/` and loads it
  in the background. The model stays in memory afterwards. Poll `/healthz` as usual; a dictation that
  arrives during the first download simply waits (heartbeats keep flowing).

## Implemented

- `GET /healthz`, `POST /v1/format`, `POST /v1/command`, `POST /v1/extract_edited_words`, and the
  `WS /v1/dictate` session (init, audio, context, commit, cancel; heartbeat every second; partial
  `state` frames after each finished segment; one `result`). HTTP and WebSocket framing are hand-rolled
  on top of Network.framework's `NWListener` so both share one port.
- ASR: FluidAudio 0.17.7, Parakeet TDT v3 (25 languages) on the Neural Engine. Completed segments are
  transcribed while audio streams: a cut happens at a pause of 520 ms or more once 8 s have accumulated,
  the tail is transcribed at commit, short dictations are transcribed whole at commit.
- Vocabulary: `replacements` are applied as case-insensitive whole-word substitutions, then a
  conservative fuzzy correction maps near-miss words to dictionary terms (same first letter, edit
  distance 1, or 2 for terms of 8+ letters). FluidAudio's CTC keyword boosting is not used because it
  needs a second model download.
- Formatting: Apple Foundation Models (`SystemLanguageModel.default`, greedy decoding, macOS 26 with
  Apple Intelligence). The system message is assembled from the bundled shared prompts exactly as
  `format-request.md` describes, with cursor context trimmed to 300 characters per side and 60 screen
  words so it fits the roughly 4k token window. Post-processing: echo stripping, hallucination guard,
  snippets, `casual_messaging` / `all_lowercase`, HTML, `starts_with_proper_noun`, edit stats.
- Fallback: when Foundation Models is unavailable, times out (4 s, 10 s for the very first call),
  errors, or is rejected by the guard, rule-based cleanup runs (fillers, stutters, simple number/day
  backtracks, "scratch that", spoken punctuation, "new line" / "new paragraph", capitalization, final
  punctuation by style). Status is `raw_transcript` with `format_skip_reason` set
  (`formatter_error` when the model is unavailable).
- Command mode (`metadata.mode = "command"` and `/v1/command`) and `/v1/extract_edited_words` use
  Foundation Models. Without it, command mode returns an `error` and the extract endpoint returns no
  accepted candidates.

## Not implemented / limits

- No streaming of the formatter (the result is emitted once).
- Rule-based cleanup does not build lists or email layout (that needs the model).
- Self-correction in the fallback only handles number/day/month swaps ("3, actually 4") and "scratch that".

## Build

CI only (`.github/workflows/native-engine.yml`, macOS runner). The workflow copies `shared/prompts/*`
into `Sources/MurmurEngine/Resources/prompts` before `swift build`; that directory is git-ignored.
Never build on the dev Mac.
