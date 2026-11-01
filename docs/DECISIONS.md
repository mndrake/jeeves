# Decision Log

Append-only. Each entry: date, decision, alternatives considered, evidence.

## 2026-11-01 - Planning baseline (pre-interview, v0.1)
- Native Swift/SwiftUI app on macOS 26+; Python only for offline evaluation.
- Context sources unified as watched folders of Markdown.
- STT default candidate Apple SpeechAnalyzer; FluidAudio/Parakeet alternate; decided by M2 shoot-out.
- Hybrid BM25 + sqlite-vec retrieval with reciprocal rank fusion.
- Floating non-activating NSPanel hidden from screen sharing.

## 2026-11-01 - Requirements interview (v0.2)

| Question | Answer | Consequence |
|---|---|---|
| Primary use case | Expert consulting / technical Q&A | Neutral reference-style answers with citations; no first-person persona; no interview-prep features |
| Whose audio, which apps | Browser calls (Meet, Zoom web); remote party only | Tap Chrome/Safari helper processes; no mic channel; detector relies on silence gaps + debounce; mic deferred |
| Local vs cloud, RAM | 16 GB; the AI model is **not** local; use Claude via API key, Haiku/Sonnet/Opus by task | Dropped MLX local LLM and all 4B/8B model work; freed ~3 GB; added `AnthropicClient` (URLSession + SSE); per-task model table in PLAN D4 |
| Knowledge sources | Markdown and web pages, mostly Anthropic docs; open to preprocessing; recall speed paramount | Dropped Google Drive and PDF/DOCX from v1; added `llms.txt` + `.md` site ingestion; added ingest-time enrichment (context prefix + synthetic questions) via Haiku 5.5 Batches; two-phase display (passages first) |
| Web page ingestion method | Wants a recommendation | Recommended `llms.txt` -> per-page `.md` for Anthropic docs (verified: `platform.claude.com/llms.txt`, `platform.claude.com/llms-full.txt`, `code.claude.com/docs/llms.txt`, all pages served as `.md`); generic URLs via `.md` probe -> readability -> Haiku cleanup |
| Mic | Remote party only | As above |
| Display | Instant passages, then answer | PRD 06 two-phase panel; PRD 05 split into local Phase 1 and cloud Phase 2 budgets |
| Stack | All Swift / SwiftUI | Confirmed D1 |

### Model-per-task defaults (PLAN D4)
- Live answer: `claude-sonnet-5-5`, thinking off via `{type: "between_tools"}`, effort `low`, streaming, `fallbacks: "default"` + beta `server-side-fallback-2026-07-01`.
- Fast mode: `claude-haiku-5-5`, thinking `disabled`, effort `low`; no `fallbacks` (unsupported on Haiku 5.5).
- Deep mode: `claude-opus-5-5`, effort `low`/`medium` (thinking cannot be disabled).
- Ingest enrichment and HTML cleanup: `claude-haiku-5-5` via Message Batches, 1-hour cache on the whole document.
- Question detection: on-device Foundation Models; Haiku 5.5 fallback.
- Post-call summary: `claude-sonnet-5-5`, effort `medium`.
- API version header `2026-10-21`; no sampling params; no prefill; cache prefix >= 512 tokens.
- Pricing used for estimates (Anthropic first-party, 2026-10): Opus 5.5 $4/$20 per MTok, Sonnet 5.5 $2/$10, Haiku 5.5 $0.10/$0.50 (prompts <= 100K), batch at 50%.

### Platform facts used
- 2026 MacBook Air: Apple M5, 10-core CPU, 8/10-core GPU, 16 GB base (24/32 GB options), ships with macOS 26 Tahoe.
- Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`): macOS 14.4+, `NSAudioCaptureUsageDescription` required.
- FluidAudio: Parakeet TDT 0.6B v3 (batch) and Parakeet EOU 120M (streaming), CoreML, macOS 14+.

Pending: PLAN section 9 (six low-stakes defaults). Shoot-out results from M0-M4 will be appended here.
