# Jeeves - Plan

Status: v0.2 (2026-11-01), updated after the requirements interview. Interview answers
and the decisions they drove are logged in `docs/DECISIONS.md`. Remaining open questions
are in section 9.

---

## 1. Vision

Jeeves is a native macOS app that sits beside a browser-based video call and acts like
an expert colleague with your notes open. It:

1. Captures the remote side of the call from the browser (Chrome or Safari).
2. Transcribes it on-device with sub-second latency.
3. Notices when a question has been asked.
4. Instantly (under ~300 ms) shows the top matching passages from your knowledge base.
5. Streams a short synthesized answer from Claude underneath, a second or so later.

The use case is **expert consulting and technical Q&A**: reference-style, neutral,
citation-backed answers. The knowledge base is Markdown notes plus documentation
websites, with Anthropic's docs as the primary web source.

**Recall speed is the top product metric.** Everything that can be precomputed is
precomputed at ingest time; the only network call on the critical path is the single
streaming Claude request for the synthesized answer, and the passages are already on
screen before it starts.

## 2. Target platform

| Item | Target | Notes |
|---|---|---|
| Hardware | 2026 MacBook Air, Apple M5, **16 GB** unified memory | Fanless; sustained load throttles. No local LLM, so memory is comfortable |
| OS | Minimum macOS 26 Tahoe (deployment target 26.0); primary target macOS 27, current since September 2026 | Core Audio process taps, `SpeechAnalyzer`, Foundation Models framework. Avoid macOS 27-only APIs (for example `AnalyzerInputConverter`) unless the minimum moves |
| Toolchain | Xcode 27, Swift 6.4, SwiftUI, Swift concurrency; app project generated with XcodeGen | Single process; no Python at runtime. Xcode 27 needs macOS 26.6+ |
| Call apps | Google Meet and Zoom **in the browser** (Chrome, Safari) | Native Zoom/Teams are out of scope for v1 but the tap code is app-agnostic |
| LLM | Anthropic API (Claude Haiku 5.5 / Sonnet 5.5 / Opus 5.5), picked per task | See D4. Requires a Console API key |

## 3. Architecture

```
+-------------------------------------------------------------------------------------+
|  Jeeves.app  (Swift / SwiftUI, one process, one actor per stage)                      |
|                                                                                       |
|  Capture ----> Transcribe ----> Detect ----> Retrieve ----> [Passages on screen]       |
|  (Core Audio   (SpeechAnalyzer  (heuristics +  (BM25 + vec,       |                   |
|   process tap   streaming,       on-device      all local,        v                   |
|   on browser    on-device)       Foundation     <100 ms)      Answer ----> [Streamed]  |
|   PID)                           Models)                      (Claude via HTTPS,      |
|                                                                streaming SSE)         |
|                                                                                       |
|  Knowledge base (ingest time, not call time):                                         |
|    Sources: Markdown folders (Obsidian-aware) | Web: llms.txt + .md pages | generic URL |
|    -> normalize to Markdown -> chunk -> contextualize (Claude Haiku 5.5, Batch API)    |
|    -> embed (local) -> SQLite FTS5 + sqlite-vec                                       |
|                                                                                       |
|  Session store (opt-in): transcript, questions, passages, answers, timings -> SQLite  |
+-------------------------------------------------------------------------------------+
```

Design rules:

- **Two-phase display.** Phase 1 (local, ~300 ms): question + top 3 passages with source
  breadcrumbs. Phase 2 (cloud, ~1-1.5 s): Claude's answer streams in below. The user is
  never staring at a spinner.
- **Local retrieval, cloud synthesis.** Embeddings and search are local so recall never
  waits on the network. Only the question, recent transcript snippet and retrieved
  chunks are sent to Anthropic. Audio never leaves the machine.
