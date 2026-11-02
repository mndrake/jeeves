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

## 2026-11-01 - M0 started

- **macOS 27 is current.** It shipped in September 2026 with Xcode 27 and Swift 6.4. The
  deployment target stays macOS 26.0 so the app runs on Tahoe too; development uses
  Xcode 27. Source for the release: a third-party write-up plus Apple's Xcode
  requirements page; confirm on the Mac.
- **Swift package + XcodeGen.** Modules live in a SwiftPM package that also builds on
  Linux, so the client, index and tests run in CI without a Mac. The app target is
  generated from `App/project.yml`; the `.xcodeproj` is not committed.
- **SQLite is vendored** (3.54.1 amalgamation + sqlite-vec v0.1.9, statically compiled).
  macOS's system SQLite cannot load extensions, and vendoring pins FTS5 behaviour.
  Pinned to sqlite-vec's latest stable tag, not the 0.1.10 alpha on main.
- **Claude client is hand-written over HTTP.** There is no official Anthropic Swift SDK.
  Streaming uses a `URLSessionDataDelegate` so SSE event boundaries survive and the same
  code runs on Linux.
- **Refusal fallback on by default** for Sonnet 5.5 and Opus 5.5 (`fallbacks: "default"`,
  beta `server-side-fallback-2026-07-01`). Omitted for Haiku 5.5, which has no
  server-side fallback. The stream decoder records `fallback` blocks and discards
  partial text on `stop_reason: "refusal"`.
- **Speech input conversion** uses `AVAudioConverter` directly, because
  `AnalyzerInputConverter` is macOS 27-only.
- **Tap strategy is an open M0 question.** Three are implemented: `bundleIDs` (macOS 26
  `CATapDescription.bundleIDs` with process restore), per-process taps of the browser's
  helper processes, and a system-wide tap excluding Jeeves.
- **Linux container numbers** are in `docs/M0.md`: hybrid search at 10k chunks is
  17 ms p50 and 29 ms p95, well inside the 100 ms retrieval budget.

## 2026-11-01 - M0 tap results (MacBook Air, macOS 26, Chrome + Google Meet, v0.0.1)

| Strategy | Result | Gaps (30 s) | CPU | Audible chunks |
|---|---|---|---|---|
| `pids` (browser processes) | captures | 0 | 2.0% | 951 / 2,812 |
| `system` (all except Jeeves) | captures | 0 | 1.9% | 1,820 / 2,812 |
| `bundle` (`CATapDescription.bundleIDs`) | no audio delivered | - | - | - |

- **Default capture strategy: `pids`.** It hears only the browser. `system` is the
  fallback; it also captures notifications, music and other apps. The app and the spike
  tools now default to `pids` (v0.0.2).
- Tap format is 48 kHz mono mixdown; callback-to-consumer lag p50 0.1 ms.
- Follow-ups for M1: `pids` snapshots the browser's processes when the tap starts, so a
  helper launched later (new tab or call) is missed; re-scan and rebuild the tap when
  Core Audio's process list changes. Confirm with live transcription that `pids` does
  not drop speech that `system` hears.

## 2026-11-02 - M0 live transcription results (MacBook Air, Chrome + Meet, v0.0.2)

`spike-stt --live`, fast mode, `pids` capture, 60 seconds of speech from a second device:

| Measurement | Result | Plan budget |
|---|---|---|
| Final result lag p50 / p95 (n=17) | 828 / 1,084 ms | 500 ms (p95 at most 600 ms) |
| Partial result lag p50 / p95 (n=136) | 22 / 28 ms | none |
| Tap gaps | 0 | 0 |
| Analyzer startup | 130-461 ms | none |

Transcripts were accurate on conversational speech, with occasional mishearings of
names. The final-result lag is mostly SpeechAnalyzer waiting to be sure an utterance
has ended before it finalizes.

