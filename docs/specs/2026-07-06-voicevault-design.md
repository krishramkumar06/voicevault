# VoiceVault — Design

**Date:** 2026-07-06
**Status:** Approved (built end-to-end per author's brief)

## Problem

Apple Voice Memos is a great capture tool and a terrible retrieval tool. Ideas
recorded on walks pile up as audio files with vibes-based titles that never get
revisited. Obsidian is the opposite: strategic, searchable, linked — but hostile
to tactical brain-dumping. VoiceVault bridges them: every memo becomes one
markdown note with a verbatim transcript, a short summary, and retrieval
metadata (tags, `[[people]]` links), written into the user's vault.

The command-line pipeline (`poc/vm_to_markdown.py`) proved the approach. This
app is the version a non-technical person can use: **zero terminal, fully
on-device**.

## Hard constraints (from the brief)

1. No terminal, ever. Install, setup, local model management — all in-app.
2. Fully on-device: Apple SpeechAnalyzer for transcription, Ollama-served local
   model for summaries. The only network traffic is downloading models.
3. Ingest from the real Voice Memos library with real titles; user can process
   all or a subset; **preview before anything is written**; whole-library runs
   require a deliberate confirmation.
4. Summary model and prompt are user-configurable with sensible defaults.
5. Output: one Obsidian markdown note per memo — frontmatter, summary,
   verbatim transcript, configurable enrichments.
6. README teaches the practice (one idea per memo, LATCH), not just install.
7. Bonus feature: fix commonly mistranscribed names (Suren→"Soren",
   Isa→"Issa", Sosnovsky→"Sasnowski").

## Decisions made with the author

- **No Developer ID yet.** Ship ad-hoc-signed; release script takes a
  `SIGNING_IDENTITY` so notarization is a one-line change later. README
  documents the first-launch Gatekeeper steps foolproofly.
- **Public GitHub repo** under `krishramkumar06`, MIT.
- **Name: VoiceVault.**
- **Audio stays where it lives.** Vault gets text by default; a checkbox can
  also copy the `.m4a` next to the note. User picks input source and output
  folder explicitly.

## Architecture

SwiftPM package, two targets plus tests. No Xcode required to build; a script
assembles the `.app` bundle. macOS 26 (Tahoe), Apple Silicon.

```
VoiceVaultCore (library — all logic, fully testable)
├─ VoiceMemoLibrary   reads CloudRecordings.db (sqlite3 C API, read-only on a
│                     temp copy); falls back to scanning any folder of .m4a
├─ Transcriber        SpeechAnalyzer + SpeechTranscriber; manages the one-time
│                     Apple speech-model download via AssetInventory
├─ NameCorrector      phonetic post-correction from the People dictionary
├─ OllamaClient       localhost HTTP: /api/version, /api/tags, /api/pull
│                     (streamed progress), /api/chat with JSON-schema output
├─ OllamaManager      detect running server → detect installed binary and
│                     launch → else download runtime to Application Support
│                     and manage `ollama serve` as a child process
├─ NoteRenderer       memo + transcript + summary → markdown string; filename
│                     sanitization and collision handling
├─ ProcessingEngine   per-memo pipeline with status reporting; review queue
└─ AppSettings        Codable, persisted as JSON in Application Support

VoiceVault (executable — SwiftUI)
├─ Onboarding wizard  privacy promise → memo access → vault folder →
│                     local AI setup → people names
├─ Library view       real titles, date, duration, status badge, checkboxes;
│                     "process all" requires typed-out confirm sheet
├─ Review queue       full rendered preview per note; Save / Save all /
│                     Discard; nothing touches disk before Save
└─ Settings           General / AI (model picker, prompt editor) / People
```

### Voice Memos access (the TCC problem)

`~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/` is
TCC-protected. Strategy, in order:

1. **Guided folder selection.** An `NSOpenPanel` pre-navigated to the
   Recordings folder; the user clicks "Grant Access". Explicit user selection
   grants the app access without any settings spelunking.
2. **Full Disk Access fallback.** If reading still fails, an in-app page
   explains why, deep-links to the exact System Settings pane, and re-checks
   automatically.
3. **Plain folder mode.** Any folder of `.m4a` files (e.g. exported memos)
   works with zero permissions.

The app is **not sandboxed** — a sandboxed app cannot read another app's group
container at all. Distribution is outside the App Store, so this is fine, and
the README says why.

Titles come from `ZCLOUDRECORDING.ZCUSTOMLABEL`, dates from `ZDATE` (Core Data
epoch, +978307200), duration from `ZDURATION`, file from `ZPATH`. The DB is
copied to a temp file before opening so a live Voice Memos session can't
corrupt reads; if the DB is unreadable, fall back to filenames.

### Name correction ("People")

The user maintains a list of canonical names, optionally with known
mishearings. Three layers:

1. **Recognizer biasing** — canonical names are handed to SpeechTranscriber's
   contextual-strings mechanism where the API supports it.
2. **Phonetic post-correction** — transcript tokens (and n-grams for
   multi-word names) are matched against the dictionary: exact alias hits
   always correct; fuzzy hits require same-initial phonetic keys
   (double-metaphone), small edit distance on both surface and phonetic forms,
   and the misheard token must not be a common English word (embedded
   wordlist guard) unless explicitly listed as an alias. Conservative by
   design: a missed correction is cheap, a wrong one corrupts a verbatim
   transcript. All corrections are logged in `x-name-corrections` frontmatter
   and shown in the preview.
3. **Prompt injection** — canonical names are appended to the system prompt so
   the model's `people` output (→ `[[links]]`) uses canonical spellings.

Acceptance cases (unit-tested): Soren→Suren, Issa→Isa, Sasnowski→Sosnovsky;
"is a" is never corrected to "Isa".

### Ollama, zero-terminal

Detection order: server responding on the configured URL → use it. Binary at
known paths (`/opt/homebrew/bin`, `/usr/local/bin`, Ollama.app resources) →
spawn `ollama serve` as a managed child, terminated with the app. Neither →
one-click "Install the local AI engine": download the official
`ollama-darwin.tgz` release into `~/Library/Application Support/VoiceVault/`,
unpack, run. No admin rights, no terminal.

Model management is in-app: recommended models with download sizes, pull with
streamed progress, picker fed by `/api/tags`. Default model `qwen3.5:latest`
(what the PoC validated); context window 16384 (the PoC learned 4096 silently
truncates 30-minute memos).

### Note format (matches the PoC)

```markdown
---
title: "yc of amsterdam AWESOME"
created: 2026-07-01T09:12:44Z
duration: "12:03"
type: voice-memo
transcription: apple-speechanalyzer
x-suggested-tags: [startups, europe]
x-suggested-people: [Suren]
x-name-corrections: ["Soren → Suren"]
---

## Summary

Two to three sentences of plain prose.

- key point
- key point

People: [[Suren]]

---

## Transcript

…verbatim, with name corrections applied and logged…
```

Enrichment toggles (tags, people, key points) and the copy-audio option live
in Settings. `source:` frontmatter appears only when audio is copied.
Filenames are the sanitized title, with ` (YYYY-MM-DD)` appended on collision.

### Safety & error handling

- **Nothing is written without review.** Processing fills a review queue;
  writes happen on Save. An "auto-save after processing" toggle exists,
  default off.
- Empty transcript → flagged in the queue, note explains, never silently
  dropped. Ollama failure → transcript-only note, clearly badged (PoC
  behavior). Vault write errors surface in the UI with the failing path.
- Already-exported memos get a badge (tracked by memo ID in app state) and are
  skipped unless re-selected.

### Testing

`swift test` covers the pure core: name corrector (acceptance cases + guards),
renderer (golden-file note), DB reader (fixture sqlite built in the test),
filename sanitizer, Ollama response parsing. The app itself is verified by
building, launching, and running the real pipeline on real memos on the target
machine.

### Distribution

`Scripts/build_app.sh` compiles release, assembles `VoiceVault.app`
(Info.plist, icon generated via CoreGraphics + iconutil), ad-hoc codesigns
(or `SIGNING_IDENTITY`), zips into `dist/`. GitHub Release carries the zip.
README's install section assumes the reader has never bypassed Gatekeeper
before.
