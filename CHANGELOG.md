# Translate Names - changelog

## 2.8.8 - 2026-10-30

The Advanced band keeps the language pair after all.

- **Source/target no longer move into the grid.** 2.8.7 moved them down and put
  the two limits in the band above; the band is the same height either way, so
  the wrong pair moved. The languages now stay in the band in both modes, and
  `Max name length` / `Max depth` take the grid cells they used to occupy
  (right column, rows 1 and 2). Nothing moves when the mode changes - Simple
  only hides the grid.

## 2.8.7 - 2026-10-30

Advanced mode stops wasting its top band.

- **Max length and Max depth move up.** Advanced mode moves the source/target
  pair into the options grid, which left a band across the top holding nothing
  but the Advanced checkbox. `Max length` and `Max depth` now sit in that band
  instead, and go back into the grid in Simple mode (where it is hidden).
- **A list-only pass no longer invents targets.** The GUI plan builder did not
  skip `Queued` rows, so a drop could show collision-suffixed names under
  *Final target* before anything had been translated. It skips them now, so the
  column stays empty and Apply stays disabled until Preview runs.

## 2.8.6 - 2026-10-30

Back to the one-click include switch, and a probe bug fixed.

- **Clearing the last include option selects the other one.** 2.8.5 re-checked
  the box that had just been cleared, so switching from folders to files took
  several clicks and looked like nothing happened. Clearing the active box now
  turns the other one on, so files, folders and both are one click apart.
- **A test probe could leave `Include files` off.** The smoke hook that
  exercises that guard wrote its final state into `settings.json`, which made
  the drop listing come up empty (0 items) for a folder of files. The probe now
  restores the real settings before the window closes.

## 2.8.5 - 2026-10-30

The Include menu can no longer end up excluding everything.

- **"Neither" is impossible.** Unchecking the last of files/folders puts it
  straight back - in the Include menu and in the Advanced checkboxes, which are
  the same two choices - with a one-line note in the status bar. Before, both
  could be off and the scan refused them only after Preview was pressed.
- **The button says what is active:** `Files + folders`, `Files only`,
  `Folders only`. It still opens the same menu; hidden and subfolders remain
  independent of that choice.
- Tests: three new self-test checks for the caption (118 total).

## 2.8.4 - 2026-10-30

Capitalisation now reaches names that are not translated.

- **Already-English names take the case too.** With a capitalisation mode set,
  a name that is skipped because it is already in the target language kept its
  original casing (`notes.txt` stayed `notes.txt` while everything else became
  `NOTES.txt`). The skip branch overwrote the converted name with the original;
  it now keeps the converted one when it differs. "As returned" is still a
  no-op for those rows, so nothing changes unless a mode is chosen.
- Tests: two new self-test checks for the folded name (115 total).

## 2.8.3 - 2026-10-30

Two gaps from actually using 2.8.2 on a real folder.

- **The list fills in on drop.** Dropping a folder (or picking one, or typing
  a path and pressing Enter) now enumerates it immediately and shows every
  entry under its current name, marked `Queued`. That pass is local: it sends
  no request, writes no cache, and takes about a second. Pressing Preview/F5
  replaces the rows with the translated ones.
- **Clear list.** A new `Clear list` button next to Cancel empties the queue,
  the rows and the plan - including a multi-folder queue - without touching
  anything on disk. It is disabled while a job runs; Cancel stops the job.
- Fixes a regression from 2.8.2 where the drop handler removed the auto-start
  but left the list empty, so a drop looked like it had done nothing.

## 2.8.2 - 2026-10-30

A drop no longer translates on its own, and a throttled network is waited out
instead of ending the scan.

- **Nothing is sent until you ask.** Dropping a folder, picking one with
  Browse, choosing a recent path or launching with a folder now only loads it;
  the status line points at Preview translations (F5). Simple mode used to
  start the scan on the drop itself, spending requests before the languages and
  filters could be checked.
- **Throttling is ridden out.** A 429 now pauses 60 s instead of 5 s, then 2
  minutes, then 3 (capped), before the breaker stops the scan. The old 5/10/20
  second ladder gave up after roughly 35 seconds - often shorter than the burst
  limit it was waiting for.