- **Precompute aggressively.** Web pages are fetched, cleaned and chunked at ingest.
  Each chunk gets a short Claude-written context prefix (Anthropic's "contextual
  retrieval" technique) and a few synthetic questions, all generated offline via the
  Batch API at half price. At call time retrieval is a pure lookup.
- **Actors per stage, timing on every event.** Each stage is a Swift actor emitting an
  `AsyncStream`; every event carries host-time stamps so the latency budget is
  measured, not guessed.

## 4. Key decisions

### D1. All Swift / SwiftUI (confirmed by interview)
Core Audio taps, `SpeechAnalyzer`, Foundation Models and `NSPanel` overlays are native
only. There is no official Anthropic Swift SDK, so the Claude client is a small
`URLSession`-based module speaking the Messages API over HTTPS with SSE streaming
(see PRD 05 for the exact request shape). Python exists only under `eval/` for
offline measurement.

### D2. Context sources: Markdown folders + documentation sites, unified as Markdown
The interview replaced the "Obsidian vs Drive vs local" question with: **Markdown
files and web pages, mostly Anthropic docs, recall speed paramount.** Recommendation:

1. **Markdown folders** (Obsidian vault or any folder): indexed directly. Headings give
   chunk boundaries; frontmatter and tags are free metadata.
2. **Documentation sites via `llms.txt`.** Anthropic's doc sites publish an `llms.txt`
   index and serve every page as clean Markdown by appending `.md` to the URL
   (verified for `platform.claude.com` and `code.claude.com`; `platform.claude.com` also
   publishes `llms-full.txt`). Jeeves treats an `llms.txt` URL as a "folder": fetch the
   index, fetch each `.md` page, store under `~/Library/Application Support/Jeeves/web/<host>/...`,
   and from there it is indexed exactly like a local Markdown folder. Re-fetch on a
   schedule using `ETag`/`Last-Modified`; only changed pages are re-chunked and re-embedded.
3. **Generic URLs** (no `.md` or `llms.txt`): fetch HTML, strip boilerplate, convert to
   Markdown. First try `<url>.md` and `/llms.txt` on the host; otherwise run a
   readability pass in Swift and, when that produces poor output, have Claude Haiku 5.5
   convert the HTML to Markdown at ingest (cheap, offline, batched).
4. **Preprocessing for recall** (ingest time, Batch API, Claude Haiku 5.5): per chunk,
   a 1-2 sentence context prefix situating the chunk in its document, plus 2-3 questions
   the chunk answers. Both are indexed alongside the chunk text. This is the single
   biggest recall lever for terse documentation chunks.

Google Drive is dropped from v1 scope. The watched-folder design still covers a Drive
for desktop folder of Markdown files if that ever matters.

### D3. STT: Apple `SpeechAnalyzer` first, FluidAudio/Parakeet alternate
Unchanged. Remote channel only (interview), so one STT instance. The STT shoot-out in
M2 includes Anthropic/Claude-specific vocabulary (model names, API terms) pulled from
the index as contextual hints.

### D4. Answer model: Claude via the Anthropic API, model chosen per task
Interview: the AI model is not local; use Claude with Haiku/Sonnet/Opus chosen per task.

| Task | Model | Settings | Why |
|---|---|---|---|
| Live answer (default) | **Claude Sonnet 5.5** `claude-sonnet-5-5` | streaming; `thinking: {type: "between_tools"}` (thinking off for this call); `output_config.effort: "low"`; `max_tokens` ~300. M0 confirmed it: first token 718 ms p50, 843 ms p95; adaptive at low effort had p95 1,335 ms | Best speed/quality for grounded synthesis; time-to-first-token is what matters |
| Live answer, "fast" mode | Claude Haiku 5.5 `claude-haiku-5-5` | streaming; `thinking: {type: "disabled"}`; effort `low` | Lowest latency and cost; good enough when passages already carry the answer |
| "Deeper" answer (hotkey / follow-up) | Claude Opus 5.5 `claude-opus-5-5` | streaming; effort `low` or `medium` (thinking cannot be disabled on Opus 5.5) | Hard multi-document questions, worth 2-4 s |
| Ingest-time contextualization and synthetic questions | Claude Haiku 5.5 via Message Batches | non-streaming, effort `low`, 1-hour prompt cache on the full document | Thousands of chunks, half price, no latency constraint |
| HTML -> Markdown cleanup for generic URLs | Claude Haiku 5.5 via Batches | effort `low` | Only when the Swift readability pass is poor |
| Question detection (ambiguous cases) | On-device Apple Foundation Models; Haiku 5.5 as fallback | constrained output `{isQuestion, directedAtUser}` | A network hop in the detection path costs ~300 ms; on-device is ~50 ms and free |
| Post-call summary and gap list | Claude Sonnet 5.5 (or Opus 5.5 via Batches) | effort `medium` | Not latency-sensitive |

Cost model, live answers: ~2.5k input tokens (of which ~1k is a cached static prefix) and
~150 output tokens per question. On Sonnet 5.5 that is roughly $0.005 per question;
a one-hour call with 40 questions is about $0.20. Haiku 5.5 is ~20x cheaper. Ingest of a
230-page doc site (~1,500 chunks) with Haiku 5.5 Batches is well under $1.

API facts baked into the design (from the Claude API reference as of 2026-10): prompt
caching needs a prefix of at least 512 tokens on these models, so the static system prompt
is padded with the full answer-style guide and persona to clear it; Sonnet 5.5 requests
should send `fallbacks: "default"` with beta `server-side-fallback-2026-07-01` so a
safety-classifier refusal is retried server-side; Haiku 5.5 has no server-side fallback,
so the client handles `stop_reason: "refusal"` by showing the passages only. `temperature`,
`top_p` and `top_k` are not sent (rejected on API version `2026-10-21`).

Credential: an Anthropic **Console API key** (`sk-ant-...`) stored in the Keychain. A
Claude.ai or Claude Code subscription login is not a supported credential for third-party
apps; the plan assumes a Console key with usage billing. `[ASSUMPTION A3]`

### D5. Retrieval: local hybrid search over enriched chunks
SQLite with FTS5 (BM25) and `sqlite-vec` in one file. Chunk record = text + Claude-written
context prefix + synthetic questions + breadcrumb. Embedding model runs locally
(candidates: `bge-small-en-v1.5`, `nomic-embed-text-v1.5`, `Qwen3-Embedding-0.6B`, as
CoreML or MLX); chosen in M3 by recall@3 on a question set drawn from your notes and the
Anthropic docs. Target: query embedded + both searches + fusion in under 100 ms warm.

### D6. UI: floating non-activating panel, two-phase content
Passages render first; answer streams below. Panel is hidden from screen sharing
(`sharingType = .none`) and never takes keyboard focus from the browser.

### D7. Remote audio only
No microphone channel in v1 (interview). Consequence: Jeeves cannot tell when you are
speaking, so it relies on silence gaps and a debounce; a hotkey always forces an answer.

## 5. Latency and resource budget

Two clocks, both measured from the end of the spoken question:

| Phase | Stage | Budget |
|---|---|---|
| 1: passages | End of speech -> usable transcript (latest partial after about 400 ms of silence; M0: finals lag 828 ms p50, partials 22 ms) | 450 ms |
| | Question detection | 100 ms (heuristic path) / 150 ms (Foundation Models path) |
| | Query embed + hybrid search + fusion | 100 ms |
| | Render passages | 50 ms |
| | **Passages visible** | **~750 ms, ceiling 1.0 s** |
| 2: answer | HTTPS request + Claude TTFT (Sonnet 5.5, effort low, cached prefix) | 600-900 ms |
| | First answer token visible | **~1.5 s, ceiling 2.0 s** |
| | Full 60-word answer | ~2.5-3 s |

Resources (16 GB Air): Jeeves resident set under 1.5 GB (STT ~1 GB, embeddings ~0.3 GB,
app ~0.2 GB). Idle-listening CPU under 15% of one core. Zero GPU use between questions.
Network: one streaming request per question; nothing else during a call.

## 6. Milestones

Each milestone ends with something you can run on the Air during a real call.
Estimates assume one developer, mostly full time.

### M0 - Spike and skeleton (1 week) - complete 2026-11-02; results in `docs/M0.md`
- Xcode project, menu bar item, entitlements, `NSAudioCaptureUsageDescription`.
- Four throwaway demos on the target machine: process tap on Chrome/Safari captures Meet audio; `SpeechAnalyzer` streams text; `sqlite-vec` loads and queries; a Swift `URLSession` SSE client streams a Sonnet 5.5 answer with a cached prefix (verify `cache_read_input_tokens` > 0 on the second call).
- Exit: numbers for each in `docs/DECISIONS.md`.

### M1 - Hear the browser (1 week) -> PRD 01 - accepted 2026-11-02 with open items; see `docs/M1.md`
- Tap Chrome or Safari by bundle ID including helper processes; AirPods switching; browser launched after Jeeves.
- Exit: 60-minute Meet and Zoom-web calls captured with no dropouts.

### M2 - Live transcript (1.5-2 weeks) -> PRD 02 - code complete 2026-11-02, Mac tests in `docs/M2.md`
- Streaming STT, utterance segmentation, vocabulary hints from the index.
- Shoot-out `SpeechAnalyzer` vs FluidAudio on 30 min of your recorded calls, with a read-aloud test of Anthropic/API terminology.
- Exit: final-segment latency under 600 ms; domain-term accuracy acceptable.

### M3 - Knowledge base (2-3 weeks) -> PRD 04, PRD 05 (retrieval) - first cut in v0.3.0 (lexical search, Markdown/llms.txt/folders), hybrid search with potion-base-8M in v0.4.0; see `docs/M3-M4.md`
- Markdown folder indexing; `llms.txt` site ingestion with `.md` pages; generic URL fallback; incremental refresh.
- Ingest-time contextualization and synthetic questions via Haiku 5.5 Batches.
- Embedding model shoot-out; hybrid search; debug search window.
- Exit: your vault plus `platform.claude.com` and `code.claude.com` indexed; recall@3 >= 0.85 on a 60-question set; query under 100 ms.

### M4 - Live loop (2-3 weeks) -> PRD 03, PRD 05 (generation), PRD 06 - first cut in v0.3.0 (detection, answer panel, settings); see `docs/M3-M4.md`
- Question detection; two-phase overlay; Claude client with streaming, prompt caching, refusal and error handling; model picker per task; hotkeys.
- Exit: on a live call, passages under 1.0 s and first answer token under 2.0 s, measured over 50 questions. First genuinely useful build.

### M5 - Sessions and review (1-2 weeks) -> PRD 07
- Opt-in session persistence; post-call summary and "gaps in my notes" list; Markdown export into the vault.
- Exit: yesterday's call is searchable and its summary is in Obsidian.

### M6 - Hardening and polish (ongoing) -> PRD 08
- Settings, API key management, spend meter, index management, thermal guard, onboarding, notarised build with updates.

Daily-usable build (end of M4): roughly 7-10 weeks. Through M5: 9-12 weeks.

## 7. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Claude TTFT variance pushes phase 2 past 2 s | Medium | Medium | Passages are already visible (phase 1); Haiku "fast" mode toggle; keep prompts ~2.5k tokens; cached prefix; measure p95 per model in M4 |
| Network outage during a call | Low | Medium | Phase 1 is fully local, so passages still appear; banner shows "offline: passages only" |
| `SpeechAnalyzer` mishears API/model names | Medium | High for retrieval | Vocabulary hints from the index; FluidAudio alternate; BM25 tolerates partial matches; synthetic questions improve semantic recall |
| Question detection too eager or too timid (no mic channel to know when you speak) | High | Medium | Assist mode with "answer?" chip; hotkey; per-session threshold slider |
| Doc site changes break ingestion | Low | Low | `llms.txt` is a stable convention; generic fallback path |
| Browser helper process is the real audio emitter | Medium | Medium | Tap by bundle ID including children; fall back to system-wide tap excluding Jeeves |
| Fanless Air throttles | Low (no local LLM) | Low | Idle path is CPU-light; `thermalState` monitor |
| Overlay visible when screen sharing | Low | High | `sharingType = .none`; share-detection warning |
| Consent and recording law for transcripts | Medium | High | Persistence off by default; clear notice; audio never stored |
| API key misuse / cost runaway | Low | Medium | Keychain storage; per-session spend meter; daily cap in Settings |

## 8. Out of scope for v1
Native Zoom/Teams apps, microphone channel, Google Drive, Windows/Linux/iOS, local LLM,
diarisation, translation, speaking or typing on your behalf, App Store distribution,
multi-user.

## 9. Remaining open questions
These do not block M0-M2. Defaults in parentheses.
1. Answer length and format detail: bullets are the default; is a hard cap of ~60 words right, with "more" on demand? (yes)
2. Daily API spend cap that should pause cloud answers? ($5/day)
3. Any non-Anthropic documentation sites to ingest at launch, and any Markdown folders beyond one vault? (one vault + two Anthropic doc hosts)
4. Should the post-call export go into the same vault that is indexed? (yes, into a `Jeeves/` folder, indexed)
5. Detection default: Auto or Assist? (Auto, with Assist one click away)
6. English only for v1? (yes)
