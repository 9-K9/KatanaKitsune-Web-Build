#!/usr/bin/env python3
"""Master ElevenLabs game audio and build a REAPER review project."""

from __future__ import annotations

import csv
import argparse
import json
import math
import os
import re
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "assets/audio/generated/raw"
OUT = ROOT / "assets/audio/generated/optimized"
MANIFEST = ROOT / "docs/audio/AUDIO_ASSET_MANIFEST.csv"
REPORT = ROOT / "docs/audio/AUDIO_MASTERING_REPORT.csv"
RPP = ROOT / "docs/audio/Katana_Kitsune_Generated_Audio.rpp"


def run(args: list[str]) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=True)
    return result.stdout


def probe(path: Path) -> dict:
    data = run(["ffprobe", "-v", "error", "-select_streams", "a:0",
                "-show_entries", "stream=sample_rate,channels:format=duration",
                "-of", "json", str(path)])
    parsed = json.loads(data)
    stream = parsed["streams"][0]
    return {"duration": float(parsed.get("format", {}).get("duration", 0)),
            "sample_rate": int(stream["sample_rate"]),
            "channels": int(stream["channels"])}


def peak_db(path: Path) -> float:
    text = run(["ffmpeg", "-hide_banner", "-i", str(path), "-af", "volumedetect",
                "-f", "null", "-"])
    match = re.search(r"max_volume:\s*(-?[0-9.]+) dB", text)
    return float(match.group(1)) if match else -99.0


def manifest_rows() -> list[dict[str, str]]:
    with MANIFEST.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def match_row(name: str, rows: list[dict[str, str]]) -> dict[str, str] | None:
    stem = Path(name).stem
    for row in rows:
        template = Path(row.get("Filename", "")).stem
        pattern = "^" + re.escape(template).replace(r"\{n\}", r"\d+") + "$"
        if re.match(pattern, stem):
            return row
    return None


def category_for(name: str) -> str:
    if name.startswith("amb_"):
        return "Ambience"
    if name.startswith("vox_"):
        return "Voices"
    if name.startswith("ui_"):
        return "UI"
    if name.startswith("sfx_enemy_"):
        return "Enemies"
    if name.startswith("sfx_"):
        return "SFX"
    return "Other"


def master_one(src: Path, row: dict[str, str] | None) -> dict[str, object]:
    original = probe(src)
    looped = bool(row and row.get("Loop", "").strip().lower() == "yes")
    requested_format = (row.get("Target Format", "WAV") if row else "WAV").strip().upper()
    extension = ".ogg" if requested_format == "OGG" else ".wav"
    target = OUT / (src.stem + extension)
    spatial = row.get("Spatial Audio", "Positional 2D") if row else "Positional 2D"
    channels = 2 if (looped or "Non-positional" in spatial) else 1

    with tempfile.TemporaryDirectory(prefix="katana_audio_") as temp_dir:
        clean = Path(temp_dir) / "clean.wav"
        if looped:
            trim_filter = "anull"
        else:
            trim_filter = ("silenceremove=start_periods=1:start_duration=0.01:"
                           "start_threshold=-50dB:stop_periods=-1:stop_duration=0.04:"
                           "stop_threshold=-50dB:window=0.01")
        run(["ffmpeg", "-y", "-hide_banner", "-i", str(src), "-af", trim_filter,
             "-ar", "48000", "-ac", str(channels), "-c:a", "pcm_f32le", str(clean)])
        cleaned = probe(clean)
        # Preserve intentionally very quiet clips when threshold trimming finds no
        # usable samples (common for subtle UI ticks and room-tone-like effects).
        if cleaned["duration"] <= 0.001:
            run(["ffmpeg", "-y", "-hide_banner", "-i", str(src), "-af", "anull",
                 "-ar", "48000", "-ac", str(channels), "-c:a", "pcm_f32le", str(clean)])
            cleaned = probe(clean)

        if looped:
            filters = "loudnorm=I=-24:LRA=12:TP=-2"
        else:
            measured_peak = peak_db(clean)
            gain = max(-12.0, min(12.0, -1.0 - measured_peak))
            duration = cleaned["duration"]
            fade = min(0.005, duration / 4)
            fade_out = max(0.0, duration - fade)
            filters = (f"afade=t=in:st=0:d={fade:.6f},"
                       f"afade=t=out:st={fade_out:.6f}:d={fade:.6f},"
                       f"volume={gain:.3f}dB,"
                       "alimiter=limit=0.891251:attack=1:release=20:level=false")

        codec = ["-c:a", "libvorbis", "-q:a", "5"] if extension == ".ogg" else ["-c:a", "pcm_s16le"]
        run(["ffmpeg", "-y", "-hide_banner", "-i", str(clean), "-af", filters,
             "-ar", "48000", "-ac", str(channels), *codec, str(target)])

    finished = probe(target)
    return {
        "source": str(src.relative_to(ROOT)),
        "output": str(target.relative_to(ROOT)),
        "category": category_for(src.name),
        "loop": "Yes" if looped else "No",
        "channels": finished["channels"],
        "sample_rate": finished["sample_rate"],
        "original_seconds": round(original["duration"], 4),
        "finished_seconds": round(finished["duration"], 4),
        "trimmed_seconds": round(max(0.0, original["duration"] - finished["duration"]), 4),
        "peak_dbfs": round(peak_db(target), 2),
    }


