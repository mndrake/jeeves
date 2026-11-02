# Jeeves

A macOS call copilot for expert Q&A. Jeeves listens to the remote side of a browser-based
video call (Google Meet or Zoom web in Chrome or Safari), transcribes it on-device, detects
questions, instantly shows the best-matching passages from your knowledge base (Markdown
notes plus documentation sites such as Anthropic's), and streams a short, cited answer
from Claude underneath.

- Hardware: 2026 MacBook Air, Apple M5, 16 GB. OS: macOS 26 Tahoe or later; developed on macOS 27 with Xcode 27.
- Stack: Swift 6 / SwiftUI, Core Audio process taps, Apple SpeechAnalyzer, SQLite (FTS5 + sqlite-vec), Anthropic Messages API.
- Audio and documents stay on the machine; only the detected question, a short transcript window and the retrieved passages are sent to Claude.

Planning documents:

- `docs/M0.md` - M0 runbook, results table and exit criteria
- `docs/M1.md` - M1 capture resilience tests and results
- `docs/M2.md` - M2 speech-engine comparison and live transcript tests

- `docs/PLAN.md` - vision, architecture, decisions, latency budget, milestones M0-M6, risks, open questions
- `docs/prd/01-audio-capture.md` - browser audio via Core Audio process taps
- `docs/prd/02-transcription.md` - on-device streaming speech to text
- `docs/prd/03-question-detection.md` - detecting questions and manual triggers
- `docs/prd/04-knowledge-base.md` - Markdown folders, `llms.txt` doc sites, ingest-time enrichment, indexing
- `docs/prd/05-retrieval-and-answers.md` - local hybrid retrieval, Claude client, model per task
- `docs/prd/06-live-overlay-ui.md` - two-phase overlay panel and menu bar
- `docs/prd/07-sessions-and-review.md` - opt-in session memory and post-call review
- `docs/prd/08-settings-privacy-models.md` - settings, API key, spend, privacy, distribution
- `docs/DECISIONS.md` - interview answers and decision log

## Status

Milestone M0 (spikes and skeleton) is complete: audio capture, on-device transcription,
local search and Claude answers all meet the latency plan on the MacBook Air. See
`docs/M0.md` for results and `docs/DECISIONS.md` for what they decided. M1 (capture
that survives a whole call) is accepted. M2 (transcript accuracy: Apple vs Parakeet, and
a Parakeet second pass) is code complete; its tests are in `docs/M2.md`.

## Download

Every push builds the app and spike tools on GitHub Actions. To publish a release, run
the **macOS build** workflow from the Actions tab with a version such as `v0.0.1`.
Install the newest release from Terminal:

```bash
curl -fL -o /tmp/Jeeves.zip https://github.com/mndrake/jeeves/releases/latest/download/Jeeves-macOS-arm64.zip
rm -rf /Applications/Jeeves.app && ditto -x -k /tmp/Jeeves.zip /Applications
open /Applications/Jeeves.app
```

`docs/M0.md` covers browser downloads of the unsigned build and the spike tools.

## Development

```bash
swift test                                   # macOS 26+ or Linux; Swift 6.2+
swift run spike-claude --dry-run             # see the Claude request bodies
swift run -c release spike-vec               # index latency on a synthetic corpus
cd App && xcodegen && open Jeeves.xcodeproj  # menu bar app (macOS, Xcode 27)
```

`scripts/vendor-sqlite.sh` re-vendors SQLite and sqlite-vec at pinned versions.
`scripts/mock-anthropic.py` serves a local streaming mock of the Messages API.