- Tests: the self-test throttle expectations follow the new ladder, and the
  suite's synthetic 429 test still drives the scan to a clean stop.

## 2.8.1 - 2026-10-28

Two bugs, both of the "you only notice when it bites" kind.

- **Help window: the last two buttons vanished when the window was shrunk.**
  The six captions need about 940px; below that, `Import settings` and
  `Reset settings` ran off the right edge and could not be clicked at all. The
  row now wraps onto a second line when the window is narrow, so every button
  stays reachable at the dialog's minimum size (704x421 client). The corpus
  suite renders the real dialog at exactly that size and asserts all six
  buttons are inside it.
- **Glossary terms were applied in file order, one regex pass each.** Two
  consequences: a shorter term swallowed a longer one starting with it
  (`Show` turned `Show Name` into `serial Name`), and a substitution could be
  substituted again by a later term (`Nakama -> Crewmate` then
  `Crewmate -> Shipmate` came out as `Shipmate`). The glossary is now compiled
  once into a single expression with the longest source first and applied in one
  pass, so neither can happen. Each term keeps its own case flag; the compiled
  expression is cached per glossary load, so a name costs one scan instead of
  one per term.
- Self-test grew from 106 to 113 checks (longest-term precedence, no chaining,
  every occurrence replaced, and per-term case sensitivity in a mixed glossary).
- The corpus suite now has a help-window layout check (12th section), and smoke
  runs skip the single-instance lock so an open window cannot swallow a test
  run before it writes its report.

## 2.8.0 - 2026-10-26

Fixing a translated name no longer costs a dialog per row, and a multi-selection
in Explorer is one preview instead of "only the first folder counts".

- **Edit the new name in place.** Double-click the "New name" cell (or press F2)
  and the cell becomes an editor. Enter or Tab saves and moves to the next row,
  Shift+Tab to the previous one, Esc abandons the change, and clicking anywhere
  else saves it. The base name is preselected, not the extension. Names are still
  sanitised: if Windows would reject something, it is adjusted and the status
  line says so.
- A virtual-mode `ListView` forbids `LabelEdit` - there are no items to edit - so
  the editor is a themed TextBox floated over the cell at the bounds reported by
  `LVM_GETSUBITEMRECT`. That is the one native call that accounts for horizontal
  scrolling; without interop it falls back to the item rectangle plus the widths
  of the earlier columns. The corpus suite asserts the box lands within a pixel
  of the cell it replaces.
- The editor belongs to the running window, so it is closed by anything that
  moves rows under it (wheel, column resize, window resize, filter or sort
  rebuild), and it refuses to open during a scan or an apply. While it is open,
  the window's shortcuts are suspended - Ctrl+Z cannot start an undo mid-edit and
  F5 cannot scan over the top of it - so Esc means "abandon this edit" and
  nothing else.
- **Delete a row** is now its own sentence in the quick start: `Delete` still
  removes the selected rows, as before.
- **Multi-select drag and drop.** The drop handler used to take `$paths[0]` and
  ignore the rest, and a dropped file was mapped to its parent folder, so
  dropping three folders translated one and dropping one episode translated the
  season. Every dropped path is now queued: folders are scanned, files are queued
  as themselves (an explicitly picked file ignores the include, extension,
  exclude and depth filters; junctions and symlinks are still skipped), and a
  file inside a folder that was also dropped is not counted twice. One folder
  behaves exactly as before.
- The scan context carries a list of roots instead of a single `Root`, each
  candidate keeps its own root, and the protected-folder check runs over every
  folder in the queue. With several roots the Location column shows the last two
  segments (`...\Season 1\Extras`) instead of an elided absolute path, while the
  folder box keeps showing a real folder so recents and re-runs still work.
- Tests: the corpus suite grew from 56 to 69 checks. New: the editor opens on the
  requested row, covers the cell, uses the native rectangle and sits on top; a
  two-folder queue with a duplicated file scans two rows, renames in both roots
  and undoes back to the baseline; and the two performance guards below.

### Faster where it is felt

Editing a name in the list makes the cost of one edit something you notice, so
it was measured first (20 000 rows, `TRANSLATENAMES_SMOKE_VIRTUAL`):

