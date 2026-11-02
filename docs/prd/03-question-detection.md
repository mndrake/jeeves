# PRD 03 - Question Detection and Triggering

Milestone: M4. Owner stage: `DetectActor`. Status: v0.2 after interview.

## Problem
Jeeves should answer when a question is asked of the user, and stay quiet otherwise.
Firing on every sentence floods the overlay and burns the battery; missing real questions
makes the product useless. Transcripts arrive without reliable punctuation, and
questions are often indirect ("walk me through how you'd handle...", "I'm curious
about your pricing").

## Goals
- Detect questions and question-like requests directed at the user within 150 ms of the end of speech. Detection runs on the latest volatile (partial) transcript plus a silence check, not on final segments: M0 measured final-result lag at 828 ms p50 and 1,084 ms p95, but partials at 22 ms p50 (DECISIONS, 2026-11-02).
- Precision >= 0.85, recall >= 0.9 on a labelled set of the user's calls.
- Always offer a manual override: a global hotkey answers "the last thing said".

## Non-goals
- Understanding multi-party politics (who is asked). With one remote channel and no mic, every remote question is treated as addressed to the user. Without a mic channel Jeeves cannot know when the user is speaking; the debounce and Assist mode compensate.

## Detection pipeline
1. **Segment assembly.** Track the latest volatile result. When the audio level stays below the speech threshold for about 400 ms, treat the utterance as ended and use the partial text (tunable). When the final result arrives, replace the text and re-run retrieval only if it changed.
2. **Fast heuristics (sub-millisecond).** Fire if: trailing `?`; leading wh-word or auxiliary inversion ("can you", "do you", "what's your"); imperative request verbs ("tell me", "walk me through", "explain", "describe"); or rising-intonation flag if the STT engine exposes it. Suppress if: utterance < 3 words; identical question in the last 30 s; an answer for a near-identical query is already on screen.
3. **Model check for ambiguous cases (<= 100 ms).** Utterances that score "maybe" go to a tiny classifier: Apple Foundation Models framework (on-device, free) with a constrained `@Generable` output `{ isQuestion: Bool, directedAtUser: Bool, topic: String }`. Fallback when Foundation Models is unavailable: Claude Haiku 5.5 (`thinking: disabled`, effort `low`, structured output, `max_tokens` 64), accepting a ~300 ms network hop; the user can disable the cloud fallback.
4. **Context window.** On fire, package the question and the previous ~60 s of remote transcript for the retrieval stage.
5. **Debounce and merge.** If a second question arrives while an answer is streaming, the new question replaces it unless the user pinned the current answer.

## Manual triggers
- Global hotkey (default `⌥⌘J`): answer the last remote utterance regardless of detection.
- Hotkey with shift: answer the last 30 s as a whole ("what are they really asking").
- Click any transcript line in the overlay to answer it.
- Typed question box in the overlay for when the user wants to look something up quietly.

## Modes (Settings)
- **Auto** (default): heuristics + model.
- **Assist**: show a small "answer?" chip on detected questions; answer only on click/hotkey. Good for noisy multi-person meetings.
- **Manual**: hotkey only.

## Non-functional
- Detection adds <= 150 ms to the critical path.
- The classifier runs only on ambiguous utterances (expected < 30% of utterances) to protect battery.

## Evaluation
- `eval/detect/` labelled utterances from the user's calls (target 300+). Report precision/recall per mode; tune thresholds; store in `docs/DECISIONS.md`.

## Acceptance criteria
- Precision >= 0.85, recall >= 0.9 on the labelled set.
- A repeated or rephrased question within 30 s does not produce a duplicate panel entry.
- Hotkey path works even when detection is off or the model is unloaded.

## Open questions
- Default mode Auto or Assist (PLAN Q5)?
- Should Jeeves also react to non-questions that match the knowledge base strongly (for example someone states a wrong fact about the product)? Proposed: v2.
