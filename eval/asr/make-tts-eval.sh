#!/usr/bin/env bash
# Makes synthetic-speech test files for spike-asr from read-aloud.txt (macOS).
#
#   ./make-tts-eval.sh [output-dir] [voice ...]
#   ./make-tts-eval.sh asr-eval Samantha Daniel     # list voices with: say -v '?'
#
# Each voice gives <output-dir>/tts-<voice>.wav (16 kHz mono) and a matching .txt
# reference. Synthetic speech is clean and evenly paced, so treat the result as a
# best case; a recording of you reading the same text through a call is the real test.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/read-aloud.txt"
out="${1:-asr-eval}"
shift || true
mkdir -p "$out"
voices=("$@")
if [[ ${#voices[@]} -eq 0 ]]; then voices=("default"); fi
for voice in "${voices[@]}"; do
  base="$out/tts-$voice"
  if [[ "$voice" == "default" ]]; then
    say -o "$base.aiff" -f "$script"
  else
    say -v "$voice" -o "$base.aiff" -f "$script"
  fi
  afconvert -f WAVE -d LEI16@16000 -c 1 "$base.aiff" "$base.wav"
  rm -f "$base.aiff"
  cp "$script" "$base.txt"
  echo "wrote $base.wav"
done