| Step | Before | After |
|---|---|---|
| One row edit, end to end | 4 760 ms | 270 ms |
| Full re-plan (real collisions) | 2 943 ms | 2 943 ms |
| Row counting and status line | 1 637 ms | 38 ms |
| Startup with a full 20 000-entry cache | 1 741 ms | 1 337 ms |

- **A single edit no longer re-plans the queue.** The planner is global, but the
  answer for one row almost always is too: the new name is free, the row was
  already in the plan and stays in it. `Update-SingleRowPlan` decides that with a
  dictionary lookup of the plan's target paths plus one disk check, and updates
  just that row; anything that could affect other rows - a collision, a name
  another queued row has not vacated yet (a chain), the row joining or leaving
  the plan - falls back to the full planner, so the semantics are unchanged.
- **Row counting is one pass.** `Update-Counts` built a `Where-Object` pipeline
  with a function call per row (1.6 s at 20 000 rows) on every edit; it now
  counts and filters in a single loop, like the results view already did.
- **The translation cache is loaded when a scan starts, not at startup.** A full
  cache is a 1.2 MB JSON parse - about 0.4 s - and a window that is only being
  looked at does not need it.
- **Closing no longer rewrites an unchanged cache.** Exporting 20 000 entries is
  another ~0.5 s, and it used to happen on every exit even when nothing new had
  been translated. The file is now written only when the entry count changed.
- Startup tracing is built in: with `TRANSLATENAMES_SMOKE_REPORT` set, each boot
  phase is appended with the milliseconds since launch (`BOOT 289ms interop-ready
  `), so the next regression can be found instead of guessed.
- The corpus suite now asserts the edit path (`editMs` under 1 500 ms and a
  correct final target at 20 000 rows) and that counting stays under 400 ms, so
  neither can silently go back to seconds.

## 2.7.0 - 2026-10-26

Optional persistence: the app's data folder can now live on an Archil disk, so
settings, glossary, translation cache and the undo journal survive between runs
- and follow you to another machine.

