#!/usr/bin/env python3
"""Split and master ElevenLabs multi-vocalization player voice takes.

The script deliberately runs ffmpeg serially.  It keeps the source recordings,
selects two substantial vocal bursts from every take, and writes compact mono
48 kHz game assets plus a REAPER review project.
"""

from __future__ import annotations

import csv
import math
import re
import subprocess
import wave
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "assets/audio/generated/raw/player_voice"
OUT = ROOT / "assets/audio/generated/optimized/player_voice"
FINAL = ROOT / "assets/audio/generated/final"
REPORT = ROOT / "docs/audio/PLAYER_VOICE_MASTERING_REPORT.csv"
RPP = ROOT / "docs/audio/Katana_Kitsune_Player_Voice.rpp"
THRESHOLD_DB = -42.0
MIN_SOUND = 0.14
PADDING = 0.035


def run(args: list[str]) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=True)
    return result.stdout


def duration(path: Path) -> float:
    text = run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                "-of", "default=nw=1:nk=1", str(path)])
    return float(text.strip())


def intervals(path: Path) -> list[tuple[float, float]]:
    """Return non-silent spans using the same conservative gate used in review."""
    text = run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af",
                f"silencedetect=noise={THRESHOLD_DB}dB:d=0.12", "-f", "null", "-"])
    total = duration(path)
    starts = [float(x) for x in re.findall(r"silence_start: ([0-9.]+)", text)]
    ends = [float(x) for x in re.findall(r"silence_end: ([0-9.]+)", text)]
    spans: list[tuple[float, float]] = []
    cursor = 0.0
    for silence_start, silence_end in zip(starts, ends):
        if silence_start - cursor >= MIN_SOUND:
            spans.append((cursor, silence_start))
        cursor = silence_end
    if total - cursor >= MIN_SOUND:
        spans.append((cursor, total))
    return spans


def rms_db(path: Path, start: float, end: float) -> float:
    """Measure a candidate without loading a whole take into memory."""
    with wave.open(str(path), "rb") as source:
        rate = source.getframerate()
        channels = source.getnchannels()
        width = source.getsampwidth()
        source.setpos(max(0, int(start * rate)))
        raw = source.readframes(max(1, int((end - start) * rate)))
    if width != 2:
        return -99.0
    count = len(raw) // 2
    if count == 0:
        return -99.0
    values = memoryview(raw).cast("h")
    power = sum(int(value) * int(value) for value in values) / count
    return 20.0 * math.log10(max(math.sqrt(power) / 32768.0, 1e-9))


def choose(path: Path) -> list[tuple[float, float, float]]:
    candidates = [(start, end, rms_db(path, start, end))
                  for start, end in intervals(path)]
    # Prefer clear, compact exertions. Keeping two per source gives every take
    # representation while avoiding dozens of near-duplicate micro-fragments.
    candidates = [item for item in candidates if item[1] - item[0] <= 1.25]
    candidates.sort(key=lambda item: (item[2], min(item[1] - item[0], 0.8)), reverse=True)
    return sorted(candidates[:2], key=lambda item: item[0])


def master(src: Path, start: float, end: float, target: Path) -> None:
    clip_start = max(0.0, start - PADDING)
    clip_end = min(duration(src), end + PADDING)
    clip_duration = clip_end - clip_start
    fade_out = max(0.0, clip_duration - 0.012)
    filters = (
        "highpass=f=75,lowpass=f=15500,"
        "acompressor=threshold=0.125:ratio=2.2:attack=5:release=55:makeup=1.35,"
        f"afade=t=in:st=0:d=0.008,afade=t=out:st={fade_out:.6f}:d=0.012,"
        # Short clips vary too much for source-gain alone.  Loudness matching
        # here keeps alternate takes perceptually close; true peak remains -3 dB.
        "loudnorm=I=-22:LRA=7:TP=-3,"
        "alimiter=limit=0.707946:attack=2:release=30:level=false"
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    run(["ffmpeg", "-y", "-hide_banner", "-ss", f"{clip_start:.6f}",
         "-t", f"{clip_duration:.6f}", "-i", str(src), "-af", filters,
         "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(target)])


def write_rpp(records: list[dict[str, object]]) -> None:
    lines = ['<REAPER_PROJECT 0.1 "7.82/linux-x86_64" 1770000000',
             '  RIPPLE 0', '  AUTOXFADE 1', '  TEMPO 120 4 4']
    cursor = 0.0
    for record in records:
        path = ROOT / str(record["output"])
        length = float(record["seconds"])
        lines.extend(['  <TRACK', f'    NAME "{path.stem}"', '    <ITEM',
                      f'      POSITION {cursor:.6f}', f'      LENGTH {length:.6f}',
                      f'      NAME "{path.stem}"', '      <SOURCE WAVE',
                      f'        FILE "{path}"', '      >', '    >', '  >'])
        cursor += length + 0.2
    lines.append('>')
    RPP.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    sources = sorted(RAW.glob("*_set_*/*.wav"))
    records: list[dict[str, object]] = []
    counters = {"movement": 0, "attack": 0}
    for source in sources:
        family = "attack" if "attack_set" in source.as_posix() else "movement"
        for start, end, level in choose(source):
            counters[family] += 1
            name = f"vox_kitsune_{family}_{counters[family]:02d}.wav"
            optimized = OUT / name
            master(source, start, end, optimized)
            final = FINAL / name
            final.write_bytes(optimized.read_bytes())
            record = {
                "source": str(source.relative_to(ROOT)),
                "source_start": round(start, 4),
                "source_end": round(end, 4),
                "source_rms_dbfs": round(level, 2),
                "output": str(final.relative_to(ROOT)),
                "seconds": round(duration(final), 4),
            }
            records.append(record)
            print(f"[{len(records):02d}] {name}", flush=True)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    with REPORT.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    write_rpp(records)
    print(f"Mastered {len(records)} voice clips serially")


if __name__ == "__main__":
    main()
