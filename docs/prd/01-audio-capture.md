# PRD 01 - Audio Capture

Milestone: M1. Owner stage: `CaptureActor`. Status: v0.2 after interview (browser calls, remote audio only).

## Problem
Jeeves must hear what the other participants on a browser-based call (Google Meet or Zoom
web, in Chrome or Safari) say, reliably, for an hour at a time, without a virtual audio
driver, kernel extension, or changing the user's output device. The user's microphone is
not captured in v1 (interview decision).

## Goals
- Capture the audio output of a chosen call app (or all system audio) using Core Audio
  process taps (`AudioHardwareCreateProcessTap`, macOS 14.4+; we deploy on 26).
- Deliver 16 kHz mono Float32 frames to the transcription stage with under 50 ms of added latency.
- Survive device changes, app restarts, sleep/wake, and sample-rate changes mid-call.

## Non-goals
- Recording to disk (PRD 07 handles persistence; capture only streams).
- Microphone capture (deferred; the `channel` tag stays in the data model so it can be added).
- Per-participant separation (we get one mixed remote stream).
- Capturing calls on an iPhone or on another machine.

## User stories
- As a user I pick "Google Chrome" or "Safari" from a list of running audio-producing apps (browsers first) and Jeeves starts listening within one second.
- As a user I switch to AirPods during a call and Jeeves keeps working without a restart.
- As a user I can see a live level meter so I know Jeeves is actually hearing the call.

## Functional requirements
1. Enumerate running processes that have audio output, with app name and icon (`kAudioHardwarePropertyProcessObjectList`, bundle ID lookup).
2. Source modes: **single app** (default; browsers listed first) and **all system audio excluding Jeeves** (fallback when the browser's helper processes make per-app tapping unreliable).
3. Tap is private (`isPrivate = true`) and non-muting (the user still hears the call).
4. Wrap the tap in an aggregate device; read via an IO proc; resample to 16 kHz mono with `AVAudioConverter`.
5. Frames tagged `.remote`; the `.me` tag is reserved for a future mic channel.
6. Listen for `kAudioHardwarePropertyDefaultOutputDevice` / default input changes and process termination; tear down and recreate the tap transparently; emit a status event.
7. Simple energy-based VAD to suppress silence frames before they hit STT (saves CPU on a fanless Air).
8. Expose `AsyncStream<AudioChunk>` where `AudioChunk { channel, hostTime, samples }`.

## Permissions and entitlements
- `NSAudioCaptureUsageDescription` in Info.plist; system prompt appears on first tap creation.
- Hardened runtime with `com.apple.security.device.audio-input`. App Sandbox is **off** for v1 (process taps and file watching across arbitrary folders are simpler without it); revisit if we ever go to the App Store.

## Non-functional
- Added latency <= 50 ms; zero dropped frames over a 60-minute call (counted via host-time gaps).
- CPU < 5% of one core for capture + VAD while idle-listening.
- Startup to first frame < 1 s.

## Technical notes
- Reference implementations to crib from: Apple's "Capturing system audio with Core Audio taps" sample, `insidegui/AudioCap`, `makeusabrew/audiotee`.
- Taps on a PID that is not currently producing audio can fail; retry with backoff and show "waiting for audio from Zoom".
- Browser-based Meet/Zoom: Chrome plays audio from a helper process (`Google Chrome Helper`) and Safari from `com.apple.WebKit.GPU`/WebContent processes, not the main app PID. Enumerate the process object list, group by responsible bundle ID, and tap the whole group; re-evaluate the group when the browser spawns new helpers (new tab, new call).

## Acceptance criteria
- A 60-minute Meet-in-Chrome call and a 60-minute Zoom-web-in-Safari call each captured with 0 dropouts and CPU under budget, measured on the target Air.
- AirPods connect/disconnect mid-call recovers within 2 s without user action.
- Switching tabs or opening a second call in the same browser keeps capture working.

## Open questions
- Chrome or Safari as the primary browser for testing order? (assume Chrome first)
- Should other tabs' audio (notifications, music) be filtered? Not possible per tab; the VAD and question detector are the filter.
