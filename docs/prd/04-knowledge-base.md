# PRD 04 - Knowledge Base: Sources, Ingestion and Indexing

Milestone: M3. Owner: `IndexerActor`. Status: v0.2 after interview.

## Problem
Answers are only useful if they come from the user's own material: Markdown notes and
documentation websites, mostly Anthropic's. Recall speed at call time is the top
priority, so every expensive step (fetching, cleaning, chunking, enrichment, embedding)
happens at ingest time and the call-time path is a pure local lookup.

## Goals
- Two source kinds, one pipeline: **Markdown folders** and **web sources**. Both end up as Markdown files on disk, then chunks in SQLite.
- Anthropic doc sites ingested completely from `llms.txt` with per-page `.md` fetches; no HTML scraping needed.
- Generic URLs supported with a cleaning fallback.
- Each chunk enriched offline with a context prefix and synthetic questions (Claude Haiku 5.5, Batch API) to maximize recall on terse documentation.
- Incremental: a changed note is searchable within 5 s; a changed web page within one refresh cycle.

## Non-goals
- Editing sources. PDFs/DOCX (can be added later as another normalizer). Google Drive. Images.

## Source adapters

| Adapter | Input | Normalization | Refresh |
|---|---|---|---|
| Markdown folder | path (Obsidian vault auto-detected via `.obsidian/`) | none; frontmatter, tags, wikilinks parsed to metadata | `FSEvents`, coalesced |
| `llms.txt` site | URL of an `llms.txt` (e.g. `https://platform.claude.com/llms.txt`, `https://code.claude.com/docs/llms.txt`) | parse index -> fetch each linked `.md` page -> save under `web/<host>/<path>.md` | scheduled (default every 24 h); conditional GET with `ETag`/`Last-Modified`; only changed pages re-processed |
| Single Markdown page | URL ending in `.md` | fetch and save | as above |
| Generic URL | any `http(s)` URL | 1) try `<url>.md`; 2) try `<origin>/llms.txt` and locate the page; 3) fetch HTML -> Swift readability pass -> Markdown; 4) if the result is short or garbled relative to page size, send HTML to Claude Haiku 5.5 (Batch) for conversion | as above |
| Site crawl (optional, M3 stretch) | root URL + max pages/depth | same-origin link following with the Generic URL path per page | as above |

All web content is cached as Markdown files, so the indexer only ever sees folders of
Markdown. Deleting a web source deletes its cache and chunks.

## Chunking
- Heading-aware split; target 250-400 tokens; 15% overlap on paragraph boundaries.
- Code blocks are never split mid-block; a chunk may be a single long code block.
- Each chunk carries: `docId`, `breadcrumb` (`title > H2 > H3`), `sourceURLorPath`, `tags`, `mtime`, stable `chunkId` (hash of path + heading path + ordinal).

## Enrichment (ingest time, offline)
Anthropic's contextual-retrieval technique, run with **Claude Haiku 5.5 via the Message
Batches API** (50% price, no latency constraint):
1. One request per chunk; the request's system prompt holds the **whole document** with a `cache_control` breakpoint (1-hour TTL, since batch items for one document are processed close together) and the user turn holds the chunk. Output: a 1-2 sentence context prefix and 2-3 natural questions this chunk answers, as structured output.
2. Stored as `contextPrefix` and `syntheticQuestions`. Indexed text = `contextPrefix + "\n" + chunkText`; questions are indexed as a separate FTS column and also embedded.
3. Settings: `thinking: {type: "disabled"}`, `output_config.effort: "low"`, `max_tokens: 400`. Batches are polled until `ended`; results keyed by `custom_id = chunkId`.
4. Enrichment is skippable per source (toggle) and resumable; chunks without enrichment are still indexed with raw text so the index is usable immediately and improves as batches complete.
5. Budget guard: show estimated cost before the first batch for a source (chunks x avg tokens x Haiku batch rate).

## Embedding and storage
- Local embedding model (chosen in M3; candidates `bge-small-en-v1.5` 384-d, `nomic-embed-text-v1.5` 768-d, `Qwen3-Embedding-0.6B` 1024-d) as CoreML or MLX; resident during indexing, kept warm during a session for query embedding.
- SQLite file `~/Library/Application Support/Jeeves/index.sqlite`: `documents`, `chunks` (FTS5 over `text`, `contextPrefix`, `breadcrumb`, `questions`), `embeddings` (`sqlite-vec`, one vector per chunk text and one per synthetic-question set).
- Vocabulary export: top proper nouns and rare terms (model names, API parameters) for STT hints (PRD 02).

## Functional requirements
1. Sources UI: add folder / add URL (auto-detects `llms.txt`, `.md`, generic); per-source counts, last refresh, enrichment progress, estimated and actual spend; enable/disable; delete.
2. Exclusions: `.gitignore`-style; defaults exclude `.obsidian/`, `.trash/`, templates.
3. Refresh schedule per web source; manual "refresh now"; refresh pauses during a live session.
4. Debug search window: type a query, see BM25 hits, vector hits, fused ranking, and timings.
5. Index deletable in one click; re-index from cache without re-fetching.

## Non-functional
- 2,000 Markdown notes indexed (without enrichment) in < 3 min; `platform.claude.com` (hundreds of pages) fetched and indexed in < 10 min on a normal connection.
- Incremental file change searchable in < 5 s.
- Query path (PRD 05) < 100 ms warm.
- No document content sent to Anthropic except for enrichment and HTML cleanup, both user-visible toggles with cost estimates.

## Acceptance criteria
- Vault + both Anthropic doc hosts indexed; page count matches `llms.txt` within 1%.
- Edit a note, save, query within 10 s: new text is retrievable.
- Change detection: a doc page updated upstream is re-fetched on the next refresh and only that page is re-embedded.
- Recall@3 >= 0.85 on the 60-question eval set (PRD 05), with enrichment on; report the delta enrichment makes.

## Open questions
- Other doc sites at launch (PLAN Q3)?
- Should synthetic questions be shown in the UI as "you might be asked" prep material? (nice-to-have)
