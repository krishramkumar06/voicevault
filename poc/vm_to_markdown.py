#!/usr/bin/env python3
"""
vm_to_markdown.py

Batch-convert a folder of Apple Voice Memos (.m4a) into sidecar Markdown notes.

For each <name>.m4a it writes <name>.md next to it, containing:
  - YAML frontmatter (title, created, duration, source, suggested tags/people)
  - a short prose distillation + key-point bullets (local Ollama)
  - the verbatim transcript (Apple SpeechAnalyzer via `yap`)

Everything runs on-device: `yap` (Apple Speech.framework) for transcription,
Ollama for the summary. No audio or text leaves the machine.

Requirements (macOS 26 Tahoe):
  brew install finnvoor/tools/yap ffmpeg
  ollama running, with a model pulled, e.g. `ollama pull qwen3.5`

Usage:
  python3 vm_to_markdown.py /path/to/folder            # whole folder
  python3 vm_to_markdown.py /path/to/folder --limit 1  # validate on one first
  python3 vm_to_markdown.py /path/to/folder --force     # overwrite existing .md
"""

from __future__ import annotations
import argparse, json, sqlite3, subprocess, urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---- Config -----------------------------------------------------------------
MODEL   = "qwen3.5:latest"   # <- set to whatever you `ollama pull`ed
NUM_CTX = 16384              # big enough for a 30-min memo; default 4096 SILENTLY truncates
OLLAMA  = "http://localhost:11434/api/chat"

# Optional: recover the nice user-facing Voice Memos titles instead of filenames.
# Leave as None to title notes by filename. If you enable it, confirm the two
# column names against your own DB first:
#   sqlite3 '<path>/CloudRecordings.db' '.schema ZCLOUDRECORDING'
VOICE_MEMOS_DB = None
# e.g. Path.home() / "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db"

SYSTEM_PROMPT = """You are archiving a personal voice-memo brain dump for later retrieval in an Obsidian vault.
Return JSON only, no commentary.
- distillation: 2 to 3 sentences of plain declarative prose, no em dashes, saying what this memo is actually about.
- key_points: 3 to 6 short bullets capturing the substantive ideas, not filler or throat-clearing.
- tags: 2 to 6 lowercase hyphenated topic tags. Reuse conventional tags; do not invent baroque ones.
- people: names of specific people the speaker mentions by name. Empty list if none.
"""

SCHEMA = {
    "type": "object",
    "properties": {
        "distillation": {"type": "string"},
        "key_points":   {"type": "array", "items": {"type": "string"}},
        "tags":         {"type": "array", "items": {"type": "string"}},
        "people":       {"type": "array", "items": {"type": "string"}},
    },
    "required": ["distillation", "key_points", "tags", "people"],
}

# ---- Steps ------------------------------------------------------------------

def transcribe(path: Path) -> str:
    r = subprocess.run(["yap", "transcribe", str(path), "--txt"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"yap failed: {r.stderr.strip()}")
    return r.stdout.strip()

def probe(path: Path):
    """(duration_seconds, created_iso) from ffprobe; fall back to file mtime."""
    duration, created = None, None
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", str(path)],
            capture_output=True, text=True)
        fmt = json.loads(r.stdout).get("format", {})
        if fmt.get("duration"):
            duration = float(fmt["duration"])
        created = (fmt.get("tags") or {}).get("creation_time")
    except Exception:
        pass
    if not created:
        created = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).isoformat()
    return duration, created

def apple_title(path: Path):
    """Best-effort user-facing title from CloudRecordings.db; None if unavailable."""
    if not VOICE_MEMOS_DB:
        return None
    try:
        con = sqlite3.connect(f"file:{VOICE_MEMOS_DB}?mode=ro", uri=True)
        row = con.execute(
            "SELECT ZCUSTOMLABEL FROM ZCLOUDRECORDING WHERE ZPATH LIKE ?",
            (f"%{path.name}",)).fetchone()
        con.close()
        return row[0] if row and row[0] else None
    except Exception:
        return None

def summarise(transcript: str, model: str) -> dict:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user",   "content": transcript},
        ],
        "format": SCHEMA,
        "stream": False,
        "options": {"num_ctx": NUM_CTX, "temperature": 0.2},
    }
    req = urllib.request.Request(
        OLLAMA, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        body = json.loads(resp.read())
    return json.loads(body["message"]["content"])

# ---- Assembly ---------------------------------------------------------------

def hhmmss(seconds):
    if not seconds:
        return ""
    s = int(round(seconds))
    return f"{s // 60}:{s % 60:02d}"

def yaml_list(items):
    return "[" + ", ".join(items) + "]" if items else "[]"

def build_markdown(title, created, duration, source_name, data, transcript):
    people = data.get("people") or []
    tags = data.get("tags") or []
    lines = [
        "---",
        f'title: "{title}"',
        f"created: {created}",
        f'duration: "{hhmmss(duration)}"',
        "type: voice-memo",
        f"source: ./{source_name}",
        "transcription: apple-speechanalyzer",
        "---",
        "",
        "## Summary",
        "",
        (data.get("distillation") or "").strip(),
        "",
    ]
    for pt in data.get("key_points", []):
        lines.append(f"- {pt}")
    lines += [
        "",
        "## Suggested (review before filing)",
        "",
        "Suggested people: " + (", ".join(people) if people else "(none)"),
        "Suggested tags: " + (", ".join(tags) if tags else "(none)"),
        "",
        "---",
        "",
        "## Transcript",
        "",
        transcript,
        "",
    ]
    return "\n".join(lines)

# ---- Driver -----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", type=Path)
    ap.add_argument("--limit", type=int, default=None, help="process at most N files (use 1 to validate)")
    ap.add_argument("--force", action="store_true", help="overwrite existing .md sidecars")
    ap.add_argument("--model", default=MODEL)
    args = ap.parse_args()

    files = sorted(args.folder.glob("*.m4a"))
    if args.limit:
        files = files[:args.limit]
    if not files:
        print("No .m4a files found."); return

    for i, path in enumerate(files, 1):
        out = path.with_suffix(".md")
        if out.exists() and not args.force:
            print(f"[{i}/{len(files)}] skip (exists): {path.name}"); continue
        print(f"[{i}/{len(files)}] {path.name}")
        try:
            transcript = transcribe(path)
            if not transcript:
                out.write_text(
                    f'---\ntitle: "{path.stem}"\ntype: voice-memo\n'
                    f"source: ./{path.name}\nstatus: no-transcript\n---\n\n(No speech transcribed.)\n")
                print("   ! empty transcript, flagged"); continue
            duration, created = probe(path)
            title = apple_title(path) or path.stem
            try:
                data = summarise(transcript, args.model)
            except Exception as e:
                print(f"   ! ollama failed ({e}); writing transcript only")
                data = {"distillation": "", "key_points": [], "tags": [], "people": []}
            out.write_text(build_markdown(title, created, duration, path.name, data, transcript))
            print(f"   -> {out.name}")
        except Exception as e:
            print(f"   ! failed: {e}")

if __name__ == "__main__":
    main()
