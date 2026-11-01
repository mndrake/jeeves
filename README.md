# Jeeves

A macOS call copilot for expert Q&A. Jeeves listens to the remote side of a browser-based
video call (Google Meet or Zoom web in Chrome or Safari), transcribes it on-device, detects
questions, instantly shows the best-matching passages from your knowledge base (Markdown
notes plus documentation sites such as Anthropic's), and streams a short, cited answer
from Claude underneath.

- Hardware: 2026 MacBook Air, Apple M5, 16 GB. OS: macOS 26 Tahoe or later.
- Stack: Swift 6 / SwiftUI, Core Audio process taps, Apple SpeechAnalyzer, SQLite (FTS5 + sqlite-vec), Anthropic Messages API.
- Audio and documents stay on the machine; only the detected question, a short transcript window and the retrieved passages are sent to Claude.

Planning documents:

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

Nothing is implemented yet; the plan is the deliverable of this phase.
