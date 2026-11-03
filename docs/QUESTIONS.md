# Question detection: testing and calibration (v0.5.0)

How Jeeves decides that someone asked a question, how much of what they said it keeps,
and how to measure and tune that on your own recordings.

## What was wrong in v0.4

Every pause of 400 ms ended an "utterance", and detection looked at that utterance
alone. A question set up over several sentences, with pauses between them,

> We run a support bot on Sonnet. The system prompt is about twenty thousand tokens.
> How do we make that cheaper?

reached search and Claude as "How do we make that cheaper?". Replaying five
recorded interviews (below) showed two more problems that matter as much:

- **False triggers.** 95 in 75 minutes, mostly tag questions ("It's great for local
  stuff, right?") and half-finished phrases at a pause ("how many, you know").
- **Missed questions.** A question split across pauses ("and can you maybe" / "just
  for the uninitiated" / "give a version of what DuckDB does") has no piece that reads
  as a question on its own.

## What v0.5 does

| Step | What happens |
|---|---|
| End of speech | 400 ms of quiet ends a phrase, as before. "Quiet" now means below the fixed -45 dBFS **or** within 12 dB of the measured noise floor, so recordings with room tone or a music bed still split into phrases. |
| Turn | Phrases joined across pauses of up to 1.2 s, reaching back at most 20 s, never into an earlier question. |
| Detection | Runs on the end of the whole turn, not just the last phrase. Ignores tag questions ("..., right?", "you know?"), waits when a phrase stops mid-sentence ("...and can you maybe"), finds questions that start mid-sentence ("...it's like, what happens if you bring DuckDB into Postgres") and knows more request phrases ("help me unpack", "tell me more"). |
| Lead-in | What the speaker said before the question sentence (up to 80 words). Shown in grey above the question in the panel. |
| Reply boundary | Right after a question mark, a sentence that opens like a reply ("Yeah, great question...", "So I think...") ends the question, even with no pause. So does a first-person answer to a "you" question ("Do you have numbers? We don't yet..."). Videos and podcasts rarely leave a gap between speakers. |
| Mid-speech asking | That boundary is checked on every transcript update while someone is still talking. The question is asked the moment the reply starts, not when the reply finally pauses 10 to 20 s later. |
| Follow-up | Speech within 2 s of a question that is not a reply revises it ("...I mean specifically for the batch API"), and the panel answers it again, marked "updated". A follow-up that is itself a question ("...and what about Opus?") is asked as a new question, with the first one as its lead-in. |
| Final text | When the recogniser's final text for a phrase arrives, detection re-runs if the provisional text had stopped short ("what's the price of the"). |
| Search | The last 30 words of the lead-in are searched with the question. |
| Claude | Gets the lead-in in its own block, with instructions to answer the question as the lead-in frames it and to ignore unrelated earlier talk. |

The values to tune (phrase-end pause, join gap, lookback, follow-up window) are in
**Settings > Question detection**; the rules are fixed.

## How to test and calibrate

The loop is: record → label → replay → sweep → set.

### 1. Record a call trace

A trace is a JSON Lines file of audio levels (one per 50 ms) and every transcript
result with the moment it arrived. It holds no audio. Replaying it reproduces exactly
what Jeeves saw, so the same recording can be tested with any settings.

- **From the app:** Settings > Question detection > **Save call traces for
  calibration**, then listen as usual (play the video in Chrome). Each session is
  saved to `~/Library/Application Support/Jeeves/traces/call-<date>.jsonl`; **Show
  traces** opens the folder.
- **From a recording** (faster than real time, same Apple recogniser):

  ```bash
  ./spike-stt interview.wav --trace interview.jsonl
  ```

  Any audio format AVFoundation reads works (`.m4a`, `.mp3`, `.wav`). For a YouTube
  video, save its audio first, for example `yt-dlp -x --audio-format m4a <url>`.

### 2. Label the questions

Labels are `<trace>.labels.tsv` next to the trace. Each line holds a start time, an end
time and the full question as it should be understood, set-up included. Copy the
speaker's own words, because scoring compares words.

```
# start   end      question
 61.40    74.10    We run a support bot on Sonnet. The system prompt is about twenty thousand tokens. How do we make that cheaper?
 2:13.8   2:25.7   So in that uptick of data for using Codex for financial applications, what did you learn?
```

There are two ways to make the file:

- `ANTHROPIC_API_KEY=sk-ant-... ./spike-qa label interview.jsonl` asks Claude (Opus 5.5)
  to draft the file. Check every line: delete non-questions, add missed ones, trim the
  wording.
- `./spike-qa transcript interview.jsonl` prints the phrases with times, so you can
  write the file by hand. Or paste the questions word for word into a text file, one
  per line, and let `scripts/labels-from-quotes.py` find their exact times.

Label only questions you would want answered. Rhetorical questions, banter and
"…, right?" checks should not be labelled, so that triggering on them counts as a
false trigger.

### 3. Replay and score

```bash
./spike-qa replay interview.jsonl --verbose
```

This prints every labelled question next to what Jeeves would have asked (lead-in and
question), then the misses and the false triggers. The summary line reports:

| Measure | Meaning |
|---|---|
| asked | Share of labelled questions that triggered an answer |
| complete | Share whose asked text holds at least 80% of the label's content words |
| coverage | Mean share of each label's content words that the asked text holds (missed questions count as 0); "first ask" is the same before any follow-up revision |
| extra | Share of the asked text's words that are not in the label: earlier talk or the reply dragged in |
| false | Questions asked that match no label |
| asked after / final after | Median seconds from the end of the question to the first answer and to the last revision. Negative means Jeeves asked before the speaker finished, then revised. |

Any setting can be overridden: `--silence-ms 400 --gap 1.2 --lookback 20 --follow 2
--lead-words 80 --noise-margin 12`. `--v04` replays the v0.4 behaviour for comparison.

### 4. Sweep

```bash
./spike-qa sweep a.jsonl b.jsonl c.jsonl
./spike-qa sweep *.jsonl --silence-ms 300,400,500 --gap 0.8,1.2,1.5 --lookback 10,20,30 --follow 0,1,2,3
```

The sweep ranks every combination by `coverage x (1 - extra) - 0.25 x false triggers
per label` and prints the current default and v0.4 for reference. The score is a
starting point, not the answer: a setting that misses half the questions can rank well
by never triggering, so also read the `complete`, `asked` and `false` columns.

### 5. Set

Enter the chosen values in Settings > Question detection. **Restore defaults** goes
back to the values below.

## Calibration results (defaults)

Recordings: five 15-minute excerpts of technical interview podcasts (75 minutes),
transcribed with faster-whisper small.en (word timings, punctuation) into traces with
the real audio levels. Each excerpt has two speakers and no speaker labels, which is
like playing an interview video. I labelled 28 questions by hand from the transcripts.
The recordings and labels are not in the repository because they come from
third-party podcasts. The sources are:

| Trace | Episode | Excerpt |
|---|---|---|
| cl-postgres | The Changelog #688, "The future is Postgres" | 10:00-25:00 |
| cl-nanoclaw | The Changelog #686, "From zero to NanoClaw" | 20:00-35:00 |
| ls-finance | Latent Space, "Building ChatGPT for Finance" | 2:00-17:00 |
| ls-leash | Latent Space, "An Eval for AI Scientists That Knows the Answer Key" | 0:30-15:30 |
| cl-whatsnext | The Changelog #687, "Building what's next" | 30:00-45:00 |

All five, with the final rules:

| Setting | asked | complete | coverage | extra | false triggers |
|---|---|---|---|---|---|
| v0.4 as shipped | 64% | 4% | 0.19 | 0.09 | 95 |
| v0.5 defaults (400 ms, gap 1.2 s, lookback 20 s, follow-up 2 s) | 82% | 54% | 0.64 | 0.43 | 38 |
| Same with 300 ms phrase ends | 86% | 61% | 0.70 | 0.45 | 40 |
| Same with 500 ms phrase ends (fewest false triggers) | 71% | 39% | 0.54 | 0.49 | 24 |

Held-out checks, each labelled before it was replayed:

| Trace | When | v0.4 | v0.5 |
|---|---|---|---|
| ls-leash, 12 questions | after tuning on the first three | asked 42%, complete 8%, coverage 0.19, 11 false | asked 33%, complete 33%, coverage 0.33, 5 false |
| cl-whatsnext, 5 questions | after all changes | asked 100%, complete 0%, coverage 0.28, 25 false | asked 80%, complete 40%, coverage 0.64, 10 false |

The first held-out trace exposed the problems that mid-speech asking and the
first-person reply rule fix. With them, that trace reaches asked 75%, complete 67%, but
it was then tuning data, so cl-whatsnext is the clean check.

"extra" is high because, without speaker labels, the lead-in often includes the end of
the other person's last answer. Claude is told to ignore lead-in text that has nothing
to do with the question.

I kept 400 ms phrase ends. 300 ms scores better here, but the traces come from
Whisper, whose word timings are cleaner than Apple's provisional text at a pause.
Record a few traces of your own videos and run
`spike-qa sweep --silence-ms 300,400,500` to decide.

Lead-in retrieval (`spike-kb --eval-lead-in retrieval/lead-in-questions.tsv`, 26
set-up questions, 8 of them with an unrelated lead-in):

| Search query | recall@1 | recall@3 | recall@6 |
|---|---|---|---|
| Question alone | 0.19 | 0.31 | 0.35 |
| Last 30 lead-in words + question (v0.5) | 0.42 | 0.58 | 0.65 |
| Both, fused by rank | 0.31 | 0.54 | 0.65 |

## Known limits

- **No speaker labels.** When the reply starts with no pause and with no reply opener
  ("What happens with the weaker models? They'll just keep..."), the question is
  missed or the reply leaks into it. Most remaining misses are this. Speaker
  diarization (FluidAudio has it) is the next step.
- **Rhetorical questions** that a speaker answers themselves still trigger. Most of
  the 38 false triggers are these.
- **Long monologue questions** (two minutes, several "how do you feel about…"
  sentences) are cut to the last 80 words of lead-in. Claude still gets the recent
  transcript.
- **Small, self-labelled sample.** I wrote the rules while looking at four of the five
  excerpts, so their numbers flatter the result. cl-whatsnext is the fairer number.
- On a real call only the remote side is captured and you answer on your microphone,
  so replies don't follow questions instantly. That case should be easier than
  videos.