def write_report(records: list[dict[str, object]], report: Path = REPORT) -> None:
    fields = list(records[0])
    with report.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(records)


def rpp_quote(path: Path) -> str:
    return str(path).replace('"', '\\"')


def write_reaper_project(records: list[dict[str, object]], rpp: Path = RPP) -> None:
    by_category: dict[str, list[dict[str, object]]] = {}
    for record in records:
        by_category.setdefault(str(record["category"]), []).append(record)
    lines = [
        '<REAPER_PROJECT 0.1 "7.82/linux-x86_64" 1770000000',
        '  RIPPLE 0', '  GROUPOVERRIDE 0 0 0', '  AUTOXFADE 1',
        '  TEMPO 120 4 4', '  PLAYRATE 1 0 0.25 4',
    ]
    for category in ["SFX", "Enemies", "Voices", "UI", "Ambience", "Other"]:
        items = sorted(by_category.get(category, []), key=lambda r: str(r["output"]))
        if not items:
            continue
        lines.extend(['  <TRACK', f'    NAME "{category}"', '    PEAKCOL 16576',
                      '    BEAT -1', '    AUTOMODE 0'])
        cursor = 0.0
        for record in items:
            output = ROOT / str(record["output"])
            length = float(record["finished_seconds"])
            label = output.stem
            source_type = "VORBIS" if output.suffix == ".ogg" else "WAVE"
            lines.extend([
                '    <ITEM', f'      POSITION {cursor:.6f}', f'      LENGTH {length:.6f}',
                f'      NAME "{label}"', '      FADEIN 1 0.005 0 1 0 0',
                '      FADEOUT 1 0.005 0 1 0 0', '      <SOURCE ' + source_type,
                f'        FILE "{rpp_quote(output)}"', '      >', '    >'])
            cursor += length + 0.25
        lines.append('  >')
    lines.append('>')
    rpp.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", nargs="*", type=Path,
                        help="specific source files to master (defaults to every raw MP3)")
    parser.add_argument("--jobs", type=int, default=min(6, os.cpu_count() or 2),
                        help="parallel mastering jobs; use 1 on memory-constrained machines")
    parser.add_argument("--report", type=Path, default=REPORT,
                        help="CSV mastering report path")
    parser.add_argument("--rpp", type=Path, default=RPP,
                        help="REAPER review project path")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    rows = manifest_rows()
    sources = [path.resolve() for path in args.sources] if args.sources else sorted(RAW.glob("*.mp3"))
    if not sources:
        raise SystemExit("No source audio files found")
    missing = [path for path in sources if not path.is_file()]
    if missing:
        raise SystemExit("Missing source files: " + ", ".join(str(path) for path in missing))
    records: list[dict[str, object]] = []
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = {pool.submit(master_one, src, match_row(src.name, rows)): src for src in sources}
        for count, future in enumerate(as_completed(futures), 1):
            record = future.result()
            records.append(record)
            print(f"[{count}/{len(sources)}] {record['output']}", flush=True)
    records.sort(key=lambda record: str(record["output"]))
    report = args.report.resolve()
    rpp = args.rpp.resolve()
    report.parent.mkdir(parents=True, exist_ok=True)
    rpp.parent.mkdir(parents=True, exist_ok=True)
    write_report(records, report)
    write_reaper_project(records, rpp)
    print(f"Mastered {len(records)} assets into {OUT}")
    print(f"Report: {report}")
    print(f"REAPER project: {rpp}")


if __name__ == "__main__":
    main()
