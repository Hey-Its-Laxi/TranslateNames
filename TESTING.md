# Testing Translate Names against failure

This folder ships two test tools besides the app:

| File | Purpose |
|---|---|
| `TestCorpus.ps1` | Generates a hostile-but-valid corpus (names, folders, file types) plus `_meta\settings.json` + `_meta\cache.json` so apply/undo can be tested offline. |
| `Run-CorpusTests.ps1` | Runs the whole failure suite against that corpus and writes `TestLab\last-run.txt`. |

Everything is written under `<workspace>\TestLab\`. The suite never touches your real folders: it copies the corpus into throw-away `work-*` trees first.

```powershell
# one command, exit code 0 = all good
.\Run-CorpusTests.ps1

# keep the work/data folders for inspection
.\Run-CorpusTests.ps1 -KeepScratch

# skip the kill-mid-apply test
.\Run-CorpusTests.ps1 -SkipCrashTest

# regenerate the corpus somewhere else (including >260-char paths)
.\TestCorpus.ps1 -Path D:\Temp\Corpus -Force -IncludeLongPaths
```

## What the suite already checks automatically

1. **Offline self-test** (113 checks): safe names, reserved names, emoji truncation,
   Unicode/RTL/combining marks, release-tag segmentation, provider parsing,
   glossary, planner (collisions, chains, cycles, parent/child order),   planner speed at 5 000 rows (fails at 2 000 ms - the old quadratic scheduler needed
   more than 100 s), journal, corrupt settings/cache/journal, two-batch undo,
   real rename/undo transactions, and the Archil disk key map (shared files vs
   per-host undo journal, and the "key-" API key check).
2. **Headless plan**: every scannable entry appears, excluded subtrees
   (`node_modules`, `.git`, `$RECYCLE.BIN`, `System Volume Information`) do not,
   the CSV has the expected columns, exit code 0.
3. **Apply + restart + undo**: exact tree comparison (paths, attributes,
   SHA256), so a lost file, changed content or dropped attribute fails the run.
4. **Locked file**: a file held open by another process must fail softly, must
   not lose data, and undo must still restore everything else.
5. **Corrupt state**: invalid `settings.json`, `cache.json`, and a journal with
   garbage lines; the app must start and undo without crashing.
6. **Kill during apply**: the app is killed once the journal has entries, then
   undo must restore the baseline exactly. This is the crash-safety test.
7. **Long paths** (>260 chars): creation, scan and plan all run from
   `TestLab\CorpusLong` (generated with `-IncludeLongPaths`).
8. **Settings, filters, diagnostics**: settings round-trip/reset, filter
   selection, diagnostics content, protected-root detection and persisted
   column widths. Also the Simple/Advanced switch: both layouts hide the right
   blocks, the source/target combos are reparented into the correct container,
   the collapsed rows really measure zero, an include-menu click drives its
   checkbox, and the mode round-trips through `settings.json`.
9. **Inline editor and multi-root queue**: the in-place editor must open on the
   requested row, cover exactly the "New name" cell (form-client bounds mapped
   back to the list), use the native rectangle and sit on top of the list. A
   queue built from two folders plus a file that is already inside one of them
   must scan two rows (no duplicates), rename in both roots and undo both.
10. **Virtual list benchmark**: 20,000 synthetic rows must be held virtually,
    lazily retrieved, selectable, filterable and sortable, with the refresh time
    bounded. Also the two numbers that decide whether a huge queue feels usable:
    one row edit (fast path, under 1 500 ms - a full re-plan of the same queue is
    about 3 000 ms) and the status-line count (single pass, under 400 ms).
11. **Parallel workers + throttling**: a 3-worker apply/undo round trip must
    restore the baseline; a synthetic provider throttle (429/HTML) must pause,
    trip the circuit breaker and stop the scan cleanly without crashing.
12. **Help window at its smallest size**: the real dialog is rendered at its
    minimum client size (704x421) and every one of the six buttons must be
    inside it. The row wraps when narrow, so shrinking must never hide
    `Import settings` / `Reset settings` again. `TRANSLATENAMES_SMOKE_HELP_SIZE`
    (for example `704x421`) picks the size; `TRANSLATENAMES_SMOKE_SHOT` saves a
    PNG of the same frame if you want to look at it.

## Measuring startup and the big-queue costs

Set `TRANSLATENAMES_SMOKE_REPORT` to a file and start the app normally (or with
`-Smoke`): every boot phase is appended with the milliseconds since launch, so a
slow startup can be attributed instead of guessed:

    BOOT 52ms interop-start       before the C# helpers are compiled
    BOOT 289ms interop-ready      237 ms of that is Add-Type
    BOOT 399ms state-loaded       settings and glossary (the cache is lazy)
    BOOT 661ms options-built      the Advanced options grid
    BOOT 730ms list-built
    BOOT 958ms chrome-added
    BOOT 1021ms form-built
    BOOT 1340ms window-shown      first paint and the window fit

`TRANSLATENAMES_SMOKE_VIRTUAL=<file>` writes the 20 000-row numbers instead:
`buildMs`, `refreshMs`, `sortMs`, `planMs` (a full re-plan, the expensive real
case), `countsMs` and `editMs` (one row edit, the fast path).

## What the corpus contains

`TestLab\Corpus\` is generated by `TestCorpus.ps1`:

- `01-basic` - spaces, dots, dotfiles, `.mp4`, `.tar.gz`, digits, date-like
  names, case variants, separator runs.
- `02-languages` - Japanese, Chinese (simplified/traditional), Korean, Arabic,
  Hebrew, Russian, Greek, Thai, Hindi, Vietnamese, Turkish, mixed scripts, NFC
  vs NFD accents, RTL mark.
- `03-symbols` - `& # @ $ % ! + = ~ ^`, quotes, backtick, brackets/braces,
  semicolons, `%1 %V %PATH%`, copyright/trademark currency symbols, zero-width
  space, BOM character.
