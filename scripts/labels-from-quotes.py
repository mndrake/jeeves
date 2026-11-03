"""Turn quoted questions into a spike-qa .labels.tsv with exact times (docs/QUESTIONS.md).

    python3 labels-from-quotes.py call.jsonl quotes.txt call.labels.tsv

quotes.txt: one question per line, copied word for word from `spike-qa transcript`;
leave parts out by splitting the quote with ' || '. Lines starting with # are
comments. Quotes are matched in order against the trace's final transcript results,
so the start and end come from the recogniser's own timings."""
import json, re, sys
trace, spec, out = sys.argv[1:4]
words = []
for line in open(trace):
    e = json.loads(line)
    if e.get("type") == "update" and e.get("final"):
        words.append((e["start"], e["end"], e["text"]))
norm = lambda w: re.sub(r"[^a-z0-9']", "", w.lower())
toks = [norm(w[2]) for w in words]
cursor = 0
rows = []
for raw in open(spec):
    raw = raw.strip()
    if not raw or raw.startswith("#"): continue
    parts = [p.strip() for p in raw.split("||")]
    spans = []
    for p in parts:
        target = [t for t in (norm(x) for x in p.split()) if t]
        found = None
        for i in range(cursor, len(toks) - len(target) + 1):
            if toks[i:i + len(target)] == target:
                found = i; break
        if found is None:
            sys.exit(f"not found after word {cursor}: {p!r}")
        spans.append((found, found + len(target) - 1))
        cursor = found + len(target)
    start, end = words[spans[0][0]][0], words[spans[-1][1]][1]
    text = " ".join(" ".join(words[k][2] for k in range(a, b + 1)) for a, b in spans)
    rows.append(f"{start:.2f}\t{end:.2f}\t{text}")
open(out, "w").write("# hand-labelled from the transcript (verbatim fragments)\n" + "\n".join(rows) + "\n")
print(out, len(rows), "labels")
