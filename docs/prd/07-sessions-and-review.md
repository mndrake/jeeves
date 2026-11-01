# PRD 07 - Sessions, Recording and Post-call Review

Milestone: M5. Status: v0.2 after interview.

## Problem
Once the live loop works, the next value is memory: what was asked, what Jeeves
suggested, what the user actually said, and what could not be answered from the notes.
That last list is the best possible to-do list for improving the knowledge base.

## Goals
- Opt-in per-session persistence of transcript, questions, answers and timings, locally in SQLite.
- Post-call summary and gap list, exportable as Markdown into the user's Obsidian vault (closing the loop: Jeeves writes notes that Jeeves can later retrieve).
- Search across past sessions.

## Non-goals
- Audio recording to disk (v1 stores text only; audio recording is a possible later opt-in with explicit consent UX).
- Sharing sessions with other people.

## Functional requirements
1. Session lifecycle: starts on "Start listening", ends on stop or 10 min of silence; named by date + source app + optional user title.
2. Persistence toggle per session with a visible recording indicator in the menu bar; default **off** until the user turns it on in Settings, with a one-time notice that recording conversations may require consent in their jurisdiction.
3. Stored: final transcript segments (time, text), detected questions, retrieved passages, generated answers with model, citations and confidence, token usage and cost, stage timings.
4. Post-call view: summary (Claude Sonnet 5.5, effort `medium`), list of questions with answers, "weak match" list (the gaps in your notes), latency and spend stats for the session.
5. Export: Markdown file with frontmatter (`date`, `app`, `tags: [jeeves, call]`) into a configurable vault folder; the exported file is then indexed like any other note (optional toggle, since indexing your own past answers can create echo chambers).
6. Retention: auto-delete sessions after N days (default 90); delete-all button.
7. Session search: FTS over transcripts and answers; results link back to the session timeline.

## Non-functional
- Writing to SQLite never blocks the live path (write-behind queue).
- A 60-minute session is < 2 MB on disk.

## Acceptance criteria
- Run a call with persistence on; after the call the summary and gap list appear within 30 s; export lands in the vault and is searchable in Obsidian.
- Persistence off: nothing about the call remains on disk after the app quits (verified by inspecting the data directory).

## Open questions
- Export into the indexed vault (PLAN Q4)?
- Turn the weak-match list into suggested URLs to ingest (for example the Anthropic doc page that would have answered it)? Proposed v2.