- `04-emoji` - single emoji, ZWJ family, flag (regional indicators), skin-tone
  modifier, emoji + text, variation selector.
- `05-edge-names` - 240-character component, read-only, hidden, Office lock
  pattern, plus files whose *translation* is hostile: `CON`, `bad:name*?<>|`,
  400 characters, whitespace only, control characters, emoji.
- `06-media-tags` - S01E02, 1080p, x265, WEB-DL, DDP5.1, HDR, BDRip, EP12,
  CJK episode counter, subtitle sidecar.
- `07-structure` - deep nesting, empty folder, parent folder + child file both
  renamed, folder with a tag, and excluded subtrees (`node_modules`, `.git`,
  `$RECYCLE.BIN`, `System Volume Information`).
- `08-collisions` - two files translating to the same name, a translation that
  collides with an existing file, a chain (target is another row's source), and
  a case-only rename.
- `10-encoding-names` - NFC and NFD versions of the same name in separate dirs.
- `11-filetypes` - 38 common extensions (mkv, mp4, srt, ass, nfo, jpg, pdf,
  docx, xlsx, zip, iso, torrent, flac, mp3, epub, cbz, sqlite, ...).

The `_meta\cache.json` maps every translatable base name to a dull `TR nnn`
target, except the deliberately hostile ones above. That is what makes a real
apply/undo run possible with **no network**.

## Failure matrix: what to try, and what should happen

| Area | Input | Expected behaviour | Covered by |
|---|---|---|---|
| Invalid characters in translation | `bad:name*?<>|` | Sanitised to a valid name, preview shows the truth | corpus + apply |
| Reserved names in translation | `CON` | Prefixed to `_CON`, never refused by Windows | corpus + apply |
| Over-long translation | 400 chars | Truncated to `Max name length`, extension kept | corpus + apply |
| Empty translation | `"   "` | Row marked unchanged, nothing renamed | corpus + apply |
| Control characters | tabs/CR/LF in translation | Replaced by `_` | corpus + apply |
| Unicode / RTL / emoji | all scripts | Preserved end-to-end (no mojibake in CSV or names) | corpus + apply |
| Combining marks | `e` + U+0301 | Preserved, not normalised away | self-test + corpus |
| ZWJ emoji | family sequence | Preserved, truncation never splits a surrogate | self-test + corpus |
| Collisions inside batch | two names -> one | Second gets ` (1)`, or is skipped if auto-suffix is off | corpus + apply |
| Collision with disk | target exists | Auto-suffix or skip+report, never overwrite | corpus + apply |
| Rename chain | A->B while B->C | Reordered so B moves first | self-test + corpus |
| Swap/cycle | A->B, B->A | Terminates with distinct targets (suffix fallback) | self-test |
| Parent + child renamed | folder and file inside | Child first, parent second, paths repaired | corpus + apply |
| Case-only rename | `case-only` -> `CASE-ONLY` | Two-step via temp name, undo restores exact case | corpus + apply |
| Excluded folders | node_modules, .git, recycle bin | Whole subtree untounched and absent from preview | plan + apply |
| Locked file | open handle, share read only | Rename fails for that row only, no data loss, undo restores rest | suite |
| Read-only file | attribute set | Renames and keeps attribute | corpus + apply |
| Hidden file | attribute set | Included only with "Include hidden and system" | corpus + apply |
| Long path | >260 chars | Scan/plan/rename use `\\?\` handling | CorpusLong |
| Corrupt settings | invalid JSON | Defaults, app still starts | suite |
| Corrupt cache | invalid JSON | Cache ignored, app still starts | suite |
| Corrupt journal | garbage/`null` lines | Lines skipped, valid entries still undo | suite |
| Crash mid-apply | kill -Force | Journal replays; tree returns to baseline | suite |
| Double launch | start twice | Second activates the first window (or starts if the lock is stale) | manual |
| Provider auth failure | bad DeepL key | Fatal message "Authentication failed (HTTP 401/403)", scan stops | manual |
| Provider throttling | many requests | Backoff on 429/503/HTML (about 5 s, 10 s, 20 s); a fourth event within two minutes stops the scan | manual |
| Provider timeout/offline | unplug network | Rows marked Failed, no renames, undo unaffected | manual |
| Empty folder | empty dir | Preview says "Nothing matched", apply disabled | manual |
| Invalid regex | `[` | Message box, scan does not start | manual |
| Missing folder | typo path | Message box, scan does not start | manual |
| Two windows writing | concurrent instances | Second window refuses/activates first | manual |
| DPI 100/150/200% | display scaling | No clipped captions or bottom bars | screenshot/measure |

## Manual checks that automation cannot cover

1. **Real provider failures.** With a bogus DeepL key, expect an immediate
   "Authentication failed" stop. With a throttled network, expect 429 backoff
   and eventually the circuit breaker. Offline, expect `Failed` rows and *no*
   renames. (The suite intentionally uses the cache so it needs no network.)
2. **Visual check at your scaling.** Launch normally and confirm: all five
   buttons, the status line and the hint line are fully readable; no column
   header is half cut. The suite can render a PNG via
   `TRANSLATENAMES_SMOKE_SHOT` if you want to compare. Tick **Advanced** and back
   at 150% and 200%: nothing should clip in either layout, the list should grow
   when the options grid collapses, and the choice should survive a restart.
   Double-click a name and confirm the editor sits on that cell, then Tab through
   a few rows: the box must follow the selection, and scrolling the wheel while
   it is open must close it rather than leave it floating over another row.
3. **Double launch.** Start the app twice. The second should raise the existing
   window; if the first was killed and left a stale lock, the app should start
   anyway (a fix in 2.1.2).
4. **Context menu.** Run `-InstallContextMenu`, right-click a folder, confirm the
   right folder opens, then `-UninstallContextMenu`.
5. **Permissions.** Try a folder you cannot write to; expect per-row failures,
   not a crash, and no partial silent loss.
6. **Huge libraries.** Point it at a few thousand files and watch memory/CPU.
   The list is virtualised, and planning 20 000 rows measures about 2 s; what
   still scales with the queue is `Update-FinalPlan`, which re-plans the whole
   queue after every row edit.
7. **Symlinks/junctions.** The app always skips reparse points. Verify that a
   junction inside the tree is reported as skipped, not renamed.
8. **Packaged exe.** After `Build-SingleExe.ps1`, run
   `dist\TranslateNames.exe -SelfTest` and `-Plan` from a terminal (both must wait
   and return exit codes), then double-click it: only the GUI should appear. Add
   `TranslateNames.portable` next to it and confirm the data lands in
   `TranslateNamesData\`.
9. **Help / Glossary.** Press F1 (or `-Help`): the guide should open with twelve
   sections, live paths in "About this install", and working
   "Open glossary file" / "Open data folder" buttons.
10. **Quick wins.** Try the filter bar (Find, Failed only, Conflicts only),
    recent-folder drop-down, Ctrl+Z / Ctrl+F / Ctrl+D, Export/Import/Reset
    settings from Help, and confirm rescanning a drive root asks first.
11. **Unicode CSV in Excel.** Open a rename log containing CJK/emoji names; Excel
    needs the UTF-8 BOM treatment (the app writes UTF-8; check with your Excel).
12. **Multi-select drop.** Select three folders in Explorer and drag them onto
    the window: the status line must say what was queued (e.g. "Queued 3: 3
    folder(s)"), the preview must contain all three trees, and the Location
    column must show `...\parent\leaf` rather than one elided path. Drop a
    couple of individual files: they are scanned as those files, not their whole
    folders. Drop a folder together with a file inside it: the file appears once.

## Safety rules when testing

- Always run apply/undo tests on a **copy**, never on the corpus itself and never
  on real media folders.
- Keep `%LOCALAPPDATA%\TranslateNames\versions\` - each app version is snapshotted
  there automatically.
- The undo journal lives in `%LOCALAPPDATA%\TranslateNames\undo-journal.jsonl`;
  the suite uses per-test `-DataDir` folders so it cannot disturb your real undo
  history.
- Deleting `_meta\cache.json` is safe; the corpus regenerates it.

## Extending the corpus

Add names to `TestCorpus.ps1` with `New-CorpusFile` / `New-CorpusDirectory`
(each takes `-TargetOverride` to control what the fake translation returns) and
regenerate with `-Force`. Keep the source ASCII-only and build exotic characters
from code points (`New-UnicodeText`, `New-Emoji`) so the script runs in both
Windows PowerShell 5.1 and PowerShell 7.
