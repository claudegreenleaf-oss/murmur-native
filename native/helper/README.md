# Murmur Helper

Native macOS helper for Murmur (hotkeys, Accessibility context, paste, media control). It speaks the
protocol in `shared/protocol/HELPER.md`: `|`-framed JSON, requests on stdin, replies and events on
fd 3, `+` escaped as `+1` and `|` as `+2`.

Helper to app messages and data replies wrap their value as `{"payload": {...}}` (the canonical
shape). Set `MURMUR_HELPER_FLAT=1` in the environment to send the bare object instead.
Inbound requests accept either form.

## Build

Swift only compiles on GitHub Actions (`.github/workflows/native-helper.yml`), never on the Mac.
The artifact `murmur-helper` is `MurmurHelper.zip` containing `Murmur.app`, signed with the
"Murmur Self-Signed" identity so TCC grants survive rebuilds.

## Implemented messages

App to helper: `IsReady`, `UpdateShortcuts`, `UpdateFeatureFlags` (ack only), `StartAccessibilityServices`,
`StartAllIntervals`, `StopAllIntervals`, `HelperAppShutdown`, `RequestAccessibilityPermission`,
`GetAccessibilityStatus`, `DictationStart`, `DictationStop`, `GetTextBoxInfo`, `GetActiveAppInfo`,
`GetSelectedTextViaCopy`, `PasteText`, `CancelPaste`, `SimulateKeyPress`, `StoreFocusedAppAndElement`,
`FocusStoredAppAndElement`, `CheckStaleKeys`, `GetHardwareInfo`, `SetSecureInputMonitor`.
Anything else is answered with `HelperAPIError{type:"NO_HANDLER_REGISTERED"}`.

Helper to app: `KeypressEvent`, `TapRecoveryEvent`, `SecureInputStatus`, `AppInfoUpdate`, `TextBoxInfo`,
`AppContextUpdate`, `PasteOutcome`, `PasteBlocked`, `DictatedTextVerification`, `UpdateEditedText`,
`IsMediaPlayingUpdate`, `HardwareInfoUpdate`.

## Behavior notes

- Shortcuts come from `~/Library/Application Support/Murmur/config.json` (`prefs.user.shortcuts`, a map of
  combo strings such as `fn`, `fn+space`, `cmd+ctrl+v`, `esc` to action names; the reverse orientation is
  also accepted). Prefs `useAxContext`, `shouldPauseAudio`, `shouldMuteAudio` are read from `prefs.user`.
- Fn/Globe and matched non-modifier shortcut keys are swallowed. Esc is swallowed only between
  `DictationStart` and `DictationStop`. Events the helper posts itself carry a marker and are ignored by its own tap.
- Media pause uses mediaremote-adapter's perl trampoline (`Resources/MediaRemoteAdapter/run.pl` plus
  `libMediaRemoteAdapter.dylib`, built from `Sources/CIMediaRemote`, BSD-3). Mute uses CoreAudio and only
  restores what the helper itself changed.
- Edit observation polls the pasted region every 300 ms (anchored by the surrounding text) instead of
  using an AXObserver; end reasons: `focus_change`, `app_change`, `timeout` (60 s), `new_dictation`,
  `anchor_mismatch`, `transcript_region_removed`.

## Manual test

```
node scripts/ipc-smoke.js "/path/to/Murmur.app/Contents/MacOS/Murmur"
```
It sends `IsReady`, `GetAccessibilityStatus`, `GetHardwareInfo` and an unknown message, prints every reply,
then `HelperAppShutdown`.

## Notetaker additions

System audio capture (`StartSystemAudioCapture`, `SystemAudioChunk`, `SystemAudioCaptureState`, status and permission
requests), the microphone holders monitor and the EventKit calendar bridge are specified in `shared/protocol/HELPER.md`
("Notetaker additions"). The audio items need macOS 14.4+. The bundle declares `NSAudioCaptureUsageDescription` and
`NSCalendarsFullAccessUsageDescription`.
