# Packaging and portability

The app is developed as `TranslateNamesApp.ps1` (plus `Translate.vbs` for
double-click convenience). For handing it to someone - or for dropping it on a
USB stick - there is now a **single-file build**:

```
dist\TranslateNames.exe
```

That one file contains the script, does not need the `.vbs`, does not prompt for
execution policy, and stores nothing outside its own data folder when portable
mode is on.

## Options, in order of practicality

| Option | Files | Pros | Cons |
|---|---|---|---|
| **Single exe (built here)** | 1 | Double-click, **no console window at all**, no policy prompt, arguments and exit codes work, can register the context menu | Unsigned (SmartScreen warning), needs Windows PowerShell 5.1 on the machine, CLI calls are fire-and-forget unless you use `Start-Process -Wait` |
| Script + VBS (dev source) | 2 | Readable/editable, no compiler needed | Two files, VBS may be blocked by policy, AV heuristics |
| Single VBS with the script embedded | 1 | Text-only, no compiler | Fragile (VBS string/encoding limits), still VBS, harder to maintain |
| ZIP folder / installer | 1 archive | Simple | Not "run one file", still needs extraction |
| Native rewrite (C#/WinForms) | 1 | No PowerShell dependency, can be signed | A full rewrite - not planned |

## Build

```powershell
# from this folder
.\Build-SingleExe.ps1                 # -> dist\TranslateNames.exe (windowless GUI build)
.\Build-SingleExe.ps1 -OutDir D:\Tools
.\Build-SingleExe.ps1 -Console        # console-subsystem build, waits for CLI calls
.\Build-SingleExe.ps1 -KeepBuild      # inspect the generated Launcher.cs
```

The build uses `csc.exe` from the .NET Framework 4.x folder that ships with
Windows - no NuGet, no internet, no SDK install. The script is embedded as a
resource, so editing `TranslateNamesApp.ps1` and rebuilding is the whole release
process.

The build verifies the PE subsystem byte: the default output is
**subsystem 2 (Windows GUI)**, which means Windows never allocates a console
window - there is nothing to hide and no flash. `-Console` produces subsystem 3
when you need a binary that behaves like a classic command-line tool.

### How the launcher behaves

- **No console is ever created in GUI mode.** Double-click, shortcut and context
  menu launch show only the app window.
- CLI switches (`-SelfTest`, `-Plan`, `-InstallContextMenu`, ...) make the
  launcher borrow the calling terminal (or allocate one if started from
  Explorer) and print output there.
- Because Windows treats a GUI-subsystem process as fire-and-forget, a terminal
  returns to the prompt immediately. For scripts use
  `Start-Process -Wait` (or run `TranslateNamesApp.ps1` directly), for example:
  `Start-Process .\dist\TranslateNames.exe -ArgumentList '-SelfTest' -Wait -PassThru`.
  Build with `-Console` if you want synchronous CLI behaviour from a plain `&`.
- Each launch extracts the script to
  `%TEMP%\TranslateNames\TranslateNamesApp-<id>.ps1`, runs Windows PowerShell 5.1
  with `-STA -ExecutionPolicy Bypass -WindowStyle Hidden`, forwards every
  argument, waits for the child, returns its exit code, then deletes the temp
  script. Concurrent launches cannot collide.
- The launcher exports `TRANSLATENAMES_HOST_EXE`, so the context-menu entry it
  installs points at the exe (not the temp script) and portable data is kept next
  to the exe.
- The exe is **unsigned**. SmartScreen will warn the first time on a new machine;
  "More info -> Run anyway", or sign it with your own code-signing certificate
  (`signtool sign /f cert.pfx /tr ... dist\TranslateNames.exe`).

## Portable mode

Keep settings, translation cache, glossary, undo journal and version snapshots
beside the app instead of in `%LOCALAPPDATA%`:

1. Create an empty file named `TranslateNames.portable` next to
   `TranslateNames.exe`, **or**
2. Start it with `-Portable`.

The data goes into `TranslateNamesData\` next to the exe:

```
TranslateNames.exe
TranslateNames.portable        (empty marker, optional)
TranslateNamesData\
    settings.json
    cache.json
    glossary.csv
    undo-journal.jsonl
    versions\TranslateNamesApp-<version>.ps1
```

From a read-only medium use `-DataDir <writable path>` instead. The context menu
is optional and the only registry write; without it nothing touches the registry.

## Requirements

- Windows 10 or 11 (the script uses WinForms and Windows PowerShell 5.1).
- Windows PowerShell 5.1 is part of Windows, so the exe needs no install.
- .NET Framework 4.x (also part of Windows).
- Network access for Google/DeepL translation; all other features work offline
  (`-Plan -NoNetwork`, glossary-only caching, undo).
- No admin rights. `-InstallContextMenu` writes only under HKCU.

## Testing the packaged build

```powershell
# GUI build: use Start-Process -Wait so the caller actually waits
$p = Start-Process .\dist\TranslateNames.exe -ArgumentList '-SelfTest' -Wait -PassThru
$p.ExitCode
Start-Process .\dist\TranslateNames.exe -ArgumentList '-Plan','D:\SomeFolder','-NoNetwork' -Wait

# or launch a -Console build for normal synchronous CLI use
.\Build-SingleExe.ps1 -Console -OutDir .\dist-cli
.\dist-cli\TranslateNames.exe -SelfTest

# automated apply/undo/portable test used during development:
# TestLab\Run-CorpusTests.ps1 covers the source form; the packaged exe was
# additionally verified with -SelfTest, -Plan and a portable preview/apply/undo
# run (122 renames restored exactly, no temp scripts left).
```

## Known limits

- The exe still requires Windows PowerShell 5.1 underneath; it is not a native
  rewrite. Windows only.
- GUI-subsystem exes are fire-and-forget from a terminal: the prompt returns
  immediately. Use `Start-Process -Wait` for scripts, or build `-Console`.
- Moving the exe after installing the context menu breaks the menu entry until
  `-InstallContextMenu` is run again.
- The version snapshot under `TranslateNamesData\versions\` (or the LOCALAPPDATA
  equivalent) stores the embedded script of each version, so a bad build can be
  compared with or restored from the previous one.
- Antivirus may quarantine an unsigned packed exe; signing or an allow-list entry
  is the fix.
