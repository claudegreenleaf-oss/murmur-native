# murmur-native

Native macOS components of Murmur, a voice dictation app:

- `native/helper`: a background helper that captures the dictation hotkey (including Fn), reads
  Accessibility context around the cursor, pastes text with clipboard restore, and pauses media.
- `native/engine`: a local dictation engine (Parakeet speech recognition via FluidAudio on the
  Neural Engine, Apple Foundation Models for formatting) behind a small WebSocket server.
- `shared/prompts`: the formatting prompts both engines use.

This repo is a build mirror; development happens elsewhere. Licensed GPL-3.0 (portions adapted from
VoiceInk, GPL-3.0; `CIMediaRemote` from mediaremote-adapter, BSD-3-Clause, see its notice).