- **Do not wait for final results.** Question detection (PRD 03) runs on the latest
  volatile result once our own level-based silence check sees about 400 ms of quiet.
  Retrieval starts on that text; if the final differs, re-run retrieval (local, about
  20 ms) and only update the panel if the passages change.
- **Next experiment:** call `SpeechAnalyzer.finalize(through:)` at the detected end of
  speech to force the final early, and measure it with `spike-stt`. Also run
  `--mode accurate` and the file-mode word-error-rate test before keeping
  SpeechAnalyzer over FluidAudio.
- `spike-stt` prints "downloading speech assets" even when the assets are already
  installed (startup was 130 ms). Cosmetic; fix with an `AssetInventory.status` check.

## 2026-11-02 - Finalize experiment, baseline run (v0.0.3)

Reading the Claude Code best-practices page aloud from a second device, 60 seconds,
fast mode, `pids`, no forced finalization:

| Measurement | Result |
|---|---|
| Speech end to final, p50 (n=9) | 1,117 ms |
| Final lag p50 / p95 (n=10) | 973 / 1,125 ms |
| Partial lag p50 / p95 (n=196) | 22 / 28 ms |
| Speech ends | 13 detected, 9 matched, 4 merged into longer finals |

- The baseline confirms about 1.1 s from the speaker stopping to final text, versus
  400 ms for the partial-text trigger. The p95 (1,982 ms) is overstated: v0.0.3 timed
  every pause a final covered, so one final that swallowed two pauses counted the
  earlier one at 2,443 ms. Fixed on main: only the last pause inside a final is timed.
- **Domain terms are misheard despite contextual strings.** "Claude Code" came out as
  "cloud code" every time, "auto mode" as "automote", and some sentences were garbled
  ("rescued court runs"). Consequences: the live-answer prompt now lists these
  mishearings; M3's query builder should map known mishearings to canonical terms
  before searching (a small alias table derived from the index vocabulary); and the M2
  shoot-out should weigh domain-term accuracy, where FluidAudio/Parakeet may do better.
- The live-answer prompt had runs of spaces inside some sentences, from line
  continuations lost in an earlier edit. Rewritten, with a test that guards it.

## 2026-11-02 - Finalize experiment: forced finals are fast but fragment text (v0.0.3)

Same setup as the baseline, with `--finalize-on-silence` (400 ms of silence, speech
above -45 dBFS): Jeeves calls `SpeechAnalyzer.finalize(through:)` at each detected end.

| Measurement | Baseline | Forced at 400 ms |
|---|---|---|
| Speech end to final, p50 / p95 | 1,117 ms / (overstated) | 518 / 540 ms |
| Final lag p50 / p95 | 973 / 1,125 ms | 241 / 1,088 ms |
| Speech ends matched | 9 of 13 (4 merged) | 10 of 11 (1 merged) |

- Latency: the engine finalizes about 120 ms after being asked, so forced finals land
  near the silence setting.
- Quality: forcing a final at every 400 ms pause cut sentences mid-phrase. The run had
  fragment finals such as "to.", "..", "don...", "where......." and ", to, and force
  the rules", and context loss at the cuts ("your 1st plane prompt in a 1st essenary",
  versus "your first plan prompt in a fresh session" in the baseline). Natural speech
  pauses mid-sentence for longer than 400 ms.
