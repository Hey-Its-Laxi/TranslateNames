# TranslateNames

Rename files and folders into any language, using Google Translate. Windows, no install.

## Use

1. Download `TranslateNamesApp.ps1` and `Translate.vbs` into one folder.
2. Double-click `Translate.vbs`, drop a folder in, pick the languages, preview, apply.

Needs Windows 10+ and a connection for translating. Everything else — glossary,
editing, undo — works offline.

## What it does

- Drag in a folder or several, preview every rename before anything moves
- Translate names, or turn translation off and rewrite them from a glossary
- Source and target language, with auto-detect
- Double-click any row to fix the name yourself
- Handles collisions (`(1)`, `(2)`), long names, and renames children before parents
- Undo the last batch, even after the app was killed mid-apply
- Light and dark, follows Windows

## Optional

`Build-SingleExe.ps1` packs it into one windowless `TranslateNames.exe`.
`TESTING.md` covers the failure suite, `BUILDING.md` the packaging, and
`CHANGELOG.md` the history.

MIT licensed.
