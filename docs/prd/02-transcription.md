# PRD 02 - Streaming Transcription

Milestone: M2. Status: v0.3 (2026-11-02): M0 results folded in, M2 tooling built; tests in `docs/M2.md`.

**Updates from M0 and M2:** SpeechAnalyzer final results lag about 1.1 s after speech
ends, so detection acts on the latest partial at 400 ms of silence (PRD 03); final-result
latency is no longer a requirement. SpeechAnalyzer misheard product names ("cloud code"),
so the engine choice now turns on domain-term recall. Candidates: SpeechAnalyzer plus an
alias table; Parakeet (FluidAudio) as the main engine; or Parakeet as a per-utterance
second pass after SpeechAnalyzer's fast partials.

## Problem
Turn the remote audio into text fast enough that a question is fully
transcribed within ~500 ms of the speaker finishing, entirely on-device, with accuracy
good enough that retrieval and the LLM are not misled by misheard key terms.

## Goals
- Streaming partial results (volatile) and finalised segments with timestamps and channel tag.
- Final-segment latency after end of utterance <= 600 ms (p95).
- Word error rate acceptable on the user's domain vocabulary; measured, not assumed.
- Memory for STT <= 1 GB resident.

## Non-goals
- Translation.
- Diarisation beyond the channel tag (remote vs me).
- Offline batch transcription of files (nice-to-have later for the evaluation harness only).

## Engine strategy
`protocol SpeechEngine { func start(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent> }`

| Engine | Pros | Cons | Role |
|---|---|---|---|
| Apple `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26) | Built in, no weights to ship, streaming, Apple-optimised, volatile+final results | Accuracy on jargon unknown; language list fixed by Apple | **Default candidate** |
| FluidAudio: Parakeet TDT 0.6B v3 (CoreML) | Strong accuracy, 25 languages, active project | ~600 MB weights; streaming via Parakeet EOU 120M variant is newer | Alternate; also the batch engine for evaluation |
| whisper.cpp / WhisperKit | Well known | Not truly streaming; large models too heavy next to an LLM | Not planned |

The engine is chosen at the end of M2 by a scripted head-to-head.

## Functional requirements
1. Consume the remote `AudioChunk` stream; one engine instance.
2. Emit `TranscriptEvent { channel, kind: .partial | .final, text, start, end, confidence? }`.
3. Sentence/utterance boundaries: use the engine's end-of-utterance signal if present, else silence >= 700 ms or punctuation.
4. Vocabulary hints: extract proper nouns and frequent terms from the knowledge-base index (PRD 04), which for this user means Anthropic model names, API parameters and product terms (for example `Sonnet`, `Opus`, `max_tokens`, `MCP`, `Managed Agents`), and feed them as contextual strings where the engine supports it.
5. Live transcript view (debug and optional user-facing): scrolling, colour by channel, partials in grey.
6. Engine switch in Settings takes effect on next session start.

## Evaluation harness (part of this PRD)
- `eval/stt/` Python scripts (offline only): take WAV + reference TXT pairs, run each engine through a small Swift CLI target, compute WER, median/p95 final latency, peak memory.
- Test set: >= 30 minutes of the user's own recorded calls (user supplies; we provide a recording helper built on PRD 01) plus a public meeting corpus sample for sanity.

## Non-functional
- p95 final latency <= 600 ms; p50 partial latency <= 300 ms.
- CPU: < 40% of one core sustained while speech is active; near zero in silence (VAD gating from PRD 01).
- No network calls, ever, from this stage.

## Acceptance criteria
- Shoot-out report committed to `docs/DECISIONS.md` with the numbers above for each engine (tool: `spike-asr`).
- Provisional text (partial at 400 ms of silence) compared with finals live (tool: `spike-stt --live`).
- Chosen engine meets latency and memory targets on the Air during a live 30-minute call.
- Domain-term accuracy: >= 90% of the top-50 terms from the index (Anthropic/API vocabulary and the user's notes) transcribed correctly in a read-aloud test.

## Open questions
- English only for v1 (assumed yes; PLAN Q6).
- Mic channel is out of scope by interview decision; revisit if "don't interrupt me" logic is missed.
