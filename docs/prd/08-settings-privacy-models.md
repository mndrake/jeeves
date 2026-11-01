# PRD 08 - Settings, Privacy, Model Management and Distribution

Milestone: M6 (with pieces landing from M0 onward). Status: v0.2 after interview (cloud LLM, no local models except STT and embeddings).

## Problem
A local-first tool lives or dies on trust and on not being fiddly. The user needs to see
exactly what runs where, control every outbound connection, manage multi-gigabyte model
files without a terminal, and install updates safely.

## Goals
- Every network-touching feature is visible on one page and individually switchable; Claude answers are the one feature that is on by default once a key is entered.
- The API key is stored in the Keychain; spend is visible per session and per day with a cap.
- STT and embedding models are downloaded, verified, and switched from the UI.
- Notarised direct-download build with in-app updates.

## Settings surface
- **General**: launch at login, hotkeys, overlay defaults, answer format, persona text, language.
- **Audio**: default browser, source mode, VAD sensitivity, output device override.
- **Transcription**: engine (SpeechAnalyzer / FluidAudio), language, vocabulary hints on/off.
- **Knowledge**: folders and web sources (PRD 04), exclusions, refresh schedule, enrichment on/off with cost estimate, re-index, delete index.
- **Answers**: Anthropic API key (Keychain; validated with a tiny request on save), model per mode (Fast = Haiku 5.5, Default = Sonnet 5.5, Deep = Opus 5.5, each overridable), effort per mode, answer length cap, "allow general knowledge when notes don't cover it", daily spend cap, cache-hit and latency readouts.
- **Sessions**: persistence default, retention, export folder.
- **Privacy**: a single page listing every feature that can make a network call (Claude answers, enrichment, web refresh, model downloads, updates), its current state, and a live counter of requests and bytes this session. "Panic" button: stop listening, cancel in-flight requests, hide overlay.
- **Diagnostics**: stage latency chart for the last session, memory and thermal state, export anonymised logs (never transcripts).

## Model management
- Local models are only the optional FluidAudio STT models and the embedding model. Manifest (bundled JSON, updatable) with source, revision, SHA-256 and size; resumable downloads under `~/Library/Application Support/Jeeves/models`; verified before first load.
- Claude models are selected by ID string from a bundled list that Settings can refresh from `GET /v1/models`, so new models appear without an app update.
- Thermal guard: if `ProcessInfo.thermalState` is `.serious`, pause enrichment and indexing; the live path is light enough to continue.

## Privacy and security
- No analytics, no telemetry, no crash reporting to third parties in v1 (local crash logs only).
- App Transport Security default; the only hosts ever contacted: `api.anthropic.com`, the user's configured documentation hosts (refresh), Hugging Face (STT/embedding model downloads), and the update server.
- API key in Keychain, never in plist, SQLite or logs. The key must be an Anthropic Console API key; Claude.ai / Claude Code subscription logins are not supported credentials for third-party apps, and onboarding says so.
- Hardened runtime, notarised; App Sandbox off in v1 (documented reason: process taps and arbitrary folder access).
- Docs state plainly: you are responsible for consent to record where you live and work; Jeeves helps you answer, it does not disclose itself to other participants.

## Distribution and updates
- Direct download `.dmg`, Developer ID signed and notarised; Sparkle for updates with EdDSA-signed appcast.
- Version pinning of macOS: minimum 26.0; CI builds on the latest Xcode 26.x.

## Acceptance criteria
- Fresh machine: install, paste API key, add a folder and `https://platform.claude.com/llms.txt`, start listening, see passages and an answer, in under 10 minutes without a terminal.
- With Claude answers off, `nettop` shows zero connections from Jeeves across a full call; with them on, only `api.anthropic.com`.
- Switching Claude mode from the UI takes effect on the next question; spend meter matches the Console usage page within 5% over a day.

## Open questions
- Personal use only, or will others install it (affects how much onboarding polish is worth)? (assume personal first)
- Daily spend cap default (PLAN Q2)?