- **Archil disk sync (`Archil\`).** A small Node helper (`archil-sync.mjs`, the
  `disk` npm package - the Archil TypeScript SDK) opens a disk and pushes or
  pulls four files through the disk's S3-compatible object API:

  | Local file | Key on the disk |
  |---|---|
  | `settings.json`, `cache.json`, `glossary.csv` | `translate-names/shared/<file>` |
  | `undo-journal.jsonl` | `translate-names/hosts/<machine>/<file>` |

  Settings, cache and glossary are portable, so they are shared between
  machines; the undo journal holds absolute paths, so each machine keeps its
  own copy (a journal from another PC would point at paths that do not exist
  here).
- **When it runs.** A pull before the state is read at startup restores any
  file that is missing locally (never overwriting an existing one), and a push
  after Apply or Undo stores the journal those jobs just wrote. The status line
  reports the result, for example `Archil: saved 3 file(s) to dsk-...`.
- **Off by default, and quiet about it.** With no `ARCHIL_API_KEY` there is no
  Node launch and no network call; the app behaves exactly as before. Errors
  (no Node, offline, bad key, no disk) surface as a status-bar note and never
  interrupt a rename. The key is read from the environment or from
  `Archil\.env`, is passed to Node through the environment (never a command
  line), and is never printed, logged or written anywhere by the app.
- **Setup:** `Archil\.env.example` declares `ARCHIL_API_KEY=` (empty),
  `ARCHIL_DISK_ID=`, `ARCHIL_REGION=` and `ARCHIL_PREFIX=`; copy it to `.env`
  and fill in a key. A key starts with `key-` - a disk token (`dsk-...`) is
  rejected with a clear message. Without `ARCHIL_DISK_ID` the first disk named
  `translate-names` is used and created on the first push. Requires Node.js
  22.19+ and `npm install` in `Archil\` (already installed in this tree).
- Tests: the offline self-test grew from 101 to 106 checks (the disk key map
  and the `key-`/disk-token rule are asserted without touching the network).
- The packaged single-file exe embeds only the script: to use Archil from it,
  keep the `Archil\` folder (and its `node_modules`) next to
  `TranslateNames.exe` and install Node.js. Everything else still works without
  either.

## 2.6.2 - 2026-10-26

A Simple mode for the common case, and the Include options as a drop-down.

- **Simple / Advanced switch.** A single checkbox in the new top row moves the
  window between two layouts:

  ```
  Simple    Folder  [..........................]  [Browse...]
            From [Auto-Detect v]  To [English v]   [Include...]  [ ] Advanced
            [Preview] [Apply] [Undo] [Cancel] [Help] [Defaults]
            results list (the options grid and the filter bar collapse)
  ```

  Both layouts use the *same* controls: the source and target combos are
  reparented into the Simple header and moved back into the options grid, so
  settings, import/export and reset keep working on one copy of the state. The
  hidden blocks are AutoSize rows in the outer table, so the results list simply
  takes the freed space. The choice is saved as `UiMode` and a fresh install
  starts in Simple; the window is re-fitted to the new layout at the current DPI
  on every switch, so nothing clips in either mode.
- **Include drop-down.** The four include switches (files, folders, subfolders,
  hidden/system) are also a menu behind an `Include...` button, with an
  `All options...` item that jumps to Advanced. The menu and the checkboxes stay
  in step both ways.
- **Drop and translate.** In Simple mode, a deliberate folder choice - a drop,
  Browse, the recent-folder drop-down, or a typed path plus Enter - starts the
  preview straight away. Apply stays a click, and everything a running job
  touches is unchanged.
- Tests: the settings smoke run now asserts both layouts (visible/hidden blocks,
  which container holds the combos, the collapsed row heights, and that clicking
  an include-menu item drives its checkbox), and the corpus suite grew from 51 to
  56 checks.

## 2.6.1 - 2026-10-25

Preview no longer freezes on large folders, and a running job can no longer be
knocked out from under itself.

- **The rename planner is linear.** `Get-RenamePlan` used to rescan every row for
  every scheduling step and rebuild the pending list with `Where-Object`. Measured
  on the real function: 500 rows 1.2 s, 1 000 rows 4.0 s, 2 000 rows 15.8 s
  (quadratic - about 26 minutes extrapolated for 20 000), all of it on the UI
  thread the moment a scan finished. Scheduling is now a dictionary of source
  paths plus one chain walk per blocked row; the sort key is precomputed instead
  of `Sort-Object` with calculated properties; the hot loop concatenates paths
  and uses `System.IO.File/Directory.Exists` instead of `Join-Path` and
  `Test-Path` (measured at about 70 us and a cmdlet call per row). The same
  measurements are now 0.09 s, 0.11 s and 0.15 s; 20 000 rows plan in 0.8 s, or
  2.2 s including the on-disk collision checks.
- Ordering is unchanged: children still move before their parents, chains still
  reorder (`A -> B` while `B -> C`), swap cycles still fall back to a numeric
  suffix, and the existing collision/chain/cycle/parent-child checks pass as-is.
- **Job-state guards.** The row actions (F2, Delete, reset) ended with
  `Set-BusyState -Busy $false`, which re-enabled *Preview* and disabled *Cancel*
  in the middle of a scan - pressing Preview then replaced the context the
  running workers still publish to, orphaning them. They now go through
  `Update-ActionState`, which refreshes the buttons while keeping the live busy
  state. `Start-Scan`, `Start-ApplyJob`, `Start-UndoJob` and `Set-FolderPath`
  (drop or typed path) are no-ops while a job runs, and editing or removing rows
  is paused during Apply/Undo, where the job works from the plan captured at
  start and silently ignored such edits. The context menu greys those items out
  to match.
- **Regression test:** the offline self-test now plans 5 000 synthetic rows and
  fails at 2 000 ms or more, and verifies every target stays distinct. The old
  scheduler needed more than 100 s for that, so the guard catches a return to
  quadratic behaviour. Self-test is 101 checks.
- Docs: TESTING.md counts corrected (101 checks), the throttling row now
  describes the 2.6.0 gate (four events in two minutes, not eight in a row), and
  the "huge libraries" note no longer says the list is unvirtualised - the
  planner was the scaling limit.

## 2.6.0 - 2026-10-24

Safest-possible parallel scanning, built around not getting the network blocked.

- **Parallel requests: 1 (default) to 3.** One to three workers partition the
  candidate list; progress, cancellation, fatal errors and completion are
  coordinated through shared state so the UI still gets one preview and one
  Done. Default remains 1: nothing changes unless you opt in.
- **One global rate limit.** `Request delay` now means the minimum gap between
  any two live requests in the whole scan, shared by all workers. Raising
  parallelism hides latency; it never increases the request rate.
- **Throttle detection and a global gate.** HTTP 429/503, an HTML page instead
  of JSON (gtx sometimes answers 200 with HTML), an unexpected payload and
  empty translations are all treated as a throttle signal, not an ordinary
  failure. A shared gate pauses every worker with exponential backoff
  (about 5 s, 10 s, 20 s) plus jitter. The status line reports the pause.
- **Circuit breaker.** A fourth throttle within two minutes stops the scan with
  a clear message; successful translations are already cached, so retrying later
  only re-requests what is missing. No proxy tricks are used.
- Auth failures (401/403) stay fatal immediately; the old "8 consecutive 429"
  counter was replaced by the throttle gate.
- Self-test now covers the backoff ladder, circuit threshold, jitter bounds and
  throttle-signal classification (98 checks). The corpus suite gained a
  synthetic-throttle test and a 3-worker apply/undo round trip (51 checks).

## 2.5.0 - 2026-10-24

Performance: the results list is now virtualized.

- The ListView runs in **VirtualMode**: rows live in the preview model, and the
  native control asks for an item only when it paints one. With 20,000 rows only
  about 176 items are retrieved, so huge folders no longer pay native-item cost
  for every row.
- Sorting, filtering, hide-unchanged, selection (including Ctrl+A), edit/reset/
  remove/copy, Apply and Undo all operate on the visible-index model. Column
  clicks re-sort the model instead of using a ListViewItemSorter.
- The filter/sort rebuild path is inline rather than Where-Object + a function
  call per row. Measured on this machine with 20,000 synthetic rows:
  refresh 2,305 ms -> **121 ms**, sort 2,523 ms -> **94 ms**, row construction
  (the scanner's job) 8.5 s spread across the scan.
- Dark-mode owner-draw and the light theme were both rendered and checked; rows,
  colours and the final-target column display correctly.
- The corpus suite gained a 20,000-row virtual-list benchmark with checks for
  laziness, selection, filtering and sorting (now 44 checks).

## 2.4.1 - 2026-10-24

Help-window and clipboard polish.

- Help/Glossary buttons are now a single row across the bottom instead of two
  right-aligned rows with empty space on the left. The redundant Close button is
  gone - the title-bar X and Esc close the window.
- Copy diagnostics retries the clipboard write (6 attempts with short backoff,
  then a DataObject fallback) instead of failing once with "Requested Clipboard
  operation did not succeed". If the clipboard is still locked, the full report
  is written to %TEMP%\translate-names-diagnostics.txt and the path is shown.
- Success no longer opens a second error-style dialog path: the confirmation only
  appears when the copy actually succeeded.

## 2.4.0 - 2026-10-24

The quick-win batch: navigation, settings portability and diagnostics.

- **Filter bar** above the results: substring Find, "Failed only" and
  "Conflicts only"; Ctrl+F focuses Find, Esc clears it while focused, and the
  status line reports "showing N" when a filter hides rows. Filters affect the
  view only - Apply still uses the whole queue.
- **Recent folders**: the Folder box is now an editable drop-down holding the
  last eight folders (typed paths load on Enter, drag and drop still works).
  The list is saved with the settings.
- **Settings export / import / reset** from the Help window: JSON export (API
  key never included), import applies a file to the live window, reset restores
  shipped defaults. Cache, glossary and undo journal are untouched.
- **Copy diagnostics** (Help button or Ctrl+D): version, PowerShell and OS,
  display scale, all data paths, current options, row/undo counts and recent
  warnings on the clipboard.
- **Ctrl+Z** runs Undo last apply; **column widths persist** across sessions.
- **System-path guard**: starting a scan on a drive root, Windows, Program
  Files or ProgramData now asks for explicit confirmation first.
- Help window grew to 12 sections (Filtering, Settings and diagnostics) and two
  button rows; keyboard help updated.
- Release checks cover the new behaviour: settings round-trip/reset, filter
  selection, diagnostics, protected roots and column persistence are asserted
  by the corpus suite (now 36 checks total).

## 2.3.0 - 2026-10-24

The glossary grew into an in-app guide and info window.

- **Help / Glossary** button (also F1, and a new `-Help` switch) opens a themed
  window with ten sections: Quick start, Preview and apply, Undo and safety,
  Name template, Skip folders and filters, Glossary, Languages and providers,
  Keyboard and mouse, Tests and diagnostics, and About this install.
- **About this install** shows live information: version, PowerShell version,
  display scale, provider/target language, every data file path (settings,
  cache, glossary, journal), glossary term count, pending undo batches, preview
  row count and portable-mode note.
- Window actions: Open glossary file (Notepad), Open data folder (Explorer),
  Close; Esc closes. Resizable; scales with DPI.
- `glossary.csv` is now self-documenting when created: format, optional
  CaseSensitive column, comment rules and commented examples, so the help and
  the file agree.
- Help window verified by rendering all sections (10 sections, body content,
  live About text); corpus suite remains 28/28 and the offline self-test 88.

## 2.2.2 - 2026-10-24

Guardrails for the two editable "magic" fields (name template and skip folders).

- The scan now refuses to start silently with a broken template: a template
  without `{translated}` (every item would get the same base name) or with an
  unknown `{token}` shows a warning with the specific problem and asks to
  continue. A blank template is documented and still means `{translated}`.
- Clearing **Skip folders** now shows a warning naming node_modules, .git and
  `$RECYCLE.BIN` before the tree is walked into. Defaults remain one click away.
- New **Defaults** button restores the name template, skip folders, exclude regex
  and skip extensions to their shipped values, without touching the other
  options.
- Tooltips explain the template tokens, the blank-template rule and the
  consequence of an empty skip list.
- Offline self-test now covers the template validator (88 checks).

The single-file exe was rebuilt with these changes.

## 2.2.1 - 2026-10-24

No console window.

- The single-file launcher is now a **Windows GUI-subsystem** binary (PE
  subsystem 2), so double-clicking never creates a console window - there is
  nothing to hide and no flash.
- CLI modes still work: the launcher attaches to the calling terminal (or
  allocates a console when started from Explorer), forwards output and returns
  the child's exit code. Because GUI-subsystem processes are fire-and-forget,
  scripts should use `Start-Process -Wait`.
- `Build-SingleExe.ps1 -Console` builds the previous console-subsystem variant
  for automation that needs a synchronous `&`.
- The build now reports the resulting PE subsystem so a regression is visible.

Verified: `dist\TranslateNames.exe` (GUI subsystem, no console), `-SelfTest`
83/83 via `Start-Process -Wait`, `-Plan` 12 rows for a sample folder, and a
portable preview -> apply -> undo run through the exe renamed 122 items and
restored every path, attribute and hash. Corpus suite still 28/28.

## 2.2.0 - 2026-10-24

Portability: one file to run.

- **`dist\TranslateNames.exe`**: a 185 KB single-file build that embeds the whole
  script. No `.vbs` needed, no execution-policy prompt, double-clickable, and it
  forwards every argument (`-Plan`, `-SelfTest`, `-InstallContextMenu`, a folder
  path) with proper exit codes.
- `Build-SingleExe.ps1` rebuilds it using the `csc.exe` that ships with .NET
  Framework - no SDK, NuGet or network needed. The launcher is a console program
  that hides its own console for GUI launches (never the terminal's), waits for
  the child, cleans up its unique temp script, and exports
  `TRANSLATENAMES_HOST_EXE` so context-menu entries and portable data point at
  the exe rather than the temp copy.
- **Portable mode**: `-Portable`, or an empty `TranslateNames.portable` file next
  to the exe, keeps settings, cache, glossary, undo journal and version
  snapshots in `TranslateNamesData\` beside the app instead of `%LOCALAPPDATA%`.
- `-InstallContextMenu` now registers the exe path when running packaged; the
  STA self-relaunch uses the exe too.
- Added `BUILDING.md` with the packaging options (single exe vs script+VBS vs
  single VBS vs native rewrite), build/run instructions, portable layout,
  requirements and the unsigned-binary caveat.

Verified: packaged exe passes `-SelfTest` (83 checks) and `-Plan` with correct
exit codes; a portable preview -> apply -> undo round trip through the exe
renamed 122 items and restored every path, attribute and hash; the corpus
failure suite remains 28/28.

## 2.1.2 - 2026-10-24

Test lab + one startup fix found by it.

- Single-instance: if the named lock is held but no window with the app title
  exists (a previous run was killed before releasing it), the app now starts
  instead of refusing forever with no visible reason.
- Added `TestCorpus.ps1`: generates a 140-entry hostile corpus (12 languages,
  RTL, ZWJ emoji, combining marks, symbols, 38 file types, reserved-looking
  names, read-only/hidden files, collisions/chains/case-only renames, excluded
  folders, optional >260-char paths) plus seeded settings/cache so a real
  apply/undo run works offline.
- Added `Run-CorpusTests.ps1`: 28 checks across offline self-test (now 83 checks),
  headless plan, apply/restart/undo with exact path+attribute+SHA256 comparison,
  locked-file failure, corrupt settings/cache/journal, kill-mid-apply recovery
  and long paths. Writes `TestLab\last-run.txt`, exit code 0/1.
- Added `TESTING.md`: failure matrix, what is automated, what must be checked by
  hand (providers, DPI, context menu, permissions, huge libraries).

## 2.1.1 - 2026-10-24

High-DPI layout fix. The app is system-DPI-aware, but every control size was a
96-DPI pixel value, so at 150%/200% display scaling the font rendered larger than
its boxes: bottom labels (status, hint) and button captions (Browse, Preview,
Apply, Undo, Cancel, Glossary) were clipped or sat a few pixels too low.

- All fixed metrics (button sizes and margins, dialog geometry, column widths,
  grid margins, progress bar, window minimum) now go through `Scale-Px`, which
  multiplies by the measured display scale (`Graphics.DpiY / 96`).
- Status and hint label heights are derived from `Font.GetHeight()` instead of
  hard-coded 20/18 px, so descenders always fit. Both ellipsise instead of
  cutting words.
- Action buttons auto-size to their caption (with the old width as a minimum), so
  long translated UI text cannot be clipped horizontally at high DPI.
- One-time Shown handler measures the auto-sized chrome, grows the window until
  the results list has room, clamps it to the working area, and pins
  `MinimumSize` so the bottom rows cannot be shrunk back into clipping.
- New options layout uses 8 rows instead of 9 (skip-extensions shares a row with
  transliteration), freeing vertical space.
- Fixed `Start-Scan` throwing a parameter-binding error when the folder box was
  empty / whitespace.

Verified by measuring the live layout at the real 150% scaling and at a forced
100%: label heights 35/28 and 29/28 (assigned/preferred), buttons 44/44, action
row 1095 px inside a 1140 px client, all seven rows summing to the client height.
The window was also rendered off-screen to PNG and inspected: both bottom rows
and every button caption are fully visible. Self-test (66 checks), plan mode and
the apply/undo end-to-end run still pass.

## 2.1.0 - 2026-10-24

Canonical app: this folder (`Translate\Edit\`). The copies one level up
(`Translate\TranslateNamesApp.ps1` + `Translate.vbs`) are the older 0.x version
and are left untouched as a fallback.

### Correctness / safety

- **Undo is crash-safe.** Every rename is appended to a JSONL journal
  (`%LOCALAPPDATA%\TranslateNames\undo-journal.jsonl`) *before* the move, and a
  failed move writes a cancel record. A power cut or kill can no longer lose the
  undo trail.
- **Partial undo is precise.** Successfully reverted entries are removed from the
  pending set; retrying undo no longer reports them as "missing".
- **Starting a new apply no longer destroys an earlier undo batch.** Applied
  batches stack on disk; Undo always acts on the newest pending batch, then the
  next one becomes available. The status line reports how many older batches
  remain.
- **Pre-flight rename planning.** All target paths are resolved before anything
  moves: on-disk collisions, collisions inside the batch, rename chains
  (`A -> B` while `B -> C`) and swap cycles are detected. Chains are reordered;
  cycles fall back to a numeric suffix. Nothing is silently renamed over a file.
- **Auto-suffix is now a choice.** With "Auto-suffix collisions" off, conflicting
  items are skipped and reported instead of being renamed to `Name (1)`.
- **Final target column** shows the leaf each item will really get.
- **Stale paths fixed.** When a parent folder is renamed, every queued row under
  it is repointed, so Show in Explorer / later applies stay valid. Undo does the
  same in reverse.
- **Context-menu verb fixed.** `Directory\shell` now passes `%1` (it was passing
  `%V`, which is only valid for folder backgrounds and drives, so right-clicking
  a folder could open the wrong one).
- **Single instance.** A second launch activates the existing window instead of
  opening a second app that would race the same files.
- **Closing during a scan no longer waits** for an in-flight HTTP request.
- **Scope control.** New "Skip folders" list (wildcards, whole subtrees; defaults
  to `node_modules;.git;.svn;.hg;$RECYCLE.BIN;System Volume Information`) and a
  "Max depth" limit. The exclude regex now matches the relative path as well as
  the leaf name (`^node_modules[\\/]` works).
- Emoji-safe name truncation, case-exact restore checks, fixed cancel status text,
  managed sorting fallback when the compiled comparer is unavailable, and a
  per-version script snapshot in `%LOCALAPPDATA%\TranslateNames\versions\`.

### Translation quality

- **Release-tag aware segmentation.** Names are split into protected and
  translatable parts. `S01E02`, `1080p`, `x265`, `WEB-DL`, `DTS`, `[Group]`,
  `{...}`, `(1080p)`, `第3话`, etc. are preserved verbatim; only the title is
  translated. Toggle with "Preserve release tags".
- **Glossary / do-not-translate list.** `%LOCALAPPDATA%\TranslateNames\glossary.csv`
  (`Source,Target[,CaseSensitive]`, `#` comments allowed). Exact term wins;
  other terms are substituted in the result. The Glossary button opens the file.
- **Transliteration (Google).** Romanise CJK/Cyrillic source names: `Off`,
  `Append` (`Name (Romaji)`) or `Replace` (romaji only), used only when the
  translated name still contains non-Latin text.
- **Request handling.** Per-segment cache hits, retry with jittered backoff,
  harder backoff on HTTP 429, a circuit breaker after 8 consecutive throttles, and
  provider response parsing moved into pure, testable functions.

### New non-GUI modes

```powershell
# offline unit tests (66 checks, exit code 0/1)
powershell -File TranslateNamesApp.ps1 -SelfTest

# dry run: scan + translate + plan, writes CSV, renames nothing
powershell -File TranslateNamesApp.ps1 -Plan "D:\Downloads\Anime" -PlanOut .\plan.csv

# same but offline: shows what would be scanned, no provider calls
powershell -File TranslateNamesApp.ps1 -Plan "D:\Downloads\Anime" -NoNetwork

# override the data folder (settings, cache, journal, glossary)
... -DataDir C:\Temp\TranslateNames
```

### Upgrade notes

- Existing `settings.json` is read as-is; new keys fall back to defaults
  (`SettingsVersion` is written as 2).
- The old `undo-journal.json` (v2.0 format) is ignored; only the new JSONL journal
  is read. Nothing is renamed or deleted by the upgrade.
- The translation cache format is unchanged.
- CSV rename logs still go to `%LOCALAPPDATA%\TranslateNames\rename-log-*.csv`;
  the preview CSV now includes a `FinalTarget` column.

### Verification performed

- 66/66 offline checks (`-SelfTest`): safe names, split/case/template,
  segmentation, provider parsing, glossary, relative paths, planner (collisions,
  chains, cycles, parent/child order), journal round-trip and compression, real
  file/folder/case-only renames and their undo.
- Headless `-Plan` on a synthetic tree: exclusion of `node_modules`, max-depth
  filtering, CSV output, exit codes.
- Off-screen GUI construction test.
- Automated preview -> apply -> restart -> undo run: 3 queued items renamed
  (including a folder and its child) and restored byte-for-byte, journal emptied.
- Note: the pre-change v2.0 file could not be copied to a backup folder because
  the sandbox denied writes there; the earliest available fallback is the 0.x
  copy in the parent folder. Version snapshots now happen automatically.
