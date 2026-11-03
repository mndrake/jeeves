Jeeves M0 spike tools (Apple silicon, macOS 26 or later)

1. Clear the download quarantine once, from Terminal in this folder:

       xattr -dr com.apple.quarantine .

   (Builds without a Developer ID signature are blocked otherwise.)

2. Run the M0 runbook in docs/M0.md, replacing `swift run [-c release] spike-x`
   with `./spike-x`. For example:

       ./spike-tap --list
       ./spike-tap --browser chrome --seconds 30          # default strategy: pids
       ./spike-stt --live --browser chrome --seconds 120
       ./spike-stt --live --seconds 60 --finalize-on-silence   # finalize experiment
       ./spike-vec --chunks 10000
       ANTHROPIC_API_KEY=sk-ant-... ./spike-claude --out claude.json

   macOS asks Terminal for "system audio recording" permission the first time a
   tap starts. If nothing appears, check System Settings > Privacy & Security.

3. M1 capture tests (docs/M1.md):

       ./spike-capture --minutes 60                        # soak test during a real call
       ./spike-capture --minutes 5 --report-every 10       # event tests: AirPods, new tab, quit Chrome

4. M2 transcript tests (docs/M2.md):

       ./asr/make-tts-eval.sh asr-eval
       ./spike-asr asr-eval/*.wav --terms asr/terms.txt
       ./spike-stt --live --seconds 120 --second-pass parakeet-boost

5. M3 knowledge base (docs/M3.md):

       ./spike-kb --db kb.sqlite --presets                 # index both Anthropic doc sites
       ./spike-kb --db kb.sqlite --add ~/Notes             # a Markdown folder or Obsidian vault
       ./spike-kb --db kb.sqlite --search "how long does a cached prompt stay warm"
       ./spike-kb --db kb.sqlite --eval retrieval/questions.tsv
       ANTHROPIC_API_KEY=sk-ant-... ./spike-kb --db kb.sqlite --ask "what does sonnet five five cost"

6. Question detection calibration (docs/QUESTIONS.md):

       ./spike-stt interview.wav --trace interview.jsonl    # or Settings > Save call traces in the app
       ANTHROPIC_API_KEY=sk-ant-... ./spike-qa label interview.jsonl   # drafts interview.labels.tsv; check it
       ./spike-qa replay interview.jsonl --verbose          # what Jeeves would have asked, scored
       ./spike-qa sweep *.jsonl                             # settings ranked against your labels
       ./spike-kb --db kb.sqlite --eval-lead-in retrieval/lead-in-questions.tsv

7. mock-anthropic.py is a local fake of the Claude API:
       python3 mock-anthropic.py &   then   ./spike-claude --base-url http://127.0.0.1:8765