- **Decision: do not force finals.** Question detection uses the latest partial when
  400 ms of silence is detected (about 400 ms after speech ends, versus about 1.1 s for
  the engine's own finals). Engine finals stay as the record for display, history and
  a retrieval re-run when they differ from the partial.
- **Open question:** how often the partial at the moment of silence differs from the
  final enough to change retrieval. Measure by saving the partial at each detected end
  and comparing it with the final that later covers it.
- 300 ms variant (test 3): speech end to final p50 404 ms, p95 444 ms (n=17), final lag
  p50 128 ms; 18 ends detected, 17 matched, 1 merged. Fragmentation was worse, as
  expected: the same 60 seconds split into 18 finals, many of them junk ("." ", your."
  ", to..............." "of..") and more mishearings ("SCO sessions start in on the
  boat"). This confirms the decision: shorter forced finals trade accuracy for speed,
  and the partial-text trigger gets the speed without touching the engine's finals.

## 2026-11-02 - M0 Claude latency (spike-claude v0.0.3, home network)

Eight live-answer requests per mode with the real system prompt (1,451 tokens, cached)
and six passages; the first request per model writes the cache, so the statistics
cover the seven warm requests.

| Mode | Model and settings | First answer token p50 / p95 | Total p50 | Cache hits | Cost (8 requests) |
|---|---|---|---|---|---|
| `standard` | Sonnet 5.5, `between_tools`, effort low | 718 / 843 ms | 1,639 ms | 7/7 | $0.0235 |
| `standard-adaptive` | Sonnet 5.5, adaptive, effort low | 787 / 1,335 ms | 1,563 ms | 7/7 | $0.0236 |
| `fast` | Haiku 5.5, thinking disabled, effort low | 613 / 945 ms | 1,160 ms | 7/7 | $0.0011 |
| `deep` | Opus 5.5, adaptive, effort medium | 2,178 / 2,969 ms | 3,195 ms | 7/7 | $0.0657 |

- **Default live answer: Sonnet 5.5 with `thinking: between_tools`, effort low.** Its
  p95 (843 ms) meets the 900 ms target. Adaptive thinking at low effort, which the API
  guide prefers in general, had a similar median but a much worse tail (p95 1,335 ms)
  at the same cost, because on some questions it chose to think first.
- **Haiku 5.5 stays the opt-in fast mode.** Its median is only about 100 ms faster
  and its p95 is slower than Sonnet's, but it costs about 20 times less. Answer quality
  has not been compared yet; the answers are in the user's `claude.json`.
- **Opus 5.5 stays on demand only** (hotkey or "deeper"): first token at 2.2 s p50.
- Prompt caching works as designed: every warm request read the 1,451-token prefix.
- End-to-end estimate for the default path: about 400 ms silence trigger, about 20 ms
  retrieval, and 718 ms (p95 843 ms) to the first answer token, so roughly 1.1-1.3 s
  from the end of the question to the first answer word on screen. That is inside the
  plan's 2.0 s ceiling; passages appear at about 0.45 s.
- Cost: about $0.003 per Sonnet answer, so a one-hour call with 40 questions is about
  $0.12, below the plan's $0.20 estimate.

## 2026-11-02 - M0 search latency on the MacBook Air (spike-vec v0.0.3)

10,000 synthetic chunks of 384 dimensions, 200 queries: hybrid search (BM25 + sqlite-vec,
fused) 6.4 ms p50 and 8.2 ms p95; lexical 3.2 / 5.0 ms; vector 3.3 / 3.3 ms; inserts at
26,815 chunks/s; 25.5 MB on disk. About 3.5 times faster than the Linux container, with
sqlite-vec's NEON path. Retrieval uses under a tenth of its 100 ms budget, so exact
(brute-force) vector search stays; no approximate index is needed at this corpus size.

## 2026-11-02 - M0 complete

The menu bar app (v0.0.3) captured a Meet call through Chrome's processes and showed a
live transcript, with final lag p50 823 ms and p95 1,039 ms (n=6), matching the spike.
Every M0 exit criterion is met or resolved by a recorded decision.

Carried into M1 and later:
- M1: re-scan the browser's processes and rebuild the tap when Core Audio's process list
  changes (new tab or call); recover from output device changes.
- M2: compare SpeechAnalyzer with FluidAudio/Parakeet on product-name accuracy ("Claude"
  heard as "cloud"); measure how often the partial at 400 ms of silence differs from the
  final; try accurate mode.
- M3: alias table for known mishearings in the query builder.
- Answer quality of Haiku 5.5 versus Sonnet 5.5 is not yet compared (answers saved in the
  user's `claude.json`).
- Fixed after the app run: transcript segments carried a leading space, which indented
  every line after the first.

## 2026-11-02 - M0 answer quality, Sonnet 5.5 `standard` (from the user's claude.json)

Seven answers reviewed against the six passages the spike sends:

- All grounded and correctly cited; no claims beyond the passages.
- Partial coverage handled as designed: asked whether a mid-answer refusal can fall back
  automatically, it answered from passage 6 and added "Not covered: behavior for a
  refusal that occurs mid-stream after partial output".
- Correct hedging ("No Swift SDK listed" rather than "there is no Swift SDK").
- Style drift to fix in M4 prompt tuning: sometimes two bolded phrases instead of one,
  one answer slightly over the 60-word cap, occasional adjacent facts that were not
  asked for (cache pricing in the Sonnet price answer).
- `standard-adaptive` (adaptive thinking, low effort) gave essentially the same answers:
  same facts, citations and "Not covered" notes, occasionally a slightly sharper gap
  note ("Not covered: cache read price"). No quality gain to offset its slower tail
  (p95 1,335 ms versus 843 ms), which confirms `between_tools` as the default.
- Correction: the "Not in your notes." path did run, through the Swift question (see the
  next entry). The deliberately uncovered Rust question was tenth, beyond the default 8,
  and is now third.

## 2026-11-02 - M0 answer quality across all four modes

Same eight questions, answers from the user's `claude.json`:

- **Haiku 5.5 (`fast`) matched Sonnet on this set.** All answers grounded and correctly
  cited with the same facts, including the partial-coverage note on mid-answer refusals
  ("Not covered: whether a refusal arriving partway through an answer is retried"). Some
  were tighter than Sonnet's (a one-bullet price answer). One small inference beyond the
  passage ("a non-zero value confirms a cache hit"), which is reasonable.
- **Opus 5.5 (`deep`) added nothing on these questions**: same content with an extra
  bullet, 1-3 s to the first word. Stays on demand only.
- **Default stays Sonnet 5.5 with thinking off**, for the better tail latency (p95 843 ms
  versus Haiku's 945 ms) and expected headroom on harder, multi-passage questions. Cost
  does not decide it: about $0.12 versus $0.005 per one-hour call. Revisit with the
  60-question evaluation set in M3/M4; if Haiku holds up there, it can become the default.
- **Prompt fix for M4: absence from a complete list is an answer.** Asked "Is there an
  official Swift SDK?", Sonnet `standard` answered "No Swift SDK listed" with the list and
  citation, but `standard-adaptive`, Haiku and Opus all said "Not in your notes." even
  though passage [1] lists every official SDK. Add: "If a passage gives a complete list
  and the item asked about is not in it, say it is not listed and cite the list."

## 2026-11-02 - M1 design: supervised capture

- One `CaptureSession` per listening session owns the tap and repairs it: retarget in
  place when the browser's process set changes, rebuild on output-device change or a
  1.5 s IO stall, pause while the browser has no audio processes, retry failed rebuilds
  with backoff (0.25 s doubling to 4 s).
- Without in-place retargeting, a rebuild happens only when a process the tap misses is
  actually playing, because each rebuild drops a moment of audio.
- Audio lost in a rebuild is replaced with silence (up to 5 s) so speech timestamps stay
  aligned with real time. No filling during normal capture, where small differences are
  clock drift.
- Decisions are pure functions in JeevesCore with unit tests; the Core Audio side is
  thin and verified by `spike-capture` on the Mac.
- Open: whether `kAudioTapPropertyDescription` can be set on a running tap. Apple's
  documentation does not say; `spike-capture` reports it.

## 2026-11-02 - M1 test 1: one-hour soak (v0.1.0)

60:38 with a YouTube talk playing in Chrome, `pids` strategy: 3,631.6 s of audio (99.8%
coverage), 0 gaps, CPU 1.4% of one core, peak memory 15.1 MB at minute one and at the end,
no browser process changes. Capture itself is solid for an hour.

The one failure was the supervisor's: the IO watchdog restarted the first tap at 2 s and
the second at 4 s because neither had delivered audio within 1.5 s of starting; the
third delivered audio 462 ms after starting. A new tap can take longer than 1.5 s to
begin delivering, so v0.1.1 gives new taps 5 s (`IOWatchdog.startupTimeout`) and keeps
1.5 s only for taps that have delivered audio. Restarts that are themselves restarted
before audio returns are now one outage, timed from the first restart. `spike-capture`
reports time to first audio so the real startup figure gets measured.

## 2026-11-02 - M1 test 2: taps are silent while nothing plays; retargeting works (v0.1.0)

Started `spike-capture` before Chrome, then opened Chrome and played a video:

- **In-place retargeting works** on macOS 26 (`kAudioTapPropertyDescription` accepted):
  1 retarget, 0 refused, the tap going from 1 to 3 Chrome processes within a second.
- The tap was restarted five times between 00:15 and 00:23, each after 1.5-2 s with no IO
  callbacks; audio arrived 510 ms after the last restart and then ran 2.5 minutes with 0
  gaps. Together with test 1 (three restarts before the video played), this shows a tap
  delivers IO callbacks only while a tapped process is playing. Silence is normal.
- **Decision:** the watchdog acts only while Core Audio reports a tapped process as
  playing (`kAudioProcessPropertyIsRunningOutput`, polled each second): 3 s for a tap with
  no audio yet, 1.5 s once audio has flowed, counted from when playing began. Audio
  resuming after more than 250 ms counts as a pause and is preceded by silence (up to
  5 s) to keep timestamps aligned. Coverage is reported, not graded. Shipped in v0.1.2;
  v0.1.1's 5 s startup allowance would still have restarted silent taps.

## 2026-11-02 - M1 test 2 re-run on v0.1.2: no false restarts

Chrome open, `spike-capture` started, video played after about 12 s, run for 3 minutes:
0 restarts, 0 gaps, first audio 12,244 ms after the tap started (at playback), CPU 1.4%,
memory flat at 14.8 MB.

Correction to the test 2 note: a tap delivers no IO callbacks until a tapped process
first plays, but once IO has started it continues through pauses, delivering silent
buffers (callbacks kept rising at an "idle" report while the audible count stood still).
The watchdog fix holds either way; pause filling simply rarely triggers.

## 2026-11-02 - M1 tests 3 and 4 (v0.1.2): device switches cost rebuilds

- **Test 4 PASS:** a new tab and a reload changed none of Chrome's audio processes (all
  tabs play through one audio process), so no retarget or rebuild was needed; 0 gaps.
- **Test 3, AirPods:** every output-device change rebuilt the tap, because its aggregate
  device is clocked by the output device. Outages: 589, 94, 2,360 and 203 ms. The
  2,360 ms one was a rebuild onto the AirPods while they were disconnecting (macOS
  flipped LG, AirPods, LG within three seconds). Silence fill kept the timeline aligned
  (3.23 s filled = the four outages).
- **Experiment:** `TapClock.tap` builds the aggregate device from the tap alone, as Apple's
  sample does. If the tap keeps delivering when Chrome changes outputs, device switches
  need no rebuild and the 2 s criterion becomes moot. `spike-capture --clock tap`
  (v0.1.3) runs it; default stays `output` until measured. Fallback if it fails:
  make-before-break rebuilds (start the new tap, keep the old one until the new one
  delivers).

## 2026-11-02 - M1 test 5 (v0.1.2): quit and reopen Chrome passes

Chrome quit mid-run: capture reported that Chrome had no audio processes and waited, with
no restarts or errors. Chrome reopened: capture resumed by itself about 15 s later with 0
gaps; 5 s of silence (the cap) was filled, so the timeline is 10 s short across a long
absence, as designed.
