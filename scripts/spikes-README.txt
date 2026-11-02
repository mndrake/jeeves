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

3. mock-anthropic.py is a local fake of the Claude API:
       python3 mock-anthropic.py &   then   ./spike-claude --base-url http://127.0.0.1:8765
