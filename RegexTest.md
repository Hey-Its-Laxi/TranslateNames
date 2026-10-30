# Regex test pass — `RegexTest\`

If the folder is missing, `\TestRegex.ps1 -Force` builds it next to this file.

Drop `RegexTest\` on the window in **Advanced** mode, then paste a pattern into
**Exclude regex** and **re-drop the folder**. A drop only lists what matches
(no requests are sent), so the whole pass runs offline — **Preview** is the
button that translates, and you do not need it here.

Every expectation below was produced by running the app's own scanner over this
folder (`-Plan -NoNetwork`), not worked out on paper.

## Baseline

With default settings and an empty pattern: **49 rows** — 29 files, 20 folders.

If you see a different number before touching anything, it is almost certainly
one of these, not a bug:

| Setting | Effect |
|---|---|
| `Skip folders` (default `node_modules;.git;…`) | hides `05-skipped\node_modules\*` (3 rows) and `05-skipped\.git\*` (2) → 49 instead of 54 |
| `Include files` / `Include folders` | each item type drops out of the count |
| `Max depth` | bounds the whole walk: `1` leaves only the top-level entries |

`.git` here is a dot-name, not a Windows-hidden one, so `Include hidden` does
not affect this tree; `Skip folders` is what removes it.

`06-empty\EmptyFolder` is empty on purpose, and `05-skipped\.git` is a literal
`.git` directory, so neither can live in git. Both are what the fixture is
for, so the tree is generated rather than committed — run `\TestRegex.ps1
-Force` first, and the counts below apply.

## How the field is applied

- .NET regex, **case-insensitive**, no options to set.
- Each item is tested **twice**, and skipped if either one matches:
  1. the **leaf name, without its extension** (`report (1).pdf` → `report (1)`);
  2. the **path relative to the dropped folder**, with extension and `\`
     separators (`Projects\2024\invoice.pdf`).
- It only applies to items *below* the root. Drop a single file and the pattern
  is never used.
- An invalid pattern stops Preview with an **Invalid regex** dialog (it is
  caught before the scan, so nothing is half-filtered).

## Anchors, repetition, case

| Paste | Removed | Left | Proves |
|---|---|---|---|
| `^IMG_\d+$` | 3 | 46 | `\d` and `$` against the leaf |
| `\(\d+\)$` | 2 | 47 | parenthesised counters (`report (1)`, `report (2)`) |
| `^readme` | 2 | 47 | case-insensitive: hits `README.MD` **and** `ReadMe.txt` |
| `^(report\|invoice)` | 6 | 43 | alternation across folders |

## Leaf vs path — the part that surprises people

| Paste | Removed | Left | Why |
|---|---|---|---|
| `^notes$` | 2 | 47 | leaf test ignores the extension, so `notes` matches `notes.txt` |
| `^notes\.txt$` | **0** | 49 | leaf has no extension, and the full path starts with a folder — both tests miss |
| `notes\.txt$` | 3 | 46 | unanchored: also catches `C++ notes.txt` |
| `\.pdf$` | 7 | 42 | an extension match only ever comes from the path test |

`^notes\.txt$` looking broken while `notes\.txt$` works is the single most
useful thing to see here. Anchor an extension and you have to include the path
prefix: `^01-anchors\\notes\.txt$` removes exactly one row. (Type the doubled
backslash — a lone `\n` is a newline escape in .NET, not a folder separator.)

## Path anchoring

`Projects` exists at the root and again under `Archive`.

| Paste | Removed | Left | What it hits |
|---|---|---|---|
| `^Projects[\\/]` | 5 | 44 | only the root `Projects` tree |
| `[\\/]Projects[\\/]` | 2 | 47 | only `Archive\Projects\2024` |
| `Projects[\\/]` | 7 | 42 | both trees |
| `Projects[\\/](?!2024)` | 2 | 47 | lookahead: the `2025` branch alone |
| `^Archive[\\/]Projects` | 3 | 46 | a rooted two-segment prefix |

Note what is **not** in the removed list for `^Projects[\\/]`: the `Projects`
folder itself stays, because its relative path has no trailing separator. Its
contents vanish and it remains as an empty-looking row — see the folder section.

## Escaping (metacharacters inside real names)

| Paste | Removed | Left |
|---|---|---|
| `^file\[1\]$` | 1 | 48 |
| `^file[1]$` | **0** | 49 |
| `^a\+b$` | 1 | 48 |
| `^a+b$` | **0** | 49 |
| `^cost\$5$` | 1 | 48 |
| `\d+\s?%` | 1 | 48 |
| `^C\+\+` | 1 | 48 |

`[1]` is a character class (matches `file1`), and `+` is a quantifier — the
unescaped forms are *valid* patterns that simply match nothing here. Neither
throws, so a wrong result looks like "the filter ignored me".

## Unicode property classes

| Paste | Removed | Left | Hits |
|---|---|---|---|
| `\p{IsGreek}` | 1 | 48 | `Σημειώσεις.txt` |
| `\p{IsArabic}` | 1 | 48 | `تقرير سنوي.pdf` |
| `\p{IsCJKUnifiedIdeographs}` | 1 | 48 | `日本語メモ.txt` |
| `[^\u0000-\u007F]` | 5 | 44 | every non-ASCII name, including `café résumé` and `Änderungen über` |

## Folders

| Paste | Removed | Left | Behaviour |
|---|---|---|---|
| `^level\d$` | 4 | 45 | the four `levelN` folder rows only — the files stay listed |
| `level3[\\/]` | 2 | 47 | `level4` and `deep.txt`; `level3` itself stays (no trailing separator) |
| `level3$\|level3[\\/]` | 3 | 46 | the whole subtree, folder included |

Filtering a folder does **not** prune its children by itself: each item is tested
on its own. Use the `x$\|x[\\/]` form when you want a folder and everything under
it to disappear.

## Default `Skip folders` masks the obvious test

`05-skipped\node_modules` is already excluded before the regex runs, so both of
these change nothing (49 → 49):

- `^node_modules$`
- `node_modules[\\/]`

Clear **Skip folders**, then Preview again (54 rows). Now:

| Paste | Removed | Left |
|---|---|---|
| `^node_modules$` | 1 | 53 — the folder row only, its children stay |
| `node_modules[\\/]` | 2 | 52 — `pkg` and `index.js`, the folder row stays |

## GUI-only checks

- `[unclosed` → **Invalid regex** dialog, no scan, list untouched.
- Empty the field and re-drop → back to 49.
- A valid pattern that matches nothing (`^file[1]$`) is silently inert: no error,
  list unchanged. That is the failure mode to watch for when a pattern looks
  broken rather than wrong.
- The pattern is remembered across restarts (it is a saved setting) — clear it
  when you are done.

## The rest of the tree

`04-depth` exists for the numeric limits, not the regex: with **Max depth 1**
only the eight top-level entries remain (`01-anchors` … `06-empty`, `Archive`,
`Projects`) — 8 rows, no children. `06-empty` holds a folder with no files, to
confirm empty folders are listed and renamed.
