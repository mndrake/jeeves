"""Make a call trace without a Mac (docs/QUESTIONS.md): transcribe a 16 kHz mono WAV
with faster-whisper and write JSON Lines that spike-qa replays. Levels are 50 ms RMS
in dBFS from the real audio; each word is one final transcript result, available
0.25 s after it ends. Used for the v0.5 calibration set; on a Mac, prefer
`spike-stt recording.wav --trace call.jsonl`, which uses the recogniser the app uses.

    pip install faster-whisper numpy soundfile
    ffmpeg -i episode.mp3 -ss 600 -t 900 -ac 1 -ar 16000 excerpt.wav
    python3 whisper-trace.py excerpt.wav excerpt.jsonl excerpt
"""
import json, sys, datetime
import numpy as np, soundfile as sf
from faster_whisper import WhisperModel

wav, out, name = sys.argv[1], sys.argv[2], sys.argv[3]
audio, rate = sf.read(wav, dtype="float32")
step = 0.05; n = int(rate * step)
frames = len(audio) // n
rms = np.sqrt(np.mean(audio[: frames * n].reshape(frames, n) ** 2, axis=1) + 1e-12)
db = np.maximum(20 * np.log10(rms), -160)

model = WhisperModel("small.en", device="cpu", compute_type="int8", cpu_threads=4)
segments, _ = model.transcribe(audio, word_timestamps=True, vad_filter=False, beam_size=5,
                               condition_on_previous_text=True)
words = [w for s in segments for w in (s.words or [])]

with open(out, "w") as f:
    f.write(json.dumps({"type": "header", "version": 1, "source": "file", "name": name,
                        "engine": "faster-whisper small.en",
                        "created": datetime.datetime.now(datetime.timezone.utc).isoformat()}) + "\n")
    events = []
    for i in range(0, frames, 20):
        events.append((i * step, {"type": "levels", "t": round(i * step, 3), "step": step,
                                  "db": [round(float(x), 1) for x in db[i:i + 20]]}))
    for w in words:
        events.append((w.end + 0.25, {"type": "update", "text": w.word.strip(), "final": True,
                                      "start": round(w.start, 3), "end": round(w.end, 3), "at": round(w.end + 0.25, 3)}))
    events.sort(key=lambda e: e[0])
    for _, e in events: f.write(json.dumps(e) + "\n")
print(out, len(words), "words")
