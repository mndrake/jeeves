# PRD 05 - Retrieval and Answer Generation

Milestones: M3 (retrieval), M4 (generation). Owner: `AnswerActor`. Status: v0.2 after interview.

## Problem
Given a detected question and recent transcript, show the most relevant passages from the
user's knowledge base immediately, then stream a short synthesized answer from Claude.
Recall speed is paramount; the answer is a bonus layered on top of passages that are
already visible.

## Goals
- Phase 1: top 3 passages with breadcrumbs on screen within 100 ms of detection (all local).
- Phase 2: Claude answer first token within ~900 ms of detection; complete in < 3 s.
- Grounded: every claim traceable to a shown passage; explicit "not in your notes" when retrieval is weak.
- Model per task, user-switchable: Sonnet 5.5 default, Haiku 5.5 fast mode, Opus 5.5 deep mode.

## Non-goals
- Multi-turn chat UI (one typed follow-up is supported). Fine-tuning. Local LLM.

## Retrieval (Phase 1, local)
1. Query = question text + salient nouns from the previous 60 s of remote transcript (Apple `NaturalLanguage` tagger).
2. Lexical: FTS5 BM25 over `text`, `contextPrefix`, `breadcrumb`, `questions`; top 20.
3. Semantic: embed query locally; `sqlite-vec` cosine over chunk vectors and synthetic-question vectors; top 20.
4. Reciprocal rank fusion; dedupe by heading; top 3 displayed, top 6 sent to Claude (<= ~1,500 tokens).
5. Confidence: fused score below threshold -> `lowConfidence`; UI shows "weak match" and Claude is told to say so.
6. Boosts: small recency boost for recently modified notes; optional per-session source filter ("only Anthropic docs", "only my notes").
7. Budget: embed <= 20 ms, both searches <= 40 ms, fusion <= 5 ms. Warm SQLite connection and resident embedding model.

## Generation (Phase 2, Claude via Anthropic API)

### Client
No official Swift SDK exists, so Jeeves ships a small `AnthropicClient` module:
- `POST https://api.anthropic.com/v1/messages`, headers `x-api-key`, `anthropic-version: 2026-10-21`, `content-type: application/json`, plus `anthropic-beta` when needed.
- `stream: true`; parse SSE events (`message_start`, `content_block_delta` with `text_delta`, `message_delta` with `stop_reason` and `usage`, `message_stop`); feed deltas to the overlay.
- Cancellation via `URLSessionTask.cancel()` when a newer question supersedes.
- Retries: 429/5xx/connection errors with exponential backoff (2 tries max on the live path; the passages are already visible so give up quickly and show "answer unavailable").
- Errors mapped to UI states: invalid key, rate limited, offline, refusal.

### Request shape (live answer, default)
```json
{
  "model": "claude-sonnet-5-5",
  "max_tokens": 300,
  "stream": true,
  "thinking": {"type": "between_tools"},
  "output_config": {"effort": "low"},
  "fallbacks": "default",
  "system": [
    {"type": "text", "text": "<role, answer-style guide, persona, citation rules - static, >= 512 tokens>",
     "cache_control": {"type": "ephemeral"}}
  ],
  "messages": [
    {"role": "user", "content": "<passages [1]..[6] with breadcrumbs>\n\n<last 40 s of transcript>\n\nQuestion: <question>"}
  ]
}
```
with header `anthropic-beta: server-side-fallback-2026-07-01`. Notes:
- `thinking: {type: "between_tools"}` is how thinking is turned off on Sonnet 5.5 (`disabled` is rejected); allowed at effort `high` or below. On Haiku 5.5 use `thinking: {type: "disabled"}`. On Opus 5.5 thinking cannot be turned off; use effort `low`/`medium` and accept the extra latency in "deep" mode.
- `fallbacks: "default"` lets the API retry a safety-classifier refusal on another model server-side. **Do not send `fallbacks` on Haiku 5.5** (no server-side fallback; a list returns 400). Always check `stop_reason == "refusal"` before reading content; on refusal, keep the passages on screen and show "Claude declined; passages only".
- No `temperature`/`top_p`/`top_k` (rejected on this API version). No assistant prefill (rejected).
- Prompt caching: the system block is static and padded to clear the 512-token minimum; verify `usage.cache_read_input_tokens > 0` on the second request of a session and surface a cache-hit indicator in Diagnostics. The 5-minute TTL is refreshed by every question; questions more than 5 minutes apart pay one cache write.
- `max_tokens` 300 is a deliberate cap for a glanceable answer; "more" re-asks with 1,200.

### Model selection
| Mode | Model | Thinking | Effort | When |
|---|---|---|---|---|
| Default | `claude-sonnet-5-5` | `between_tools` (off) | `low` | every detected question |
| Fast | `claude-haiku-5-5` | `disabled` | `low` | user toggle; lowest TTFT and cost |
| Deep | `claude-opus-5-5` | adaptive (cannot disable) | `low` or `medium` | hotkey or "deeper" button; multi-document synthesis |
| Auto (M5 stretch) | Haiku -> Sonnet -> Opus | | | pick by retrieval confidence and question length; measured in eval before enabling |

### Prompt content
1. System (static, cached): "You are an expert's reference assistant. Answer only from the passages; cite as [n]; if the passages do not cover it, say so in one line and stop. Neutral, precise, no preamble." Plus the answer-style guide (bullets, <= 60 words, key fact first) and the user's short profile.
2. User turn: passages, recent transcript, the question.
3. Output: 3-5 terse bullets with `[n]` citations; or, in `lowConfidence`, one line stating the notes do not cover it, optionally followed by a clearly labelled general-knowledge answer if the user enabled that in Settings.

### Follow-ups
Typed "more", "shorter", "example", or a free-text follow-up re-sends with the previous
answer appended as an assistant turn (append-only history; thinking blocks, if any, passed
back unchanged).

### Spend and safety
- Per-question token usage from `message_delta.usage` is logged; Settings shows session and daily spend; a daily cap pauses Phase 2 (Phase 1 keeps working).
- Only passages, a 40 s transcript window and the question are sent. Never audio, never the full transcript, never documents outside the retrieved chunks.

## Evaluation
- `eval/rag/`: 60 questions over the real vault and the Anthropic docs with gold chunk IDs and gold answers.
  - Retrieval: recall@3, recall@6, MRR; with and without enrichment.
  - Generation: faithfulness and correctness judged offline by Claude Opus 5.5 (effort `high`), plus a manual pass on 20 items; per model mode.
  - Latency: phase 1 and phase 2 TTFT distributions on the Air during a live call, per model.
- Results and chosen defaults in `docs/DECISIONS.md`.

## Acceptance criteria
- Recall@3 >= 0.85; faithfulness >= 0.9 (no unsupported claims) in Default mode.
- Phase 1 p95 <= 1.0 s and Phase 2 first token p95 <= 2.0 s from end of question, over 50 live questions.
- Cache hit indicator shows reads on every question after the first in a session.
- Refusal, offline, invalid-key and rate-limit states each render correctly with passages still visible.

## Open questions
- Hard cap of ~60 words (PLAN Q1)? Daily spend cap (PLAN Q2)?
- Enable "Auto" model routing in v1 or leave as a later experiment? (later)
