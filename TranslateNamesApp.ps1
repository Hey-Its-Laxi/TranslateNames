#Requires -Version 5.1
<#
.SYNOPSIS
    Bulk-translate file and folder names with a preview/apply/undo workflow.

.DESCRIPTION
    Scans a folder, translates each file/folder name through Google Translate
    (free gtx endpoint) or DeepL, shows a preview you can edit, then renames.
    Every rename is journalled so it can be undone, including after a restart.

    Highlights:
      * Scanning and translating run in a background runspace, so the window
        never freezes and the job can be cancelled at any point.
      * File/folder names are segmented first: release tags (S01E02, 1080p,
        x265, group/bracket blocks, ...) are preserved verbatim and only the
        natural-language parts are translated. A glossary overrides terms.
      * Renames are planned before they run: name collisions with the disk and
        with the rest of the batch are resolved explicitly, and chains such as
        A -> B (where B is also being renamed) are reordered.
      * Undo is crash-safe: every rename is appended to a JSONL journal before
        it happens, so a power cut or kill cannot lose the trail.
      * Name sanitising covers invalid characters, reserved DOS device names,
        trailing dots/spaces, emoji-safe truncation and long paths.
      * Case-only renames (FOO -> Foo) are handled via a temp-name two-step.
      * Translations are cached on disk, so re-previewing a tree is free.

.PARAMETER InitialPath
    Folder to load at startup. If a file is passed, its parent folder is used.

.PARAMETER InstallContextMenu
    Registers a "Translate names..." verb for folders under HKCU, then exits.

.PARAMETER UninstallContextMenu
    Removes the context-menu verb, then exits.

.PARAMETER SelfTest
    Runs the built-in offline test suite and exits (0 = all pass).

.PARAMETER Plan
    Headless mode: scans this folder and writes the proposed renames to CSV
    without touching a single file.

.PARAMETER PlanOut
    CSV path for -Plan. Defaults to translate-names-plan.csv in the current
    directory.

.PARAMETER NoNetwork
    With -Plan: do not contact a translation provider. Names are segmented and
    normalised, with Status "Skipped (offline)". Useful for dry runs.

.PARAMETER DataDir
    Overrides %LOCALAPPDATA%\TranslateNames (settings, cache, undo journal).

.PARAMETER From
    Source language name for -Plan (default: Auto-Detect).

.PARAMETER To
    Target language name for -Plan (default: English).

.PARAMETER Quiet
    Suppresses console output in headless modes.

.PARAMETER Portable
    Keep settings, cache, glossary and the undo journal in a TranslateNamesData
    folder beside the app (or beside TranslateNames.exe) instead of
    %LOCALAPPDATA%. Also enabled automatically by an empty file named
    TranslateNames.portable next to the executable.

.PARAMETER Help
    Open the built-in Help / Glossary window on startup, then exit when it is
    closed.

.EXAMPLE
    .\TranslateNamesApp.ps1 "D:\Downloads\Anime"

.EXAMPLE
    TranslateNames.exe "D:\Downloads\Anime"      (single-file build)

.EXAMPLE
    .\TranslateNamesApp.ps1 -SelfTest

.EXAMPLE
    .\TranslateNamesApp.ps1 -Plan "D:\Downloads\Anime" -NoNetwork -PlanOut .\anime-plan.csv
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InitialPath,

    [switch]$InstallContextMenu,
    [switch]$UninstallContextMenu,

    [switch]$SelfTest,

    [Parameter(Position = 1)]
    [string]$Plan,

    [string]$PlanOut,

    [switch]$NoNetwork,

    [string]$DataDir,

    [string]$From,

    [string]$To,

    [switch]$Quiet,

    [switch]$Help,

    [switch]$Portable
)

$ErrorActionPreference = 'Stop'

$script:AppName    = 'Translate Names'
$script:AppVersion = '2.8.8'
$script:ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:ScriptDir  = Split-Path -Parent $script:ScriptPath
# When started from TranslateNames.exe the launcher exports its own path, so
# registry entries and portable data point at the real executable, not at the
# temporary script copy the launcher extracts.
$script:HostExe    = [string]$env:TRANSLATENAMES_HOST_EXE
$script:AppBase    = if ($script:HostExe) { Split-Path -Parent $script:HostExe } else { $script:ScriptDir }
$script:PortableMode = [bool]$Portable
if (-not $script:PortableMode -and $script:AppBase -and (Test-Path -LiteralPath (Join-Path $script:AppBase 'TranslateNames.portable'))) {
    $script:PortableMode = $true
}
$script:Headless   = [bool]($SelfTest -or $Plan)
$script:DataDir    = if ($DataDir) {
    [System.IO.Path]::GetFullPath($DataDir)
} elseif ($script:PortableMode) {
    Join-Path $script:AppBase 'TranslateNamesData'
} else {
    Join-Path $env:LOCALAPPDATA 'TranslateNames'
}

# Env-gated startup tracing used by Run-CorpusTests.ps1; a no-op otherwise.
# Each line carries the milliseconds since the script started, so where startup
# time goes is measurable instead of guessed.
$script:BootWatch = [System.Diagnostics.Stopwatch]::StartNew()
function Write-BootLog {
    param([string]$Message)
    if ($env:TRANSLATENAMES_SMOKE_REPORT) {
        try {
            $elapsed = if ($script:BootWatch) { [int]$script:BootWatch.ElapsedMilliseconds } else { 0 }
            [System.IO.File]::AppendAllText($env:TRANSLATENAMES_SMOKE_REPORT, ('BOOT ' + $elapsed + 'ms ' + $Message + [Environment]::NewLine))
        } catch { }
    }
}
Write-BootLog 'params'

#region ---------------------------------------------------------- Shell integration

function Get-ShellVerbCommand {
    param([string]$ArgumentToken)
    if ($script:HostExe -and (Test-Path -LiteralPath $script:HostExe)) {
        # Packaged build: point Explorer straight at the single exe.
        return ('"{0}" "{1}"' -f $script:HostExe, $ArgumentToken)
    }
    $vbs = Join-Path $script:ScriptDir 'Translate.vbs'
    if (Test-Path -LiteralPath $vbs) {
        return ('"{0}" "{1}" "{2}"' -f "$env:SystemRoot\System32\wscript.exe", $vbs, $ArgumentToken)
    }
    return ('"{0}" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" "{2}"' -f `
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", $script:ScriptPath, $ArgumentToken)
}

function Install-ShellIntegration {
    # %1 is the selected folder for Directory\shell; %V is only defined for the
    # Background and Drive verbs. Mixing them up makes "Translate names..." open
    # the wrong folder, so each root gets the token Windows actually supplies.
    $roots = [ordered]@{
        'HKCU:\Software\Classes\Directory\shell\TranslateNames'           = '%1'
        'HKCU:\Software\Classes\Directory\Background\shell\TranslateNames' = '%V'
        'HKCU:\Software\Classes\Drive\shell\TranslateNames'               = '%V'
    }
    foreach ($root in $roots.Keys) {
        $null = New-Item -Path $root -Force
        Set-ItemProperty -Path $root -Name '(default)' -Value 'Translate names...'
        Set-ItemProperty -Path $root -Name 'Icon' -Value 'imageres.dll,-5308'
        $null = New-Item -Path "$root\command" -Force
        Set-ItemProperty -Path "$root\command" -Name '(default)' -Value (Get-ShellVerbCommand $roots[$root])
    }
    Write-Host "Context-menu entry installed for folders, folder backgrounds and drives."
    foreach ($root in $roots.Keys) {
        Write-Host ("  {0}  ->  {1}" -f $root.Split('\')[-2], $roots[$root])
    }
}

function Uninstall-ShellIntegration {
    $roots = @(
        'HKCU:\Software\Classes\Directory\shell\TranslateNames'
        'HKCU:\Software\Classes\Directory\Background\shell\TranslateNames'
        'HKCU:\Software\Classes\Drive\shell\TranslateNames'
    )
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    Write-Host "Context-menu entry removed."
}

if ($InstallContextMenu)   { Install-ShellIntegration;   return }
if ($UninstallContextMenu) { Uninstall-ShellIntegration; return }
Write-BootLog 'shell-integration'

#endregion

#region ---------------------------------------------------------- STA guard

# WinForms drag-and-drop requires an STA thread (OLE). Windows PowerShell is
# STA by default; pwsh 6 and hosts that embed us may not be. Relaunch once.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $env:TRANSLATENAMES_STA -and -not $script:Headless) {
    $env:TRANSLATENAMES_STA = '1'
    if ($script:HostExe -and (Test-Path -LiteralPath $script:HostExe)) {
        $relaunchArgs = if ($InitialPath) { '"{0}"' -f $InitialPath } else { '' }
        Start-Process -FilePath $script:HostExe -ArgumentList $relaunchArgs
        return
    }
    $host_exe = try { (Get-Process -Id $PID).Path } catch { $null }
    if (-not $host_exe) { $host_exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    $relaunchArgs = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $script:ScriptPath
    if ($InitialPath) { $relaunchArgs += ' "{0}"' -f $InitialPath }
    Start-Process -FilePath $host_exe -ArgumentList $relaunchArgs -WindowStyle Hidden
    return
}

#endregion

#region ---------------------------------------------------------- Runtime setup

# TLS: enable 1.2 and (where the framework knows about it) 1.3, without poking
# undefined bit values into the enum, which throws on some builds.
try {
    $protocols = [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $protocols
} catch { }
try { [Net.ServicePointManager]::DefaultConnectionLimit = 16 } catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:InteropReady = $false
$interopSource = @'
using System;
using System.Collections;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TranslateNames
{
    public static class Native
    {
        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int StrCmpLogicalW(string a, string b);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("shcore.dll")]
        private static extern int SetProcessDpiAwareness(int value);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, ref RECT lParam);

        private const int LVM_GETSUBITEMRECT = 0x1000 + 56;
        private const int LVIR_BOUNDS = 0;

        // Client-area bounds of one cell. There is no managed equivalent that
        // accounts for horizontal scrolling, and a virtual-mode ListView cannot
        // use LabelEdit, so the inline cell editor needs this to land exactly on
        // the cell it is replacing.
        public static Rectangle GetCellBounds(ListView list, int itemIndex, int columnIndex)
        {
            if (list == null || itemIndex < 0 || columnIndex < 0) return Rectangle.Empty;
            try
            {
                // Input: left = subitem index, top = which part to report.
                RECT rect = new RECT();
                rect.Left = columnIndex;
                rect.Top = LVIR_BOUNDS;
                SendMessage(list.Handle, LVM_GETSUBITEMRECT, (IntPtr)itemIndex, ref rect);
                if (rect.Right <= rect.Left || rect.Bottom <= rect.Top) return Rectangle.Empty;
                return Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
            }
            catch { return Rectangle.Empty; }
        }

        // Bring an already-running instance forward instead of asking the user
        // to go find it (or, worse, opening a second window that would race it).
        public static bool ActivateWindow(string title)
        {
            try
            {
                IntPtr handle = FindWindow(null, title);
                if (handle == IntPtr.Zero) return false;
                ShowWindow(handle, 9);
                return SetForegroundWindow(handle);
            }
            catch { return false; }
        }

        public static int NaturalCompare(string a, string b)
        {
            try { return StrCmpLogicalW(a ?? "", b ?? ""); }
            catch { return String.Compare(a, b, StringComparison.OrdinalIgnoreCase); }
        }

        // Dark title bar. Attribute 20 on current Windows 10/11, 19 on early 1809 builds.
        public static void SetDarkTitleBar(IntPtr hwnd, bool enabled)
        {
            int flag = enabled ? 1 : 0;
            try
            {
                if (DwmSetWindowAttribute(hwnd, 20, ref flag, sizeof(int)) != 0)
                    DwmSetWindowAttribute(hwnd, 19, ref flag, sizeof(int));
            }
            catch { }
        }

        // System-DPI awareness only: WinForms on .NET Framework does not reflow
        // reliably under per-monitor v2 without an app manifest, and blurry is
        // better than broken.
        public static void EnableDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-2))) return; } catch { }
            try { if (SetProcessDpiAwareness(1) == 0) return; } catch { }
            try { SetProcessDPIAware(); } catch { }
        }
    }

    // ListView that does not flicker while thousands of rows stream in.
    public class BufferedListView : ListView
    {
        public BufferedListView()
        {
            DoubleBuffered = true;
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
        }
    }

    // NumericUpDown that scrolls one increment per wheel notch (the stock
    // control jumps by SystemInformation.MouseWheelScrollLines) and responds
    // to the wheel while merely hovered.
    public class WheelNumericUpDown : NumericUpDown
    {
        protected override void OnMouseEnter(EventArgs e)
        {
            base.OnMouseEnter(e);
            // Focusing on hover is what makes the wheel work here at all, but
            // stealing focus mid-sentence from a text box is worse than that.
            Form owner = FindForm();
            if (owner != null && owner.ActiveControl is TextBoxBase) return;
            if (CanFocus) Focus();
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            HandledMouseEventArgs handled = e as HandledMouseEventArgs;
            if (handled != null) handled.Handled = true;
            if (e.Delta > 0) UpButton();
            else if (e.Delta < 0) DownButton();
        }
    }

    // Explorer-style sort: "Part 2" before "Part 10".
    public class NaturalListViewComparer : IComparer
    {
        public int Column { get; set; }
        public SortOrder Order { get; set; }

        public NaturalListViewComparer(int column, SortOrder order)
        {
            Column = column;
            Order = order;
        }

        public int Compare(object x, object y)
        {
            ListViewItem a = x as ListViewItem;
            ListViewItem b = y as ListViewItem;
            if (a == null || b == null) return 0;
            if (Column >= a.SubItems.Count || Column >= b.SubItems.Count) return 0;

            int result = Native.NaturalCompare(a.SubItems[Column].Text, b.SubItems[Column].Text);
            return Order == SortOrder.Descending ? -result : result;
        }
    }
}
'@

Write-BootLog 'interop-start'
$refAssemblies = New-Object System.Collections.Generic.List[string]
foreach ($type in @([System.Windows.Forms.Form], [System.Drawing.Point])) {
    $location = $type.Assembly.Location
    if ($location -and -not $refAssemblies.Contains($location)) { $refAssemblies.Add($location) }
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    # The Desktop compiler references mscorlib and System implicitly; Core does not.
    foreach ($type in @([System.Object], [System.Runtime.InteropServices.Marshal], [System.ComponentModel.Component])) {
        $location = $type.Assembly.Location
        if ($location -and -not $refAssemblies.Contains($location)) { $refAssemblies.Add($location) }
    }
    $runtimeDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    foreach ($dll in 'netstandard.dll', 'System.Runtime.dll') {
        $path = Join-Path $runtimeDir $dll
        if ((Test-Path -LiteralPath $path) -and -not $refAssemblies.Contains($path)) { $refAssemblies.Add($path) }
    }
}

try {
    Add-Type -TypeDefinition $interopSource -ReferencedAssemblies $refAssemblies.ToArray() -ErrorAction Stop
    $script:InteropReady = $true
} catch {
    Write-Warning "Native helpers unavailable, falling back to stock controls: $($_.Exception.Message)"
}
Write-BootLog 'interop-ready'

if ($script:InteropReady) {
    [TranslateNames.Native]::EnableDpiAwareness()
} else {
    try {
        if ([System.Environment]::OSVersion.Version.Major -ge 10) {
            [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware)
        }
    } catch { }
}
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
        [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch { }

# The process is system-DPI-aware, so at 125/150/200% scaling the font renders
# larger while every hard-coded pixel size below stays at 96-DPI values. That
# clipped label and button captions (20px boxes holding 26px text). Measure the
# real DPI once and scale all fixed metrics through Scale-Px.
$script:DpiScale = 1.0
try {
    $screenGraphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try {
        if ($screenGraphics.DpiY -gt 0) {
            $script:DpiScale = [Math]::Round($screenGraphics.DpiY / 96.0, 2)
        }
    } finally {
        $screenGraphics.Dispose()
    }
} catch { }
if ($script:DpiScale -lt 1.0) { $script:DpiScale = 1.0 }
if ($env:TRANSLATENAMES_DPI_SCALE) {
    # Test hook: simulate another display scaling without changing Windows.
    $forcedScale = 0.0
    if ([double]::TryParse($env:TRANSLATENAMES_DPI_SCALE, [ref]$forcedScale) -and $forcedScale -ge 1.0) {
        $script:DpiScale = [Math]::Round($forcedScale, 2)
    }
}

function Scale-Px {
    param([double]$Value)
    return [int][Math]::Round($Value * $script:DpiScale)
}

#endregion

#region ---------------------------------------------------------- Theme

function Test-DarkMode {
    if ($env:TRANSLATENAMES_FORCE_DARK) { return $true }
    if ($env:TRANSLATENAMES_FORCE_LIGHT) { return $false }
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        return ((Get-ItemProperty -LiteralPath $key -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme -eq 0)
    } catch {
        return $false
    }
}

$script:IsDark = Test-DarkMode

function New-Rgb { param([int]$R, [int]$G, [int]$B) [System.Drawing.Color]::FromArgb($R, $G, $B) }

$script:Theme = if ($script:IsDark) {
    @{
        Background  = New-Rgb 32 32 32
        Foreground  = New-Rgb 240 240 240
        ControlBack = New-Rgb 45 45 48
        ControlFore = New-Rgb 240 240 240
        Border      = New-Rgb 70 70 74
        HeaderBack  = New-Rgb 55 55 58
        HeaderLine  = New-Rgb 80 80 84
        Subtle      = New-Rgb 160 160 160
        UnchangedBg = New-Rgb 58 48 40
        UnchangedFg = New-Rgb 225 190 150
        SuccessBg   = New-Rgb 36 60 40
        SuccessFg   = New-Rgb 170 235 175
        ErrorBg     = New-Rgb 70 38 38
        ErrorFg     = New-Rgb 255 170 170
        ConflictBg  = New-Rgb 66 56 26
        ConflictFg  = New-Rgb 255 225 140
        EditedBg    = New-Rgb 36 50 66
        EditedFg    = New-Rgb 170 205 255
    }
} else {
    @{
        Background  = New-Rgb 245 245 245
        Foreground  = New-Rgb 30 30 30
        ControlBack = [System.Drawing.Color]::White
        ControlFore = [System.Drawing.Color]::Black
        Border      = New-Rgb 200 200 200
        HeaderBack  = New-Rgb 235 235 235
        HeaderLine  = New-Rgb 200 200 200
        Subtle      = New-Rgb 100 100 100
        UnchangedBg = New-Rgb 255 241 228
        UnchangedFg = New-Rgb 140 80 10
        SuccessBg   = New-Rgb 226 246 228
        SuccessFg   = New-Rgb 20 100 35
        ErrorBg     = New-Rgb 253 226 226
        ErrorFg     = New-Rgb 150 25 25
        ConflictBg  = New-Rgb 253 245 205
        ConflictFg  = New-Rgb 130 100 0
        EditedBg    = New-Rgb 226 238 253
        EditedFg    = New-Rgb 20 70 140
    }
}

$script:AccentPrimary = New-Rgb 0 120 215
$script:AccentApply   = New-Rgb 16 124 65
$script:AccentUndo    = New-Rgb 176 42 55
$script:AccentNeutral = if ($script:IsDark) { New-Rgb 68 68 72 } else { New-Rgb 225 225 225 }

#endregion

#region ---------------------------------------------------------- Language data

# Codes accepted by the Google endpoint. DeepL uses a subset, mapped below.
$script:LangMap = [ordered]@{
    'Auto-Detect'           = 'auto'
    'Afrikaans'             = 'af'
    'Albanian'              = 'sq'
    'Arabic'                = 'ar'
    'Armenian'              = 'hy'
    'Azerbaijani'           = 'az'
    'Belarusian'            = 'be'
    'Bengali'               = 'bn'
    'Bosnian'               = 'bs'
    'Bulgarian'             = 'bg'
    'Catalan'               = 'ca'
    'Chinese (Simplified)'  = 'zh-CN'
    'Chinese (Traditional)' = 'zh-TW'
    'Croatian'              = 'hr'
    'Czech'                 = 'cs'
    'Danish'                = 'da'
    'Dutch'                 = 'nl'
    'English'               = 'en'
    'Estonian'              = 'et'
    'Filipino'              = 'tl'
    'Finnish'               = 'fi'
    'French'                = 'fr'
    'Georgian'              = 'ka'
    'German'                = 'de'
    'Greek'                 = 'el'
    'Hebrew'                = 'iw'
    'Hindi'                 = 'hi'
    'Hungarian'             = 'hu'
    'Icelandic'             = 'is'
    'Indonesian'            = 'id'
    'Italian'               = 'it'
    'Japanese'              = 'ja'
    'Kazakh'                = 'kk'
    'Khmer'                 = 'km'
    'Korean'                = 'ko'
    'Latvian'               = 'lv'
    'Lithuanian'            = 'lt'
    'Macedonian'            = 'mk'
    'Malay'                 = 'ms'
    'Mongolian'             = 'mn'
    'Nepali'                = 'ne'
    'Norwegian'             = 'no'
    'Persian'               = 'fa'
    'Polish'                = 'pl'
    'Portuguese'            = 'pt'
    'Romanian'              = 'ro'
    'Russian'               = 'ru'
    'Serbian'               = 'sr'
    'Sinhala'               = 'si'
    'Slovak'                = 'sk'
    'Slovenian'             = 'sl'
    'Spanish'               = 'es'
    'Swahili'               = 'sw'
    'Swedish'               = 'sv'
    'Tamil'                 = 'ta'
    'Telugu'                = 'te'
    'Thai'                  = 'th'
    'Turkish'               = 'tr'
    'Ukrainian'             = 'uk'
    'Urdu'                  = 'ur'
    'Uzbek'                 = 'uz'
    'Vietnamese'            = 'vi'
}

$script:CodeToName = @{}
foreach ($entry in $script:LangMap.GetEnumerator()) {
    if (-not $script:CodeToName.ContainsKey($entry.Value)) { $script:CodeToName[$entry.Value] = $entry.Key }
}

$script:CaseModes = @('As returned', 'Title Case', 'Sentence case', 'lower case', 'UPPER CASE')

#endregion

#region ---------------------------------------------------------- Settings and cache

$script:SettingsPath    = Join-Path $script:DataDir 'settings.json'
$script:CachePath       = Join-Path $script:DataDir 'cache.json'
$script:JournalPath     = Join-Path $script:DataDir 'undo-journal.jsonl'
$script:GlossaryPath    = Join-Path $script:DataDir 'glossary.csv'
$script:MaxCacheEntries = 20000

function Initialize-DataDir {
    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        $null = New-Item -ItemType Directory -Path $script:DataDir -Force
    }
}

# Write through a temp file so a crash never leaves a half-written JSON file.
function Set-ContentAtomic {
    param([string]$Path, [string]$Content)
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $temp = '{0}.{1}.tmp' -f $Path, [System.IO.Path]::GetRandomFileName()
    try {
        [System.IO.File]::WriteAllText($temp, $Content, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

$script:DefaultSkipFolders = 'node_modules;.git;.svn;.hg;$RECYCLE.BIN;System Volume Information'

$script:DefaultSettings = [ordered]@{
    SettingsVersion   = 2
    SourceLanguage    = 'Auto-Detect'
    TargetLanguage    = 'English'
    Provider          = 'Google'
    CaseMode          = 'As returned'
    Template          = '{translated}'
    ExcludePattern    = ''
    ExcludeFolders    = $script:DefaultSkipFolders
    SkipExtensions    = ''
    DelayMs           = 200
    MaxNameLength     = 120
    MaxDepth          = 0
    ParallelRequests  = 1
    IncludeFiles      = $true
    IncludeFolders    = $true
    Recurse           = $true
    IncludeHidden     = $false
    SkipIfTargetLang  = $true
    HideUnchanged     = $false
    UiMode            = 'Simple'
    WriteCsvLog       = $true
    ProtectTags       = $true
    Transliteration   = 'Off'
    AutoSuffix        = $true
    GlossaryFile      = ''
    LastFolder        = ''
    RecentFolders     = @()
    ColumnWidths      = @()
    WindowWidth       = 860
    WindowHeight      = 900
}

function Import-Settings {
    $settings = @{}
    foreach ($key in $script:DefaultSettings.Keys) { $settings[$key] = $script:DefaultSettings[$key] }
    try {
        if (Test-Path -LiteralPath $script:SettingsPath) {
            $saved = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @($settings.Keys)) {
                $property = $saved.PSObject.Properties[$key]
                if ($property -and $null -ne $property.Value) { $settings[$key] = $property.Value }
            }
        }
    } catch {
        Write-Warning "Could not read settings, using defaults: $($_.Exception.Message)"
    }
    # Guard against values a future/older version might have written.
    $allowedModes = @('Off', 'Append', 'Replace')
    if ($allowedModes -notcontains [string]$settings.Transliteration) { $settings.Transliteration = 'Off' }
    if (@('Simple', 'Advanced') -notcontains [string]$settings.UiMode) { $settings.UiMode = 'Simple' }
    if ([int]$settings.MaxDepth -lt 0) { $settings.MaxDepth = 0 }
    return $settings
}

function Export-Settings {
    param($Settings)
    try {
        Initialize-DataDir
        $Settings['SettingsVersion'] = 2
        Set-ContentAtomic -Path $script:SettingsPath -Content ($Settings | ConvertTo-Json -Depth 4)
    } catch {
        Write-Warning "Could not save settings: $($_.Exception.Message)"
    }
}

function Import-TranslationCache {
    $cache = [hashtable]::Synchronized(@{})
    try {
        if (Test-Path -LiteralPath $script:CachePath) {
            $raw = Get-Content -LiteralPath $script:CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in $raw.PSObject.Properties) {
                $cache[$property.Name] = [pscustomobject]@{
                    Text     = [string]$property.Value.t
                    Detected = [string]$property.Value.d
                }
            }
        }
    } catch {
        Write-Warning "Could not read translation cache: $($_.Exception.Message)"
    }
    return $cache
}

# Reading the cache is the single most expensive thing at startup once it is
# full (20 000 entries is a 1.2 MB JSON parse, about 0.4 s), and a window that
# is only being looked at does not need it. It is loaded when a scan starts.
function Initialize-TranslationCache {
    if ($script:CacheLoaded) { return }
    $script:Cache             = Import-TranslationCache
    $script:CacheLoaded       = $true
    $script:CacheLoadedCount  = $script:Cache.Count
}

# Nothing new translated means nothing to write: rebuilding a 20 000-entry JSON
# on the way out is otherwise paid on every close.
function Save-TranslationCacheIfChanged {
    if (-not $script:CacheLoaded -or -not $script:Cache) { return }
    if ($script:Cache.Count -eq $script:CacheLoadedCount) { return }
    Export-TranslationCache -Cache $script:Cache
    $script:CacheLoadedCount = $script:Cache.Count
}

function Export-TranslationCache {
    param($Cache)
    try {
        if (-not $Cache -or $Cache.Count -eq 0) { return }
        Initialize-DataDir
        $snapshot = [ordered]@{}
        $count = 0
        foreach ($key in @($Cache.Keys)) {
            if ($count -ge $script:MaxCacheEntries) { break }
            $value = $Cache[$key]
            $snapshot[$key] = @{ t = $value.Text; d = $value.Detected }
            $count++
        }
        Set-ContentAtomic -Path $script:CachePath -Content ($snapshot | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        Write-Warning "Could not save translation cache: $($_.Exception.Message)"
    }
}

# Glossary: a plain CSV the user can edit in Excel. Forgiving parser: comma,
# semicolon or tab separated, optional header, # comments, optional third
# CaseSensitive column.
function Import-Glossary {
    param([string]$Path = $script:GlossaryPath)
    $terms = New-Object System.Collections.Generic.List[object]
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $terms.ToArray() }
        if (-not (Test-Path -LiteralPath $Path)) {
            Initialize-DataDir
            $templateText = @(
                '# Translate Names glossary'
                '#'
                '# One term per line:  Source,Target[,CaseSensitive]'
                '#   Source         text as it appears in the original name (a translated segment or a whole base)'
                '#   Target         replacement text'
                '#   CaseSensitive  optional: 1/true/yes to match case exactly'
                '#'
                '# Lines beginning with # are comments and are ignored.'
                '# An exact match wins; other terms are substituted in the translated text.'
                '# The file is reloaded before every preview. The Help / Glossary window explains more.'
                ''
                '# Examples (remove the leading # to use):'
                '# One Piece,One Piece,false'
                '# Nakama,Crewmate,false'
                '# Senpai,Senpai,true'
            ) -join "`r`n"
            Set-ContentAtomic -Path $Path -Content $templateText
            return $terms.ToArray()
        }
        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
            $lineNumber++
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
            $delimiter = if ($line.Contains("`t")) { "`t" } elseif ($line.Contains(';')) { ';' } else { ',' }
            $fields = $line.Split([char]$delimiter)
            if ($fields.Count -lt 2) { continue }
            $source = $fields[0].Trim().Trim('"')
            $target = $fields[1].Trim().Trim('"')
            if ($lineNumber -eq 1 -and ($source -match '^(?i)source$' -or $target -match '^(?i)target$|^(?i)to$')) { continue }
            if ([string]::IsNullOrEmpty($source)) { continue }
            $caseSensitive = $false
            if ($fields.Count -ge 3) { $caseSensitive = ($fields[2].Trim() -match '^(?i:1|true|yes)$') }
            $terms.Add([pscustomobject]@{
                Source        = $source
                Target        = $target
                CaseSensitive = [bool]$caseSensitive
            })
        }
    } catch {
        Write-Warning "Could not read the glossary: $($_.Exception.Message)"
    }
    return $terms.ToArray()
}

# --- Undo journal (JSONL, append-only, crash-safe) --------------------------
# A rename record is appended BEFORE the move happens. A crash in between
# leaves an intent record whose reverse path simply does not exist yet, which
# undo reports and skips; a crash after the move always has a record.

function Add-JournalRecord {
    param([hashtable]$Record)
    try {
        Initialize-DataDir
        $json = $Record | ConvertTo-Json -Depth 4 -Compress
        [System.IO.File]::AppendAllText($script:JournalPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch {
        Write-Warning "Could not write the undo journal: $($_.Exception.Message)"
        return $false
    }
}

function Get-JournalRecords {
    $records = New-Object System.Collections.Generic.List[object]
    try {
        if (-not (Test-Path -LiteralPath $script:JournalPath)) { return $records.ToArray() }
        foreach ($line in [System.IO.File]::ReadAllLines($script:JournalPath, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ($record -and $record.PSObject.Properties['op']) { $records.Add($record) }
        }
    } catch { }
    return $records.ToArray()
}

# Pending renames grouped by apply batch, oldest batch first. A rename whose
# id was marked undone/cancelled is dropped, so partial undos stay precise.
function Get-PendingJournalBatches {
    param([object[]]$Records)

    $cancelled = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $undone    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $Records) {
        $id = [string]$record.id
        if ([string]::IsNullOrEmpty($id)) { continue }
        if ($record.op -eq 'undo')   { [void]$undone.Add($id) }
        if ($record.op -eq 'cancel') { [void]$cancelled.Add($id) }
    }

    $batchOrder = New-Object System.Collections.Generic.List[string]
    $batchEntries = @{}
    foreach ($record in $Records) {
        if ($record.op -ne 'rename') { continue }
        $id = [string]$record.id
        if ([string]::IsNullOrEmpty($id) -or $cancelled.Contains($id) -or $undone.Contains($id)) { continue }
        $batch = [string]$record.batch
        if ([string]::IsNullOrEmpty($batch)) { $batch = 'legacy' }
        if (-not $batchEntries.ContainsKey($batch)) {
            $batchEntries[$batch] = New-Object System.Collections.Generic.List[object]
            $batchOrder.Add($batch)
        }
        $batchEntries[$batch].Add([pscustomobject]@{
            Id           = $id
            BatchId      = $batch
            Directory    = [string]$record.dir
            OriginalLeaf = [string]$record.from
            NewLeaf      = [string]$record.to
            IsContainer  = [bool]$record.folder
            Timestamp    = [string]$record.ts
            Row          = $null
        })
    }

    $batches = New-Object System.Collections.Generic.List[object]
    foreach ($batch in $batchOrder) {
        $entries = $batchEntries[$batch]
        $batches.Add([pscustomobject]@{
            BatchId   = $batch
            Timestamp = if ($entries.Count -gt 0) { $entries[0].Timestamp } else { '' }
            Entries   = $entries
        })
    }
    return $batches.ToArray()
}

# Rewrite the journal keeping only still-pending renames (bounded growth).
function Compress-Journal {
    try {
        $records = Get-JournalRecords
        $batches = Get-PendingJournalBatches -Records $records
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($batch in $batches) {
            foreach ($entry in $batch.Entries) {
                $lines.Add((@{
                    op     = 'rename'
                    id     = $entry.Id
                    batch  = $entry.BatchId
                    dir    = $entry.Directory
                    from   = $entry.OriginalLeaf
                    to     = $entry.NewLeaf
                    folder = $entry.IsContainer
                    ts     = $entry.Timestamp
                } | ConvertTo-Json -Compress))
            }
        }
        if ($lines.Count -eq 0) {
            if (Test-Path -LiteralPath $script:JournalPath) { Remove-Item -LiteralPath $script:JournalPath -Force -ErrorAction SilentlyContinue }
            return
        }
        Set-ContentAtomic -Path $script:JournalPath -Content (($lines -join "`n") + "`n")
    } catch {
        Write-Warning "Could not compress the undo journal: $($_.Exception.Message)"
    }
}

#endregion

#region ---------------------------------------------------------- Archil disk sync
# Optional: keep the data folder on an Archil disk so settings, glossary,
# translation cache and the undo journal survive between runs - and follow you
# to another machine. The disk work itself lives in Archil\archil-sync.mjs (the
# `disk` npm package is the TypeScript SDK; there is no PowerShell one), and is
# called here as a small CLI that answers with one JSON line.
#
# Everything in this region is inert unless ARCHIL_API_KEY is set: no key means
# no Node launch, no network call, and the app behaves exactly as before.

$script:ArchilDir    = if ($script:AppBase) { Join-Path $script:AppBase 'Archil' } else { 'Archil' }
$script:ArchilScript = Join-Path $script:ArchilDir 'archil-sync.mjs'
$script:ArchilEnv    = Join-Path $script:ArchilDir '.env'
$script:ArchilNode   = ''

# Keep in step with SHARED_FILES / HOST_FILES in Archil\archil-sync.mjs.
$script:ArchilSharedFiles = @('settings.json', 'cache.json', 'glossary.csv')
$script:ArchilHostFiles   = @('undo-journal.jsonl')

# Where each data file lives on the disk. Shared files are portable; the undo
# journal holds absolute paths, so each machine gets its own copy.
function Get-ArchilSyncPlan {
    param([string]$HostName, [string]$Prefix)

    if ([string]::IsNullOrWhiteSpace($Prefix)) {
        $Prefix = if ($env:ARCHIL_PREFIX) { [string]$env:ARCHIL_PREFIX } else { 'translate-names' }
    }
    $Prefix = $Prefix.Trim().Trim('/')
    if (-not $Prefix) { $Prefix = 'translate-names' }

    if ([string]::IsNullOrWhiteSpace($HostName)) { $HostName = [string]$env:COMPUTERNAME }
    $hostSlug = $HostName.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $hostSlug = $hostSlug.Trim('-', '.')
    if (-not $hostSlug) { $hostSlug = 'local' }

    $plan = [ordered]@{}
    foreach ($file in $script:ArchilSharedFiles) { $plan[$file] = "$Prefix/shared/$file" }
    foreach ($file in $script:ArchilHostFiles)   { $plan[$file] = "$Prefix/hosts/$hostSlug/$file" }
    return $plan
}

# An Archil API key authenticates the control plane and starts with "key-"; a
# disk token is a mount credential for one disk and is rejected here.
function Test-ArchilConfigured {
    param([string]$ApiKey)
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { return $false }
    return $ApiKey.Trim().StartsWith('key-', [StringComparison]::OrdinalIgnoreCase)
}

# Read Archil\.env, if the user created one from .env.example. Real
# environment variables win, and the values are never written to the console.
function Import-ArchilEnvFile {
    param([string]$Path = $script:ArchilEnv)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
            $parts = $trimmed -split '=', 2
            if ($parts.Count -ne 2) { continue }
            $name = $parts[0].Trim()
            if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            if ([Environment]::GetEnvironmentVariable($name, 'Process')) { continue }
            $value = $parts[1].Trim().Trim('"').Trim("'")
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    } catch { }
}

function Get-ArchilNodePath {
    if ($script:ArchilNode -and (Test-Path -LiteralPath $script:ArchilNode)) { return $script:ArchilNode }
    if ($env:ARCHIL_NODE -and (Test-Path -LiteralPath $env:ARCHIL_NODE)) {
        $script:ArchilNode = $env:ARCHIL_NODE
        return $script:ArchilNode
    }
    $command = Get-Command node -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        $script:ArchilNode = [string]$command.Source
        return $script:ArchilNode
    }
    return ''
}

# Run the helper and answer with its parsed JSON line. Never throws: a broken
# disk, a missing Node or an offline machine must not take the app down.
function Invoke-ArchilNode {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 20)

    try {
        $node = Get-ArchilNodePath
        if (-not $node) {
            return [pscustomobject]@{ ok = $false; error = 'Node.js 22.19 or later was not found on PATH.' }
        }
        if (-not (Test-Path -LiteralPath $script:ArchilScript)) {
            return [pscustomobject]@{ ok = $false; error = ("{0} is missing." -f $script:ArchilScript) }
        }

        $argumentLine = (@($script:ArchilScript) + @($Arguments)) |
            ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName               = $node
        $startInfo.Arguments              = ($argumentLine -join ' ')
        $startInfo.UseShellExecute        = $false
        $startInfo.CreateNoWindow         = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError  = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit([int]$TimeoutSeconds * 1000)
        if (-not $finished) {
            try { $process.Kill() } catch { }
            $process.Dispose()
            return [pscustomobject]@{ ok = $false; error = ("no answer after {0} s" -f $TimeoutSeconds) }
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $process.Dispose()

        $lastLine = @($stdout -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
        if (-not $lastLine) {
            $detail = @($stderr -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1
            $message = if ($detail) { [string]$detail } else { 'the helper printed nothing' }
            return [pscustomobject]@{ ok = $false; error = $message }
        }
        return ($lastLine | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
}

# Push the data folder to the disk, or pull back what is missing locally.
# Returns a one-line note for the status bar, or '' when nothing happened.
function Sync-ArchilSnapshot {
    param(
        [ValidateSet('Push', 'Pull')][string]$Action,
        [int]$TimeoutSeconds = 20
    )

    try {
        Import-ArchilEnvFile
        if ([string]::IsNullOrWhiteSpace($env:ARCHIL_API_KEY)) { return '' }
        if (-not (Test-ArchilConfigured -ApiKey $env:ARCHIL_API_KEY)) {
            # A disk token (dsk-...) is a mount credential, not an account key.
            return 'Archil sync is off: ARCHIL_API_KEY must be an account API key (starts with "key-"), not a disk token.'
        }

        Initialize-DataDir
        $result = Invoke-ArchilNode -Arguments @($Action.ToLowerInvariant(), '--dir', $script:DataDir) -TimeoutSeconds $TimeoutSeconds
        if (-not $result -or -not $result.ok) {
            $reason = if ($result -and $result.error) { [string]$result.error } else { 'unknown error' }
            return ("Archil sync failed: {0}" -f $reason)
        }

        $diskLabel = if ($result.disk -and $result.disk.id) { [string]$result.disk.id } else { 'the disk' }
        if ($Action -eq 'Push') {
            $note = "Archil: saved {0} file(s) to {1}" -f @($result.uploaded).Count, $diskLabel
            if ($result.disk -and $result.disk.created) { $note += ' (new disk)' }
            return $note
        }
        $restored = @($result.downloaded).Count
        if ($restored -gt 0) { return ("Archil: restored {0} file(s) from {1}" -f $restored, $diskLabel) }
        return ''
    } catch {
        return ("Archil sync failed: {0}" -f $_.Exception.Message)
    }
}

#endregion

#region ---------------------------------------------------------- Shared helpers
# Defined as source text so the background runspace can dot-source the exact
# same implementations the UI thread uses. One definition, no drift.

$script:HelperSource = @'
function Get-PathDepth {
    param([string]$Path)
    return ($Path -split '[\\/]').Count
}

# Prefix paths that are close to MAX_PATH so the Win32 long-path form is used.
function ConvertTo-ExtendedPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.Length -lt 248) { return $Path }
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\'))   { return '\\?\UNC\' + $Path.Substring(2) }
    if ($Path -match '^[A-Za-z]:\\') { return '\\?\' + $Path }
    return $Path
}

# Existence check for the planner: System.IO is roughly an order of magnitude
# cheaper than the Test-Path cmdlet, which matters when every row of a large
# queue checks its target path.
function Test-PathExists {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    try {
        if ([System.IO.Directory]::Exists($Path)) { return $true }
        return [System.IO.File]::Exists($Path)
    } catch { return $false }
}

function Get-SafeFileName {
    param(
        [string]$Name,
        [int]$MaxLength = 120
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    $reserved = @(
        'CON','PRN','AUX','NUL',
        'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
        'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9'
    )

    # Union of the platform set and the fixed Windows set, so behaviour does not
    # depend on which host the script happens to be running under.
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() +
               [char[]]('<', '>', ':', '"', '/', '\', '|', '?', '*')
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if (($invalid -contains $ch) -or ([int]$ch -lt 32)) {
            [void]$builder.Append('_')
        } else {
            [void]$builder.Append($ch)
        }
    }

    $clean = $builder.ToString()
    $clean = [regex]::Replace($clean, '\s+', ' ')
    $clean = [regex]::Replace($clean, '_{2,}', '_')
    $clean = $clean.Trim().Trim('_').Trim()

    if ($MaxLength -gt 0 -and $clean.Length -gt $MaxLength) {
        $clean = Get-SafeTruncate -Text $clean -MaxLength $MaxLength
    }

    # Windows silently strips trailing dots and spaces, which turns a rename
    # into a surprise. Strip them here so the preview shows the truth.
    $clean = $clean.TrimEnd('.', ' ')

    if ([string]::IsNullOrWhiteSpace($clean)) { return '' }

    $stem = $clean
    $dot = $clean.IndexOf('.')
    if ($dot -gt 0) { $stem = $clean.Substring(0, $dot) }
    if ($reserved -contains $stem.ToUpperInvariant()) { $clean = '_' + $clean }

    return $clean
}

function Convert-NameCase {
    param([string]$Text, [string]$Mode)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $textInfo = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
    switch ($Mode) {
        'Title Case'    { return $textInfo.ToTitleCase($Text.ToLowerInvariant()) }
        'Sentence case' {
            $lower = $Text.ToLowerInvariant()
            return $lower.Substring(0, 1).ToUpperInvariant() + $lower.Substring(1)
        }
        'lower case'    { return $Text.ToLowerInvariant() }
        'UPPER CASE'    { return $Text.ToUpperInvariant() }
        default         { return $Text }
    }
}

# A name that is already in the target language still obeys an explicit
# capitalisation choice; "As returned" (or a mode that changes nothing) leaves
# it alone. Returns '' when the name should stay exactly as it is.
function Get-RecasedName {
    param([string]$Base, [string]$Mode, [int]$MaxLength)
    if ([string]::IsNullOrEmpty($Base)) { return '' }
    $cased = Get-SafeFileName -Name (Convert-NameCase -Text $Base -Mode $Mode) -MaxLength $MaxLength
    if ([string]::IsNullOrWhiteSpace($cased) -or $cased -ceq $Base) { return '' }
    return $cased
}

# Short label for the Include button: files and folders are independent, so
# the caption has to say which combination is active.
function Get-IncludeLabel {
    param([bool]$Files, [bool]$Folders)
    if ($Files -and $Folders) { return 'Files + folders' }
    if ($Files) { return 'Files only' }
    if ($Folders) { return 'Folders only' }
    return 'Nothing included'
}

function Expand-NameTemplate {
    param(
        [string]$Template,
        [string]$Translated,
        [string]$Original,
        [string]$Lang
    )
    if ([string]::IsNullOrWhiteSpace($Template)) { return $Translated }
    $out = $Template
    $out = $out.Replace('{translated}', $Translated)
    $out = $out.Replace('{original}', $Original)
    $out = $out.Replace('{lang}', $Lang)
    return $out
}

# Explain template problems before a scan starts instead of silently producing
# identical or literal names. Blank means "{translated}".
function Get-NameTemplateIssues {
    param([string]$Template)
    $issues = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Template)) { return $issues.ToArray() }
    if ($Template -notmatch '\{translated\}') {
        $issues.Add('it has no {translated} token, so every item would get the same base name')
    }
    $known = @('translated', 'original', 'lang')
    foreach ($match in [regex]::Matches($Template, '\{([A-Za-z]+)\}')) {
        $token = $match.Groups[1].Value.ToLowerInvariant()
        if ($known -notcontains $token) {
            $issues.Add(('unknown token ' + $match.Value + ' (known: {translated}, {original}, {lang})'))
        }
    }
    return $issues.ToArray()
}

function Split-EntryName {
    param([string]$Name, [bool]$IsContainer)
    if ($IsContainer) {
        return [pscustomobject]@{ Base = $Name; Extension = '' }
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $ext  = [System.IO.Path]::GetExtension($Name)
    # Dotfiles (".gitignore") have an empty stem; treat the whole thing as the name.
    if ([string]::IsNullOrEmpty($base)) { return [pscustomobject]@{ Base = $Name; Extension = '' } }
    return [pscustomobject]@{ Base = $base; Extension = $ext }
}

# Truncate without splitting a surrogate pair, which produces an invalid name.
function Get-SafeTruncate {
    param([string]$Text, [int]$MaxLength)
    if ([string]::IsNullOrEmpty($Text) -or $MaxLength -le 0 -or $Text.Length -le $MaxLength) { return $Text }
    $cut = $MaxLength
    if ($cut -gt 0 -and $cut -lt $Text.Length -and [char]::IsHighSurrogate($Text[$cut - 1])) { $cut-- }
    if ($cut -le 0) { return '' }
    return $Text.Substring(0, $cut)
}

# Root-relative path with a proper segment boundary, so C:\A never matches C:\AB.
function ConvertTo-RelativePath {
    param([string]$Path, [string]$Root)
    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Root)) { return $Path }
    $r = $Root.TrimEnd('\', '/')
    if ([string]::Equals($Path, $r, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    foreach ($sep in @('\', '/')) {
        if ($Path.Length -gt $r.Length -and $Path.StartsWith($r + $sep, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $Path.Substring($r.Length + 1)
            if ([string]::IsNullOrEmpty($rel)) { return '.' }
            return $rel
        }
    }
    return $Path
}

# Compact "where is this" form for the Location column when the queue came from
# several roots: the last two segments, so the column still fits and two roots
# with the same leaf name stay distinguishable.
function Get-ShortFolderPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '.' }
    $trimmed = $Path.TrimEnd('\', '/')
    if ($trimmed -match '^[A-Za-z]:$') { return $trimmed }
    $parts = @($trimmed -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -le 2) { return $trimmed }
    return ('...' + '\' + ($parts[($parts.Count - 2)..($parts.Count - 1)] -join '\'))
}

function Test-GlobMatch {
    param([string]$Name, [string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Pattern)) { return $false }
    try { return ($Name -like $Pattern) } catch { return $false }
}

function Test-HasNonLatinLetters {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [regex]::IsMatch($Text, '[^\u0000-\u007F]')
}

# --- Provider response parsing (pure, so the self-test can feed fixtures) ----

function ConvertFrom-GoogleResponse {
    param($Response)
    $text = ''
    $detected = $null
    $romanized = ''
    if ($null -ne $Response -and $Response.Count -ge 1) {
        $chunks = @($Response[0])
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($chunk in $chunks) {
            if ($null -eq $chunk) { continue }
            if ($chunk.Count -ge 1 -and $null -ne $chunk[0]) { $parts.Add([string]$chunk[0]) }
            if ($chunk.Count -ge 4 -and $null -eq $chunk[0] -and $null -ne $chunk[3]) { $romanized += [string]$chunk[3] }
        }
        $text = -join $parts
    }
    if ($null -ne $Response -and $Response.Count -ge 3 -and $Response[2]) { $detected = [string]$Response[2] }
    return [pscustomobject]@{ Text = $text; Detected = $detected; Romanized = $romanized }
}

function ConvertFrom-GoogleRomanization {
    param($Response)
    if ($null -eq $Response -or $Response.Count -lt 1) { return '' }
    $roman = ''
    foreach ($chunk in @($Response[0])) {
        if ($null -eq $chunk) { continue }
        if ($chunk.Count -ge 4 -and $null -ne $chunk[3]) { $roman += [string]$chunk[3] }
    }
    return $roman
}

function ConvertFrom-DeepLResponse {
    param($Response)
    $text = ''
    $detected = $null
    if ($null -ne $Response -and $Response.PSObject.Properties['translations'] -and $Response.translations.Count -ge 1) {
        $first = $Response.translations[0]
        $text = [string]$first.text
        if ($first.PSObject.Properties['detected_source_language']) {
            $detected = ([string]$first.detected_source_language).ToLowerInvariant()
        }
    }
    return [pscustomobject]@{ Text = $text; Detected = $detected; Romanized = '' }
}

# --- Name segmentation -------------------------------------------------------

# Release-name tags that must survive translation untouched. The bracket rules
# come first so "[Group] 1080p" is captured as a whole.
function Get-ProtectedTagPattern {
    $parts = @(
        '\[[^\]]{0,120}\]'
        '\{[^}]{0,120}\}'
        '\((?:\d{3,4}p|\d{3,4}x\d{3,4}|\d{4}|[A-Z]{2,6})\)'
        '\bS\d{1,2}(?:E\d{1,4})?\b'
        '\bE(?:P)?\d{1,4}\b'
        '\b\d{1,3}x\d{1,3}\b'
        '\b(?:EP|Episode|Vol|Volume|Part|Pt|Season|Disc|CD)\.?\s*\d{1,3}\b'
        '\u7b2c\s*\d{1,4}\s*[\u8bdd\u8a71\u96c6\u5b63\u90e8\u7ae0\u5377]'
        '\b(?:2160p|1080p|720p|480p|360p|4K|8K|UHD|HDR10\+?|HDR|DV|DoVi|SDR)\b'
        '\bx26[45]\b'
        '\bh26[45]\b'
        '\b(?:HEVC|AVC|AV1|VP9)\b'
        '\b(?:10|8|12)bit\b'
        '\b\d{1,2}\s?bits?\b'
        '\b(?:BDRip|BluRay|BDRemux|REMUX|WEBRip|WEB-DL|WEBDL|HDTV|DVDRip|HDRip|DVD|AMZN|NF|DSNP|HMAX|ATVP)\b'
        '\b(?:AAC|AC3|EAC3|DTS(?:-HD)?|TrueHD|FLAC|Atmos|MP3|OPUS)\b'
        '\bDDP?\d?\.?\d?\b'
        '\b(?:PROPER|REPACK|EXTENDED|UNCUT|MULTi|DUAL|SUB|DUB)\b'
    )
    return '(?<protect>' + ($parts -join '|') + ')'
}

function Get-NameSegments {
    param([string]$Name, [bool]$ProtectTags = $true)
    $segments = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Name)) { return $segments.ToArray() }
    if (-not $ProtectTags) {
        $segments.Add([pscustomobject]@{ Text = $Name; Protected = $false })
        return $segments.ToArray()
    }

    $pattern = Get-ProtectedTagPattern
    $last = 0
    foreach ($match in [regex]::Matches($Name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        if ($match.Length -le 0) { continue }
        if ($match.Index -gt $last) {
            $segments.Add([pscustomobject]@{ Text = $Name.Substring($last, $match.Index - $last); Protected = $false })
        }
        $segments.Add([pscustomobject]@{ Text = $match.Value; Protected = $true })
        $last = $match.Index + $match.Length
    }
    if ($last -lt $Name.Length) {
        $segments.Add([pscustomobject]@{ Text = $Name.Substring($last); Protected = $false })
    }
    if ($segments.Count -eq 0) {
        $segments.Add([pscustomobject]@{ Text = $Name; Protected = $false })
    }
    return $segments.ToArray()
}

# --- Glossary ----------------------------------------------------------------

function Find-GlossaryTerm {
    param([string]$Text, [object[]]$Glossary)
    if ([string]::IsNullOrEmpty($Text) -or -not $Glossary -or $Glossary.Count -eq 0) { return $null }
    foreach ($term in $Glossary) {
        $source = [string]$term.Source
        if ([string]::IsNullOrEmpty($source)) { continue }
        $comparison = if ($term.CaseSensitive) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
        if ([string]::Equals($Text, $source, $comparison)) { return [string]$term.Target }
    }
    return $null
}

# Compiles the whole glossary into one expression, longest source first. Two
# problems disappear with a single pass: a short term can no longer swallow a
# longer one that starts with it ("Show" eating "Show Name"), and a replacement
# can no longer be replaced again by the term that follows it (Nakama ->
# Crewmate -> Shipmate). It is also one regex scan per name instead of one per
# term. Each alternative carries its own case flag, so a mixed glossary works.
function New-GlossaryPattern {
    param([object[]]$Glossary)
    $terms = @($Glossary | Where-Object {
        -not [string]::IsNullOrEmpty([string]$_.Source) -and
        -not [string]::IsNullOrEmpty([string]$_.Target)
    } | Sort-Object -Property @{ Expression = { ([string]$_.Source).Length } } -Descending)
    if ($terms.Count -eq 0) { return $null }

    $alternatives = New-Object System.Collections.Generic.List[string]
    $targets      = New-Object System.Collections.Generic.List[string]
    foreach ($term in $terms) {
        $escaped = [regex]::Escape([string]$term.Source)
        $scoped  = if ($term.CaseSensitive) { '(?-i:' + $escaped + ')' } else { '(?i:' + $escaped + ')' }
        # The outer group is what the evaluator reads to pick the right target.
        $alternatives.Add('(' + $scoped + ')')
        $targets.Add([string]$term.Target)
    }

    $targetArray = $targets.ToArray()
    # GetNewClosure: .NET calls the delegate from outside this function's scope,
    # so the targets have to travel with it.
    $evaluator = {
        param($match)
        for ($group = 1; $group -lt $match.Groups.Count; $group++) {
            if ($match.Groups[$group].Success) { return $targetArray[$group - 1] }
        }
        return $match.Value
    }.GetNewClosure()
    return [pscustomobject]@{
        Glossary  = $Glossary
        Regex     = New-Object System.Text.RegularExpressions.Regex(($alternatives -join '|'))
        Evaluator = $evaluator
    }
}

function Expand-Glossary {
    param([string]$Text, [object[]]$Glossary)
    if ([string]::IsNullOrEmpty($Text) -or -not $Glossary) { return $Text }
    # The scan hands the same array to every row, so identity is a safe key and
    # the expression is compiled once per glossary load rather than per name.
    $pattern = $script:GlossaryPattern
    if (-not $pattern -or -not [object]::ReferenceEquals($pattern.Glossary, $Glossary)) {
        $pattern = New-GlossaryPattern -Glossary $Glossary
        if (-not $pattern) { return $Text }
        $script:GlossaryPattern = $pattern
    }
    return $pattern.Regex.Replace($Text, $pattern.Evaluator)
}

# --- Rename planner ----------------------------------------------------------
# Resolves every target path before anything moves: honours child-before-parent
# order, reorders chains (A -> B while B is also being renamed), breaks cycles
# with a numeric suffix, and reports rather than silently renaming over a file.

function Get-RenamePlan {
    param(
        [object[]]$Items,
        [bool]$AutoSuffix = $true,
        [int]$MaxSuffix = 999,
        [switch]$NoDiskCheck
    )

    $rows = @($Items)
    if ($rows.Count -eq 0) { return @() }

    $cycleIndexes = New-Object 'System.Collections.Generic.HashSet[int]'

    # Deepest path first, then lexical, so children move before their parents.
    # One precomputed key per row sorts in milliseconds at 20 000 rows, where
    # Sort-Object with calculated properties took seconds.
    $pending = New-Object 'int[]' $rows.Count
    for ($i = 0; $i -lt $rows.Count; $i++) { $pending[$i] = $i }
    if ($rows.Count -gt 1) {
        $sortKeys = New-Object 'string[]' $rows.Count
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $sortKeys[$i] = '{0:D6}|{1}' -f (999999 - [int]$rows[$i].Depth), ([string]$rows[$i].FullPath).ToUpperInvariant()
        }
        [System.Array]::Sort($sortKeys, $pending)
    }

    # Order the queue with path lookups instead of rescanning every row for
    # every step. The old loop was O(n^2) - 1 000 rows took 4 s and 2 000 took
    # 17 s, which froze the window at the end of a scan. A rename is blocked
    # only while its target is still occupied by a row that has not moved yet,
    # so one dictionary of source paths plus one walk per chain is enough.
    $sourceByIndex  = New-Object 'string[]' $rows.Count
    $dirByIndex     = New-Object 'string[]' $rows.Count
    $leafByIndex    = New-Object 'string[]' $rows.Count
    $desiredByIndex = New-Object 'string[]' $rows.Count
    $sourceIndex    = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $source = [string]$rows[$i].FullPath
        $leaf   = [string]$rows[$i].NewName
        $dir    = [System.IO.Path]::GetDirectoryName($source)
        # Join-Path costs tens of microseconds per call, which is seconds of the
        # planning time for a large queue; concatenating is equivalent once the
        # trailing separator is trimmed (a drive root keeps its "C:").
        if ($dir) { $dir = $dir.TrimEnd('\') }
        $sourceByIndex[$i]  = $source
        $dirByIndex[$i]     = $dir
        $leafByIndex[$i]    = $leaf
        $desiredByIndex[$i] = $dir + '\' + $leaf
        $sourceIndex[$source] = $i
    }

    $scheduled = New-Object 'System.Collections.Generic.HashSet[int]'
    $order = New-Object System.Collections.Generic.List[int]

    foreach ($start in $pending) {
        if ($scheduled.Contains($start)) { continue }

        # Fast path: nothing is in the way, so this row can move right now.
        # Building the chain objects below costs more than the check itself,
        # and at 20 000 rows almost no row is ever blocked.
        $first = 0
        $isBlocked = $sourceIndex.TryGetValue($desiredByIndex[$start], [ref]$first) -and
                     $first -ne $start -and -not $scheduled.Contains($first)
        if (-not $isBlocked) {
            [void]$scheduled.Add($start)
            $order.Add($start)
            continue
        }

        # Walk from this row to the head of its blocking chain: the first row
        # whose target is free or whose blocker has already moved. Scheduling
        # that chain backwards frees each path before the next one needs it.
        # Meeting a row twice means a swap cycle, which the suffix logic below
        # breaks; the chain is still scheduled in the same reverse order.
        $chain = New-Object System.Collections.Generic.List[int]
        $inChain = New-Object 'System.Collections.Generic.HashSet[int]'
        $current = $start
        $isCycle = $false
        while (-not $scheduled.Contains($current)) {
            if (-not $inChain.Add($current)) { $isCycle = $true; break }
            $chain.Add($current)
            $blocker = 0
            if ($sourceIndex.TryGetValue($desiredByIndex[$current], [ref]$blocker) -and
                $blocker -ne $current -and -not $scheduled.Contains($blocker)) {
                $current = $blocker
                continue
            }
            break
        }

        for ($position = $chain.Count - 1; $position -ge 0; $position--) {
            $idx = $chain[$position]
            if (-not $scheduled.Add($idx)) { continue }
            $order.Add($idx)
            if ($isCycle) { [void]$cycleIndexes.Add($idx) }
        }
    }

    $taken = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $movedSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $plan = New-Object System.Collections.Generic.List[object]

    foreach ($idx in $order) {
        $row = $rows[$idx]
        $source = $sourceByIndex[$idx]
        $dir = $dirByIndex[$idx]
        $desiredLeaf = $leafByIndex[$idx]
        $desired = $desiredByIndex[$idx]
        $finalLeaf = $desiredLeaf
        $note = ''
        $final = $desired
        $conflict = $false

        $caseOnly = ([string]::Equals($desired, $source, [StringComparison]::OrdinalIgnoreCase) -and
                     -not [string]::Equals($desired, $source, [StringComparison]::Ordinal))

        if (-not $caseOnly) {
            $onDisk = $false
            if (-not $NoDiskCheck) {
                # Inlined on purpose: a per-row function call costs more than
                # the two System.IO lookups it would wrap.
                $onDisk = ([System.IO.File]::Exists($desired) -or [System.IO.Directory]::Exists($desired))
                if ($onDisk -and $movedSources.Contains($desired)) { $onDisk = $false }
            }
            if ($onDisk -or $taken.Contains($desired)) { $conflict = $true }
        }

        if ($conflict) {
            if (-not $AutoSuffix) {
                $note = 'Name in use'
                $final = $null
                $finalLeaf = $null
            } else {
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($desiredLeaf)
                $ext  = [System.IO.Path]::GetExtension($desiredLeaf)
                if ([string]::IsNullOrEmpty($stem)) { $stem = $desiredLeaf; $ext = '' }
                $found = $null
                for ($n = 1; $n -le $MaxSuffix; $n++) {
                    $suffixedLeaf = '{0} ({1}){2}' -f $stem, $n, $ext
                    $candidate = $dir + '\' + $suffixedLeaf
                    if ($taken.Contains($candidate)) { continue }
                    if (-not $NoDiskCheck -and -not $movedSources.Contains($candidate) -and
                        ([System.IO.File]::Exists($candidate) -or [System.IO.Directory]::Exists($candidate))) { continue }
                    $found = $candidate
                    break
                }
                if ($found) {
                    $final = $found
                    $finalLeaf = $suffixedLeaf
                    $note = 'Collision resolved with suffix'
                } else {
                    $final = $null
                    $finalLeaf = $null
                    $note = 'No free name'
                }
            }
        }

        if ($final) { [void]$taken.Add($final) }
        [void]$movedSources.Add($source)

        $plan.Add([pscustomobject]@{
            Row        = $row
            Source     = $source
            Target     = $final
            DesiredLeaf = $desiredLeaf
            FinalLeaf  = $finalLeaf
            Note       = $note
            IsBlocked  = ($null -eq $final)
            IsCycle    = $cycleIndexes.Contains($idx)
            IsContainer = [bool]$row.IsContainer
        })
    }

    return $plan.ToArray()
}

# --- Journaled rename transaction -------------------------------------------

function Invoke-EntryRename {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [bool]$IsContainer
    )

    $source = ConvertTo-ExtendedPath $SourcePath
    $target = ConvertTo-ExtendedPath $TargetPath

    $sameIgnoringCase = [string]::Equals($SourcePath, $TargetPath, [StringComparison]::OrdinalIgnoreCase)
    $sameExactly      = [string]::Equals($SourcePath, $TargetPath, [StringComparison]::Ordinal)

    if ($sameExactly) { return }

    if ($sameIgnoringCase) {
        # NTFS is case-insensitive, so "foo" -> "Foo" looks like a collision to
        # a naive move. Go via a temporary name instead.
        $parent = [System.IO.Path]::GetDirectoryName($TargetPath)
        $staging = ConvertTo-ExtendedPath (Join-Path $parent ([System.IO.Path]::GetRandomFileName()))
        if ($IsContainer) {
            [System.IO.Directory]::Move($source, $staging)
            [System.IO.Directory]::Move($staging, $target)
        } else {
            [System.IO.File]::Move($source, $staging)
            [System.IO.File]::Move($staging, $target)
        }
        return
    }

    if ($IsContainer) {
        [System.IO.Directory]::Move($source, $target)
    } else {
        [System.IO.File]::Move($source, $target)
    }
}

function Resolve-TargetPath {
    param(
        [string]$Directory,
        [string]$DesiredName,
        [string]$SourcePath
    )

    $candidate = Join-Path $Directory $DesiredName
    if ([string]::Equals($candidate, $SourcePath, [StringComparison]::OrdinalIgnoreCase)) { return $candidate }
    if (-not (Test-PathExists $candidate)) { return $candidate }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($DesiredName)
    $ext  = [System.IO.Path]::GetExtension($DesiredName)
    if ([string]::IsNullOrEmpty($stem)) { $stem = $DesiredName; $ext = '' }

    for ($n = 1; $n -le 999; $n++) {
        $candidate = Join-Path $Directory ('{0} ({1}){2}' -f $stem, $n, $ext)
        if ([string]::Equals($candidate, $SourcePath, [StringComparison]::OrdinalIgnoreCase)) { return $candidate }
        if (-not (Test-PathExists $candidate)) { return $candidate }
    }
    return $null
}

# Journal first, then move: a crash after the record append is undoable, and a
# failed move is neutralised with a cancel record so undo never chases it.
function Invoke-PlannedRename {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [bool]$IsContainer,
        [string]$BatchId = 'manual'
    )

    $directory    = [System.IO.Path]::GetDirectoryName($SourcePath)
    $originalLeaf = [System.IO.Path]::GetFileName($SourcePath)
    $finalLeaf    = [System.IO.Path]::GetFileName($TargetPath)
    $timestamp    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $id           = [guid]::NewGuid().ToString('N')
    if ([string]::IsNullOrEmpty($BatchId)) { $BatchId = 'manual' }

    $null = Add-JournalRecord @{
        op = 'rename'; id = $id; batch = $BatchId; dir = $directory
        from = $originalLeaf; to = $finalLeaf; folder = [bool]$IsContainer; ts = $timestamp
    }

    try {
        Invoke-EntryRename -SourcePath $SourcePath -TargetPath $TargetPath -IsContainer $IsContainer
        return [pscustomobject]@{
            Ok = $true; Id = $id; BatchId = $BatchId; Directory = $directory
            OriginalLeaf = $originalLeaf; NewLeaf = $finalLeaf
            IsContainer = [bool]$IsContainer; Timestamp = $timestamp; Error = $null
        }
    } catch {
        $null = Add-JournalRecord @{ op = 'cancel'; id = $id }
        return [pscustomobject]@{
            Ok = $false; Id = $id; BatchId = $BatchId; Directory = $directory
            OriginalLeaf = $originalLeaf; NewLeaf = $finalLeaf
            IsContainer = [bool]$IsContainer; Timestamp = $timestamp; Error = $_.Exception.Message
        }
    }
}

function Invoke-PlannedUndo {
    param($Entry)

    $currentPath  = Join-Path ([string]$Entry.Directory) ([string]$Entry.NewLeaf)
    $restoredPath = Join-Path ([string]$Entry.Directory) ([string]$Entry.OriginalLeaf)

    if (-not (Test-Path -LiteralPath $currentPath)) {
        return [pscustomobject]@{ Ok = $false; RestoredPath = $restoredPath; Error = 'Missing (already moved)' }
    }
    try {
        Invoke-EntryRename -SourcePath $currentPath -TargetPath $restoredPath -IsContainer ([bool]$Entry.IsContainer)
        $null = Add-JournalRecord @{ op = 'undo'; id = [string]$Entry.Id }
        return [pscustomobject]@{ Ok = $true; RestoredPath = $restoredPath; Error = $null }
    } catch {
        return [pscustomobject]@{ Ok = $false; RestoredPath = $restoredPath; Error = $_.Exception.Message }
    }
}

# --- Provider pacing / throttling policy (pure, unit-tested) ----------------

# Backoff ladder for a throttled provider. The fourth throttle in a scan window
# trips the circuit breaker instead of sleeping: retrying a block for hours is
# worse than stopping with the cache intact.
function Get-ThrottleDecision {
    param([int]$ThrottleCount, [int]$MaxThrottles = 4)
    $count = if ($ThrottleCount -lt 1) { 1 } else { $ThrottleCount }
    if ($count -ge $MaxThrottles) {
        return [pscustomobject]@{ Fatal = $true; DelayMs = 0 }
    }
    # A 429 from the free endpoint usually clears inside a minute; five seconds
    # was short enough that the retry itself tripped the breaker.
    $base = 60000.0
    if ($env:TRANSLATENAMES_TEST_THROTTLE_BASE_MS) {
        try {
            $override = [int]$env:TRANSLATENAMES_TEST_THROTTLE_BASE_MS
            if ($override -gt 0) { $base = [double]$override }
        } catch { }
    }
    $delay = $base * [Math]::Pow(2, $count - 1)
    if ($delay -gt 180000) { $delay = 180000 }
    return [pscustomobject]@{ Fatal = $false; DelayMs = [int]$delay }
}

function New-ThrottleJitter {
    param([int]$DelayMs)
    if ($DelayMs -le 0) { return 0 }
    $span = [Math]::Max(1, [int]($DelayMs * 0.2))
    return [int](Get-Random -Minimum 0 -Maximum ($span + 1))
}

# HTTP 429/503, HTML instead of JSON, "unusual traffic" and empty responses all
# mean the same thing for our purposes: slow down, do not count it as a normal
# translation failure.
function Test-ThrottleSignal {
    param([int]$Status, [string]$Message)
    if ($Status -eq 429 -or $Status -eq 503) { return $true }
    if ([string]::IsNullOrEmpty($Message)) { return $false }
    return [bool]($Message -match 'unusual traffic|throttl|rate.?limit|captcha|HTML instead|Empty translation returned|Unexpected provider response')
}
'@

. ([scriptblock]::Create($script:HelperSource))

#endregion

#region ---------------------------------------------------------- Background worker

# Runs inside its own runspace. Everything it needs arrives through $Ctx, a
# synchronized hashtable; results come back through $Ctx.Queue, which the UI
# drains on a timer. Nothing here touches a WinForms object.
$script:ScanWorker = {
    param([hashtable]$Ctx, [int]$WorkerIndex = 0, [int]$WorkerCount = 1)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'   # Invoke-RestMethod is far slower with it on

    . ([scriptblock]::Create($Ctx.HelperSource))

    function Publish-Message { param($Message) $Ctx.Queue.Enqueue($Message) }

    function Wait-Cancellable {
        param([int]$Milliseconds)
        $remaining = $Milliseconds
        while ($remaining -gt 0 -and -not $Ctx.Cancel) {
            $slice = [Math]::Min(100, $remaining)
            Start-Sleep -Milliseconds $slice
            $remaining -= $slice
        }
    }

    # --- shared pacing and throttle gate (all workers share $Ctx) -----------

    function Enter-CtxLock { [System.Threading.Monitor]::Enter($Ctx.Lock) }
    function Exit-CtxLock { [System.Threading.Monitor]::Exit($Ctx.Lock) }

    function Next-ProcessedCount {
        Enter-CtxLock
        try { $Ctx.Processed = [int]$Ctx.Processed + 1; return [int]$Ctx.Processed }
        finally { Exit-CtxLock }
    }

    # Minimum gap between ANY two live requests across all workers. Parallelism
    # hides latency; it never raises the request rate.
    function Wait-RequestSlot {
        $interval = [int]$Ctx.DelayMs
        if ($interval -le 0) { return }
        $wait = 0
        Enter-CtxLock
        try {
            $now  = [DateTime]::UtcNow
            $next = [DateTime]$Ctx.NextRequestAt
            if ($next -gt $now) { $wait = [int][Math]::Min(30000, ($next - $now).TotalMilliseconds) }
            $base = if ($next -gt $now) { $next } else { $now }
            $Ctx.NextRequestAt = $base.AddMilliseconds($interval)
        } finally { Exit-CtxLock }
        if ($wait -gt 0) { Wait-Cancellable -Milliseconds $wait }
    }

    function Wait-ThrottleGate {
        while (-not $Ctx.Cancel -and -not $Ctx.FatalError) {
            $until = [DateTime]$Ctx.ThrottleUntil
            if ($until -le [DateTime]::UtcNow) {
                Enter-CtxLock
                try {
                    if ([DateTime]$Ctx.ThrottleUntil -le [DateTime]::UtcNow) { $Ctx.ThrottleUntil = [DateTime]::MinValue }
                } finally { Exit-CtxLock }
                break
            }
            $slice = [int][Math]::Min(500, ($until - [DateTime]::UtcNow).TotalMilliseconds)
            if ($slice -lt 50) { $slice = 50 }
            Wait-Cancellable -Milliseconds $slice
        }
        if ([int]$Ctx.ThrottleCount -gt 0) {
            $jitter = Get-Random -Minimum 0 -Maximum 250
            Wait-Cancellable -Milliseconds $jitter
        }
    }

    function Register-ThrottleEvent {
        param([string]$Reason)
        $decision = $null
        $count = 0
        Enter-CtxLock
        try {
            $now = [DateTime]::UtcNow
            if (-not $Ctx.ThrottleWindowStart) { $Ctx.ThrottleWindowStart = $now }
            if (($now - [DateTime]$Ctx.ThrottleWindowStart).TotalMinutes -gt 2) {
                $Ctx.ThrottleCount = 0
                $Ctx.ThrottleWindowStart = $now
            }
            $Ctx.ThrottleCount = [int]$Ctx.ThrottleCount + 1
            $count = [int]$Ctx.ThrottleCount
            $Ctx.SuccessSinceThrottle = 0
            $decision = Get-ThrottleDecision -ThrottleCount $count
            if ($decision.Fatal) {
                if (-not $Ctx.FatalError) {
                    $Ctx.FatalError = 'Translation provider is throttling this network (4 events in 2 minutes). Cached results are kept; retry later or switch provider.'
                }
            } else {
                $jitter = New-ThrottleJitter -DelayMs $decision.DelayMs
                $until = $now.AddMilliseconds($decision.DelayMs + $jitter)
                if ($until -gt [DateTime]$Ctx.ThrottleUntil) { $Ctx.ThrottleUntil = $until }
                $Ctx.LastThrottleReason = $Reason
            }
        } finally { Exit-CtxLock }
        if ($decision.Fatal) {
            Publish-Message @{ Kind = 'Warn'; Text = 'Provider throttled 4 times; stopping to avoid a longer block. Cached results are kept.' }
        } else {
            $seconds = [int][Math]::Round($decision.DelayMs / 1000)
            Publish-Message @{ Kind = 'Status'; Text = ("Provider throttled; pausing about {0}s (event {1}/3)." -f $seconds, $count) }
        }
        return $decision
    }

    # Throttle counters must not reset on a single good request: workers can
    # interleave successes and 429s. A healthy run of 20 successes in a row, or
    # two quiet minutes, clears the window instead.
    function Record-RequestSuccess {
        Enter-CtxLock
        try {
            $Ctx.SuccessSinceThrottle = [int]$Ctx.SuccessSinceThrottle + 1
            if ([int]$Ctx.SuccessSinceThrottle -ge 20) {
                $Ctx.ThrottleCount = 0
                $Ctx.ThrottleWindowStart = $null
                $Ctx.ThrottleUntil = [DateTime]::MinValue
                $Ctx.SuccessSinceThrottle = 0
            }
        } finally { Exit-CtxLock }
    }

    function Get-DeepLCode {
        param([string]$Code, [switch]$AsTarget)
        if ([string]::IsNullOrWhiteSpace($Code) -or $Code -eq 'auto') { return $null }
        $overrides = @{
            'zh-CN' = 'ZH'; 'zh-TW' = 'ZH'; 'no' = 'NB'; 'iw' = 'HE'; 'tl' = 'ID'
        }
        if ($overrides.ContainsKey($Code)) { return $overrides[$Code] }
        $upper = $Code.ToUpperInvariant()
        if ($AsTarget) {
            if ($upper -eq 'EN') { return 'EN-US' }
            if ($upper -eq 'PT') { return 'PT-BR' }
        }
        return $upper
    }

    function Invoke-GoogleTranslate {
        param([string]$Text, [string]$From, [string]$To, [int]$TimeoutSec)

        $url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl={0}&tl={1}&dt=t&dt=rm&q={2}' -f `
            [uri]::EscapeDataString($From), [uri]::EscapeDataString($To), [uri]::EscapeDataString($Text)

        if ($env:TRANSLATENAMES_TEST_THROTTLE) {
            throw 'Provider returned HTML instead of JSON (throttled). [test harness]'
        }

        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec $TimeoutSec `
            -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

        # A blocked gtx endpoint sometimes answers 200 with an HTML page. Treat
        # anything that is not the expected JSON array as a throttle signal.
        if ($response -is [string] -or $response -isnot [System.Array]) {
            throw 'Provider returned HTML or an unexpected payload (throttled).'
        }

        $parsed = ConvertFrom-GoogleResponse -Response $response
        $detected = if ([string]::IsNullOrWhiteSpace($parsed.Detected)) { $From } else { $parsed.Detected }
        return [pscustomobject]@{ Text = $parsed.Text; Detected = $detected; Romanized = $parsed.Romanized }
    }

    function Invoke-GoogleRomanize {
        param([string]$Text, [string]$From, [int]$TimeoutSec)
        $url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl={0}&tl=en&dt=rm&q={1}' -f `
            [uri]::EscapeDataString($From), [uri]::EscapeDataString($Text)
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec $TimeoutSec `
            -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        return (ConvertFrom-GoogleRomanization -Response $response)
    }

    function Invoke-DeepLTranslate {
        param([string]$Text, [string]$From, [string]$To, [string]$ApiKey, [int]$TimeoutSec)

        if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw 'DeepL API key is empty.' }

        $endpoint = if ($ApiKey.Trim() -match ':fx$') {
            'https://api-free.deepl.com/v2/translate'
        } else {
            'https://api.deepl.com/v2/translate'
        }

        $payload = @{ text = @($Text); target_lang = (Get-DeepLCode -Code $To -AsTarget) }
        $sourceCode = Get-DeepLCode -Code $From
        if ($sourceCode) { $payload['source_lang'] = $sourceCode }

        $body = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 3 -Compress))

        $response = Invoke-RestMethod -Uri $endpoint -Method Post -TimeoutSec $TimeoutSec `
            -Headers @{ Authorization = "DeepL-Auth-Key $($ApiKey.Trim())" } `
            -ContentType 'application/json; charset=utf-8' -Body $body

        if ($response -is [string]) { throw 'Provider returned HTML or an unexpected payload (throttled).' }

        $parsed = ConvertFrom-DeepLResponse -Response $response
        $detected = if ([string]::IsNullOrWhiteSpace($parsed.Detected)) { $From } else { $parsed.Detected }
        return [pscustomobject]@{ Text = $parsed.Text; Detected = $detected; Romanized = '' }
    }

    # Romanisation (Google only). Cached under its own key namespace.
    function Get-Romanization {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text) -or $Ctx.Provider -ne 'Google') { return '' }
        $key = 'rm|{0}|{1}' -f $Ctx.From, $Text
        if ($Ctx.Cache.ContainsKey($key)) { return ([string]$Ctx.Cache[$key].Text).Trim().TrimEnd('.') }
        try {
            Wait-ThrottleGate
            Wait-RequestSlot
            if ($Ctx.Cancel -or $Ctx.FatalError) { return '' }
            $roman = Invoke-GoogleRomanize -Text $Text -From $Ctx.From -TimeoutSec 15
            if ($Ctx.Cache.ContainsKey($key)) { return ([string]$Ctx.Cache[$key].Text) }
            $Ctx.Cache[$key] = [pscustomobject]@{ Text = $roman; Detected = '' }
            Record-RequestSuccess
            return $roman.Trim().TrimEnd('.')
        } catch {
            if (Test-ThrottleSignal -Status 0 -Message $_.Exception.Message) {
                [void](Register-ThrottleEvent -Reason $_.Exception.Message)
            }
            return ''
        }
    }

    function Get-Translation {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return [pscustomobject]@{ Text = $Text; Detected = $Ctx.From; FromCache = $true; Failed = $false; Skipped = $false }
        }

        $glossaryHit = Find-GlossaryTerm -Text $Text -Glossary $Ctx.Glossary
        if ($null -ne $glossaryHit) {
            return [pscustomobject]@{ Text = $glossaryHit; Detected = $Ctx.From; FromCache = $true; Failed = $false; Skipped = $false }
        }

        if ($Ctx.NoNetwork) {
            return [pscustomobject]@{ Text = $Text; Detected = $Ctx.From; FromCache = $false; Failed = $false; Skipped = $true }
        }

        $cacheKey = '{0}|{1}|{2}|{3}' -f $Ctx.Provider, $Ctx.From, $Ctx.To, $Text
        if ($Ctx.Cache.ContainsKey($cacheKey)) {
            $hit = $Ctx.Cache[$cacheKey]
            return [pscustomobject]@{
                Text      = (Expand-Glossary -Text ([string]$hit.Text) -Glossary $Ctx.Glossary)
                Detected  = $hit.Detected
                FromCache = $true
                Failed    = $false
                Skipped   = $false
            }
        }

        $lastError = $null
        $failureAttempts = 0
        $throttleEvents = 0
        while (-not $Ctx.Cancel -and -not $Ctx.FatalError) {
            # Every worker shares one pacing gate and one throttle gate.
            Wait-ThrottleGate
            Wait-RequestSlot
            if ($Ctx.Cancel -or $Ctx.FatalError) { break }
            try {
                $result = if ($Ctx.Provider -eq 'DeepL') {
                    Invoke-DeepLTranslate -Text $Text -From $Ctx.From -To $Ctx.To -ApiKey $Ctx.ApiKey -TimeoutSec 20
                } else {
                    Invoke-GoogleTranslate -Text $Text -From $Ctx.From -To $Ctx.To -TimeoutSec 20
                }

                if ([string]::IsNullOrWhiteSpace($result.Text)) { throw 'Empty translation returned.' }

                Record-RequestSuccess
                $Ctx.Cache[$cacheKey] = [pscustomobject]@{ Text = $result.Text; Detected = $result.Detected }
                return [pscustomobject]@{
                    Text      = (Expand-Glossary -Text $result.Text -Glossary $Ctx.Glossary)
                    Detected  = $result.Detected
                    FromCache = $false
                    Failed    = $false
                    Skipped   = $false
                }
            }
            catch {
                $lastError = $_
                $status = 0
                try {
                    if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                        $status = [int]$_.Exception.Response.StatusCode
                    }
                } catch { }

                # Auth failures will not fix themselves; surface them immediately.
                if ($status -eq 401 -or $status -eq 403) {
                    $Ctx.FatalError = "Authentication failed (HTTP $status). Check the API key."
                    break
                }

                if (Test-ThrottleSignal -Status $status -Message $_.Exception.Message) {
                    $throttleEvents++
                    $decision = Register-ThrottleEvent -Reason $_.Exception.Message
                    if ($decision.Fatal) { break }
                    continue
                }

                $failureAttempts++
                if ($failureAttempts -ge 3) { break }
                $jitter = Get-Random -Minimum 0 -Maximum 250
                $wait = [int](400 * [Math]::Pow(2, $failureAttempts - 1) + $jitter)
                Wait-Cancellable -Milliseconds $wait
            }
        }

        if ($lastError -and -not $Ctx.FatalError) {
            Publish-Message @{ Kind = 'Warn'; Text = "Translation failed for '$Text': $($lastError.Exception.Message)" }
        }
        return [pscustomobject]@{ Text = $Text; Detected = $Ctx.From; FromCache = $false; Failed = $true; Skipped = $false }
    }

    try {
        Publish-Message @{ Kind = 'Status'; Text = 'Scanning folder...' }

        $skipExtensions = @($Ctx.SkipExtensions)
        $excludeFolders = @($Ctx.ExcludeFolders)
        $candidates     = New-Object System.Collections.Generic.List[object]

        # One folder, or the whole set from a multi-select drop. Each root keeps
        # its own prefix, so relative locations and depth stay right per root.
        foreach ($root in @($Ctx.Roots)) {
            if ($Ctx.Cancel) { break }
            $rootPath   = ([string]$root).TrimEnd('\', '/')
            $isFileRoot = -not (Test-Path -LiteralPath $rootPath -PathType Container)
            $rootPrefix = if ($isFileRoot) { [System.IO.Path]::GetDirectoryName($rootPath) } else { $rootPath }

            $scanErrors = $null
            if ($isFileRoot) {
                # A file that was picked on purpose is queued as itself: the
                # include, depth, extension and exclude filters do not apply.
                $entries = @(Get-Item -LiteralPath $rootPath -Force -ErrorAction SilentlyContinue)
            } else {
                $gciParams = @{
                    LiteralPath = $rootPath
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }
                if ($Ctx.Recurse) {
                    $gciParams['Recurse'] = $true
                    if ([int]$Ctx.MaxDepth -gt 0) {
                        # -Depth bounds the walk itself, so an excluded deep tree costs nothing.
                        $gciParams['Depth'] = [int]$Ctx.MaxDepth
                    }
                }
                $entries = @(Get-ChildItem @gciParams -ErrorVariable scanErrors)
            }
            if ($scanErrors -and $scanErrors.Count -gt 0) {
                Publish-Message @{ Kind = 'Warn'; Text = "$($scanErrors.Count) path(s) could not be read (access denied or too long)." }
            }

            foreach ($entry in $entries) {
                if ($Ctx.Cancel) { break }
                $isContainer = $entry.PSIsContainer

                if (-not $isFileRoot) {
                    if ($isContainer -and -not $Ctx.IncludeFolders) { continue }
                    if (-not $isContainer -and -not $Ctx.IncludeFiles) { continue }

                    $attributes = $entry.Attributes
                    if (-not $Ctx.IncludeHidden -and (($attributes -band [System.IO.FileAttributes]::Hidden) -ne 0)) { continue }
                    if (($attributes -band [System.IO.FileAttributes]::System) -ne 0 -and -not $Ctx.IncludeHidden) { continue }
                }
                # Never rename junctions or symlinks; the target is not ours to touch.
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

                $relative = ConvertTo-RelativePath -Path $entry.FullName -Root $rootPrefix
                $depth    = Get-PathDepth $relative
                if (-not $isFileRoot -and [int]$Ctx.MaxDepth -gt 0 -and $depth -gt [int]$Ctx.MaxDepth) { continue }

                if (-not $isFileRoot -and $excludeFolders.Count -gt 0) {
                    $pathSegments = @($relative -split '[\\/]')
                    $folderSegments = if ($isContainer) { $pathSegments }
                                      elseif ($pathSegments.Count -gt 1) { @($pathSegments[0..($pathSegments.Count - 2)]) }
                                      else { @() }
                    $excluded = $false
                    foreach ($segmentName in $folderSegments) {
                        foreach ($pattern in $excludeFolders) {
                            if (Test-GlobMatch -Name $segmentName -Pattern $pattern) { $excluded = $true; break }
                        }
                        if ($excluded) { break }
                    }
                    if ($excluded) { continue }
                }

                $split = Split-EntryName -Name $entry.Name -IsContainer $isContainer
                if ([string]::IsNullOrWhiteSpace($split.Base)) { continue }

                if (-not $isFileRoot) {
                    if (-not $isContainer -and $skipExtensions.Count -gt 0) {
                        $ext = $split.Extension.TrimStart('.').ToLowerInvariant()
                        if ($ext -and ($skipExtensions -contains $ext)) { continue }
                    }

                    if ($Ctx.ExcludePattern) {
                        try {
                            # Match the leaf name or the relative path, so a whole subtree
                            # can be excluded with e.g. "^node_modules[\\/]".
                            if ([regex]::IsMatch($split.Base, $Ctx.ExcludePattern, 'IgnoreCase') -or
                                [regex]::IsMatch($relative, $Ctx.ExcludePattern, 'IgnoreCase')) { continue }
                        } catch { }
                    }
                }

                # Relative to one root is useful; with a mixed queue the honest
                # answer is the row's own parent folder.
                $relativeDir = if ($Ctx.MultiRoot) {
                    Get-ShortFolderPath -Path ([System.IO.Path]::GetDirectoryName($entry.FullName))
                } else {
                    [System.IO.Path]::GetDirectoryName($relative)
                }
                if ([string]::IsNullOrEmpty($relativeDir)) { $relativeDir = '.' }

                $candidates.Add([pscustomobject]@{
                    FullName    = $entry.FullName
                    Name        = $entry.Name
                    Base        = $split.Base
                    Extension   = $split.Extension
                    IsContainer = $isContainer
                    Depth       = $depth
                    RelativeDir = $relativeDir
                    Root        = $rootPrefix
                })
            }
        }

        # Deepest first: renaming a child before its parent keeps every queued
        # path valid. The planner reorders chains again before touching disk.
        $ordered = @($candidates | Sort-Object -Property @{ Expression = 'Depth'; Descending = $true }, @{ Expression = 'FullName'; Descending = $false })

        $Ctx.Total = $ordered.Count
        Publish-Message @{ Kind = 'Total'; Value = $ordered.Count }

        # Partition round-robin so each worker sees a mix of depths and folders.
        $myCandidates = $ordered
        if ($WorkerCount -gt 1) {
            $mine = New-Object System.Collections.Generic.List[object]
            for ($index = 0; $index -lt $ordered.Count; $index++) {
                if (($index % $WorkerCount) -eq $WorkerIndex) { $mine.Add($ordered[$index]) }
            }
            $myCandidates = $mine.ToArray()
        }

        foreach ($candidate in $myCandidates) {
            if ($Ctx.Cancel) { break }
            if ($Ctx.FatalError) { break }

            $processed = Next-ProcessedCount
            $base = $candidate.Base

            if ($Ctx.ListOnly) {
                # The list pass: show every candidate under its current name and
                # stop. Nothing is translated until Preview is pressed.
                Publish-Message @{
                    Kind        = 'Item'
                    FullPath    = $candidate.FullName
                    Root        = $candidate.Root
                    RelativeDir = $candidate.RelativeDir
                    Original    = $candidate.Name
                    NewName     = $candidate.Name
                    Extension   = $candidate.Extension
                    IsContainer = $candidate.IsContainer
                    Depth       = $candidate.Depth
                    Detected    = ''
                    State       = 'Queued'
                    Processed   = $processed
                }
                continue
            }

            $state = 'Preview'
            $detected = ''
            $newBase = $base
            $hasLetters = [regex]::IsMatch($base, '\p{L}')

            if (-not $hasLetters) {
                # Nothing to translate in "2024-01-15" or "[1080p]".
                $state = 'Unchanged'
                $detected = '-'
            } else {
                $segments = Get-NameSegments -Name $base -ProtectTags ([bool]$Ctx.ProtectTags)
                $assembled = New-Object System.Text.StringBuilder
                $failed = $false
                $offline = $false
                $translatedRuns = 0
                $firstDetected = $null

                foreach ($segment in $segments) {
                    if ($segment.Protected -or -not [regex]::IsMatch($segment.Text, '\p{L}')) {
                        [void]$assembled.Append($segment.Text)
                        continue
                    }
                    $raw = [string]$segment.Text
                    $lead = ''; $trail = ''; $core = $raw
                    if ($raw -match '^(\s*)(.*?)(\s*)$') {
                        $lead = $Matches[1]; $core = $Matches[2]; $trail = $Matches[3]
                    }
                    if ([string]::IsNullOrWhiteSpace($core)) {
                        [void]$assembled.Append($raw)
                        continue
                    }
                    $result = Get-Translation -Text $core
                    if ($result.Failed) { $failed = $true; break }
                    if ($result.Skipped) { $offline = $true }
                    $translatedRuns++
                    if (-not $firstDetected -and $result.Detected -and $result.Detected -ne $Ctx.From) {
                        $firstDetected = $result.Detected
                    }
                    [void]$assembled.Append($lead).Append([string]$result.Text).Append($trail)
                }

                if ($failed) {
                    $state = 'Failed'
                    $newBase = $base
                } elseif ($offline) {
                    $state = 'Skipped (offline)'
                    $newBase = $base
                } else {
                    $detected = if ($firstDetected) { $firstDetected }
                                elseif ($translatedRuns -eq 0) { '-' }
                                elseif ($Ctx.From -ne 'auto') { $Ctx.From }
                                else { '' }

                    $translated = Convert-NameCase -Text $assembled.ToString() -Mode $Ctx.CaseMode
                    $expanded   = Expand-NameTemplate -Template $Ctx.Template -Translated $translated -Original $base -Lang $detected
                    $expanded   = Expand-Glossary -Text $expanded -Glossary $Ctx.Glossary

                    if ($Ctx.Transliteration -and $Ctx.Transliteration -ne 'Off' -and (Test-HasNonLatinLetters $base)) {
                        $needsRomanization = ($Ctx.Transliteration -eq 'Replace') -or (Test-HasNonLatinLetters $expanded)
                        if ($needsRomanization) {
                            $roman = Get-Romanization -Text $base
                            if (-not [string]::IsNullOrWhiteSpace($roman)) {
                                if ($Ctx.Transliteration -eq 'Replace') {
                                    $expanded = $roman
                                } else {
                                    $expanded = '{0} ({1})' -f $expanded, $roman
                                }
                            }
                        }
                    }

                    $newBase = Get-SafeFileName -Name $expanded -MaxLength $Ctx.MaxNameLength

                    if ([string]::IsNullOrWhiteSpace($newBase)) {
                        $state = 'Unchanged'
                        $newBase = $base
                    } elseif ($newBase -ceq $base) {
                        $state = 'Unchanged'
                    } elseif ($Ctx.SkipIfTargetLang -and $detected -and $Ctx.To -ne 'auto' -and
                              $detected.ToLowerInvariant() -eq $Ctx.To.ToLowerInvariant()) {
                        # Already in the target language: the translation is
                        # skipped, but an explicit capitalisation choice still
                        # applies. "As returned" leaves the name alone, because
                        # the conversion is a no-op there.
                        $cased = Get-RecasedName -Base $base -Mode $Ctx.CaseMode -MaxLength $Ctx.MaxNameLength
                        if ($cased) {
                            $newBase = $cased
                        } else {
                            $state = 'Unchanged'
                            $newBase = $base
                        }
                    }
                }
            }

            Publish-Message @{
                Kind        = 'Item'
                FullPath    = $candidate.FullName
                Root        = $candidate.Root
                RelativeDir = $candidate.RelativeDir
                Original    = $candidate.Name
                NewName     = '{0}{1}' -f $newBase, $candidate.Extension
                Extension   = $candidate.Extension
                IsContainer = $candidate.IsContainer
                Depth       = $candidate.Depth
                Detected    = $detected
                State       = $state
                Processed   = $processed
            }
        }
    }
    catch {
        $Ctx.FatalError = $_.Exception.Message
    }
    finally {
        # Only the last worker announces completion, otherwise the UI would stop
        # draining while other workers are still translating.
        $remaining = 0
        Enter-CtxLock
        try {
            $Ctx.WorkersRemaining = [int]$Ctx.WorkersRemaining - 1
            $remaining = [int]$Ctx.WorkersRemaining
        } finally { Exit-CtxLock }
        if ($remaining -le 0) {
            $Ctx.Done = $true
            $Ctx.Queue.Enqueue(@{ Kind = 'Done' })
        }
    }
}

#endregion

#region ---------------------------------------------------------- Headless modes
# -SelfTest exercises the pure logic offline; -Plan runs a full scan and writes
# the proposed renames to CSV without touching a single file.

function Invoke-SelfTest {
    $script:TestPassed = 0
    $script:TestFailed = 0
    $script:TestFailures = New-Object System.Collections.Generic.List[string]

    function Write-TestCheck {
        param([string]$Name, [bool]$Pass, [string]$Detail = '')
        if ($Pass) {
            $script:TestPassed++
            Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor DarkGreen
        } else {
            $script:TestFailed++
            $script:TestFailures.Add($Name)
            Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { "  [$Detail]" } else { '' })) -ForegroundColor Red
        }
    }
    function Test-StringEqual {
        param([string]$Name, [string]$Actual, [string]$Expected)
        Write-TestCheck -Name $Name -Pass ([string]::Equals($Actual, $Expected, [StringComparison]::Ordinal)) -Detail ("expected '{0}' got '{1}'" -f $Expected, $Actual)
    }
    function New-TestFile {
        param([string]$Directory, [string]$Name)
        $path = Join-Path $Directory $Name
        Set-Content -LiteralPath $path -Value 'x' -Encoding ASCII
        return $path
    }
    function New-TestFolder {
        param([string]$Directory, [string]$Name)
        $path = Join-Path $Directory $Name
        $null = New-Item -ItemType Directory -Path $path -Force
        return $path
    }

    Write-Host "Translate Names $script:AppVersion - offline self-test" -ForegroundColor Cyan
    Write-Host "Safe name sanitising"

    Test-StringEqual 'invalid characters become underscores' (Get-SafeFileName -Name 'a<b>c:d"e/f\g|h?i*j' -MaxLength 120) 'a_b_c_d_e_f_g_h_i_j'
    Test-StringEqual 'reserved device name is prefixed' (Get-SafeFileName -Name 'CON' -MaxLength 120) '_CON'
    Test-StringEqual 'reserved device name keeps extension' (Get-SafeFileName -Name 'COM1.tar.gz' -MaxLength 120) '_COM1.tar.gz'
    Test-StringEqual 'trailing dots and spaces stripped' (Get-SafeFileName -Name 'name... ' -MaxLength 120) 'name'
    Test-StringEqual 'surrounding whitespace stripped' (Get-SafeFileName -Name '  spaced  ' -MaxLength 120) 'spaced'
    Test-StringEqual 'empty input stays empty' (Get-SafeFileName -Name '   ' -MaxLength 120) ''

    $emoji = [char]::ConvertFromUtf32(0x1F600)
    $emojiName = ('a' * 9) + $emoji + 'zzz'
    $emojiTruncated = Get-SafeTruncate -Text $emojiName -MaxLength 10
    $lastCharOk = ($emojiTruncated.Length -gt 0) -and (-not [char]::IsHighSurrogate($emojiTruncated[$emojiTruncated.Length - 1]))
    Write-TestCheck 'truncation never splits a surrogate pair' $lastCharOk ("len={0}" -f $emojiTruncated.Length)
    $safeEmoji = Get-SafeFileName -Name $emojiName -MaxLength 10
    Write-TestCheck 'safe name truncation keeps valid UTF-16' (($safeEmoji.Length -le 10) -and -not [char]::IsHighSurrogate($safeEmoji[$safeEmoji.Length - 1]))

    Write-Host "Name splitting and casing"
    $splitFile = Split-EntryName -Name 'Show.Name.mkv' -IsContainer $false
    Test-StringEqual 'file stem keeps inner dots' $splitFile.Base 'Show.Name'
    Test-StringEqual 'file extension extracted' $splitFile.Extension '.mkv'
    $splitDot = Split-EntryName -Name '.gitignore' -IsContainer $false
    Test-StringEqual 'dotfile is treated as a whole name' $splitDot.Base '.gitignore'
    Test-StringEqual 'dotfile has no extension' $splitDot.Extension ''
    $splitMulti = Split-EntryName -Name 'archive.tar.gz' -IsContainer $false
    Test-StringEqual 'multi-dot only splits the last extension' $splitMulti.Base 'archive.tar'
    $splitFolder = Split-EntryName -Name 'Some Folder' -IsContainer $true
    Test-StringEqual 'folder keeps full name' $splitFolder.Base 'Some Folder'
    Test-StringEqual 'folder has no extension' $splitFolder.Extension ''

    Test-StringEqual 'title case' (Convert-NameCase -Text 'hello world' -Mode 'Title Case') 'Hello World'
    Test-StringEqual 'sentence case' (Convert-NameCase -Text 'HELLO WORLD' -Mode 'Sentence case') 'Hello world'
    Test-StringEqual 'upper case' (Convert-NameCase -Text 'hello' -Mode 'UPPER CASE') 'HELLO'
    Test-StringEqual 'lower case' (Convert-NameCase -Text 'HELLO' -Mode 'lower case') 'hello'
    Test-StringEqual 'unknown mode is a no-op' (Convert-NameCase -Text 'Hello' -Mode 'As returned') 'Hello'
    Test-StringEqual 'target-language name still takes upper case' (Get-RecasedName -Base 'notes' -Mode 'UPPER CASE' -MaxLength 120) 'NOTES'
    Test-StringEqual 'as-returned leaves a target-language name alone' (Get-RecasedName -Base 'notes' -Mode 'As returned' -MaxLength 120) ''
    Test-StringEqual 'include label: both' (Get-IncludeLabel -Files $true -Folders $true) 'Files + folders'
    Test-StringEqual 'include label: files' (Get-IncludeLabel -Files $true -Folders $false) 'Files only'
    Test-StringEqual 'include label: folders' (Get-IncludeLabel -Files $false -Folders $true) 'Folders only'

    Write-Host "Unicode and emoji names"
    function New-Unicode {
        param([int[]]$Codes)
        return (-join ($Codes | ForEach-Object { [char]$_ }))
    }
    $cjkName = New-Unicode @(0x541B, 0x306E, 0x540D, 0x306F, 0x3002)
    Test-StringEqual 'CJK name passes through unchanged' (Get-SafeFileName -Name $cjkName -MaxLength 120) $cjkName
    $rtlName = (New-Unicode @(0x200F)) + (New-Unicode @(0x05E9, 0x05DD) )
    Test-StringEqual 'RTL mark is preserved' (Get-SafeFileName -Name $rtlName -MaxLength 120) $rtlName
    $familyEmoji = [char]::ConvertFromUtf32(0x1F468) + (New-Unicode @(0x200D)) + [char]::ConvertFromUtf32(0x1F469)
    $emojiSafe = Get-SafeFileName -Name $familyEmoji -MaxLength 120
    Test-StringEqual 'ZWJ emoji sequence survives sanitising' $emojiSafe $familyEmoji
    $combining = 'e' + (New-Unicode @(0x0301))
    Test-StringEqual 'combining accent is not stripped' (Get-SafeFileName -Name $combining -MaxLength 120) $combining
    Test-StringEqual 'name of only invalid characters becomes empty' (Get-SafeFileName -Name '???***' -MaxLength 120) ''
    $longName = ('x' * 300)
    Test-StringEqual 'very long input is truncated to the limit' ([string](Get-SafeFileName -Name $longName -MaxLength 120).Length) '120'

    Test-StringEqual 'template tokens expand' (Expand-NameTemplate -Template '{translated} [{original}] {lang}' -Translated 'Hello' -Original 'Original' -Lang 'ja') 'Hello [Original] ja'
    Test-StringEqual 'empty template falls back to translation' (Expand-NameTemplate -Template '' -Translated 'Hello' -Original 'x' -Lang 'ja') 'Hello'
    Test-StringEqual 'valid template has no issues' ([string]@(Get-NameTemplateIssues -Template '{translated} [{original}] {lang}').Count) '0'
    Test-StringEqual 'blank template is allowed' ([string]@(Get-NameTemplateIssues -Template '   ').Count) '0'
    Test-StringEqual 'template without {translated} is flagged' ([string]@(Get-NameTemplateIssues -Template 'Episode').Count) '1'
    $tokenIssues = @(Get-NameTemplateIssues -Template '{translatd}')
    Test-StringEqual 'typo token is flagged (and missing translated)' ([string]$tokenIssues.Count) '2'
    Write-TestCheck 'typo message names the token' ([bool](@($tokenIssues | Where-Object { $_ -match '\{translatd\}' }).Count)) ($tokenIssues -join ' / ')

    Write-Host "Throttling policy"
    Test-StringEqual 'first throttle backs off 60s' ([string](Get-ThrottleDecision -ThrottleCount 1).DelayMs) '60000'
    Test-StringEqual 'second throttle backs off 2m' ([string](Get-ThrottleDecision -ThrottleCount 2).DelayMs) '120000'
    Test-StringEqual 'third throttle is capped at 3m' ([string](Get-ThrottleDecision -ThrottleCount 3).DelayMs) '180000'
    Write-TestCheck 'fourth throttle trips the circuit breaker' ([bool](Get-ThrottleDecision -ThrottleCount 4).Fatal)
    Test-StringEqual 'backoff is capped at 3 minutes' ([string](Get-ThrottleDecision -ThrottleCount 8 -MaxThrottles 20).DelayMs) '180000'
    Write-TestCheck 'HTTP 429 is a throttle signal' ([bool](Test-ThrottleSignal -Status 429 -Message 'x'))
    Write-TestCheck 'HTTP 503 is a throttle signal' ([bool](Test-ThrottleSignal -Status 503 -Message 'x'))
    Write-TestCheck 'HTTP 401 is not a throttle signal' ([bool](-not (Test-ThrottleSignal -Status 401 -Message 'unauthorized')))
    Write-TestCheck 'HTML response is a throttle signal' ([bool](Test-ThrottleSignal -Status 200 -Message 'Provider returned HTML instead of JSON (throttled).'))
    $jitterOk = $true
    for ($i = 0; $i -lt 20; $i++) {
        $jitter = New-ThrottleJitter -DelayMs 10000
        if ($jitter -lt 0 -or $jitter -gt 2000) { $jitterOk = $false; break }
    }
    Write-TestCheck 'jitter stays within 20 percent' $jitterOk

    Write-Host "Release-tag segmentation"
    $segName = '[SubsPlease] One Piece - 1080p [x265]'
    $segments = Get-NameSegments -Name $segName -ProtectTags $true
    $joined = -join ($segments | ForEach-Object { $_.Text })
    Test-StringEqual 'segments reassemble exactly' $joined $segName
    $protected = @($segments | Where-Object { $_.Protected })
    Write-TestCheck 'brackets and resolution are protected' ($protected.Count -ge 2)
    $translatable = (@($segments | Where-Object { -not $_.Protected }) | ForEach-Object { $_.Text }) -join ''
    Write-TestCheck 'the title stays translatable' ($translatable -match 'One Piece')
    Write-TestCheck 'resolution stays protected' (($protected | ForEach-Object { $_.Text }) -contains '1080p')

    $episode = Get-NameSegments -Name 'Show.Name.S01E02.1080p.WEB-DL' -ProtectTags $true
    $episodeProtected = @($episode | Where-Object { $_.Protected } | ForEach-Object { $_.Text })
    Write-TestCheck 'S01E02 is protected' ($episodeProtected -contains 'S01E02')
    Write-TestCheck 'WEB-DL is protected' (($episodeProtected -contains 'WEB-DL') -or ($episodeProtected -contains 'WEBDL'))
    Write-TestCheck '1080p is protected' ($episodeProtected -contains '1080p')

    $noProtect = Get-NameSegments -Name $segName -ProtectTags $false
    Write-TestCheck 'switching protection off yields one segment' ((@($noProtect).Count -eq 1) -and (-not @($noProtect)[0].Protected))

    Write-Host "Provider response parsing"
    $googleFixture = @(
        @(
            @('What is your name?', 'Konnichiwa', $null, $null, 3, $null, $null, @(), @()),
            @($null, $null, $null, 'Kiminonaha.')
        ),
        $null,
        'ja'
    )
    $parsedGoogle = ConvertFrom-GoogleResponse -Response $googleFixture
    Test-StringEqual 'Google translation parsed' $parsedGoogle.Text 'What is your name?'
    Test-StringEqual 'Google detected language parsed' $parsedGoogle.Detected 'ja'
    Test-StringEqual 'Google romanisation parsed' $parsedGoogle.Romanized 'Kiminonaha.'
    $emptyGoogle = ConvertFrom-GoogleResponse -Response @()
    Test-StringEqual 'empty Google response yields empty text' $emptyGoogle.Text ''

    $deeplFixture = [pscustomobject]@{
        translations = @([pscustomobject]@{ text = 'Hallo'; detected_source_language = 'EN' })
    }
    $parsedDeepL = ConvertFrom-DeepLResponse -Response $deeplFixture
    Test-StringEqual 'DeepL translation parsed' $parsedDeepL.Text 'Hallo'
    Test-StringEqual 'DeepL detected language lowered' $parsedDeepL.Detected 'en'

    Write-Host "Glossary"
    $glossary = @(
        [pscustomobject]@{ Source = 'One Piece'; Target = 'One Piece'; CaseSensitive = $false }
        [pscustomobject]@{ Source = 'Nakama'; Target = 'Crewmate'; CaseSensitive = $false }
    )
    Test-StringEqual 'exact glossary hit' (Find-GlossaryTerm -Text 'one piece' -Glossary $glossary) 'One Piece'
    Test-StringEqual 'glossary expansion inside text' (Expand-Glossary -Text 'The nakama are here' -Glossary $glossary) 'The Crewmate are here'
    Test-StringEqual 'unknown term passes through' (Expand-Glossary -Text 'Something else' -Glossary $glossary) 'Something else'
    Test-StringEqual 'glossary replaces every occurrence' (Expand-Glossary -Text 'Nakama and nakama' -Glossary $glossary) 'Crewmate and Crewmate'

    # A shorter term must not win over a longer one that starts with it, and a
    # replacement must not be replaced again by the next term in the file.
    $glossaryOrder = @(
        [pscustomobject]@{ Source = 'Show';      Target = 'serial';  CaseSensitive = $false }
        [pscustomobject]@{ Source = 'Show Name'; Target = 'tytul';   CaseSensitive = $false }
    )
    Test-StringEqual 'glossary prefers the longer term' (Expand-Glossary -Text 'Show Name' -Glossary $glossaryOrder) 'tytul'
    Test-StringEqual 'shorter term still applies alone' (Expand-Glossary -Text 'Show' -Glossary $glossaryOrder) 'serial'
    $glossaryChain = @(
        [pscustomobject]@{ Source = 'Nakama';   Target = 'Crewmate'; CaseSensitive = $false }
        [pscustomobject]@{ Source = 'Crewmate'; Target = 'Shipmate'; CaseSensitive = $false }
    )
    Test-StringEqual 'glossary does not chain its own output' (Expand-Glossary -Text 'Nakama' -Glossary $glossaryChain) 'Crewmate'
    $glossaryMixed = @(
        [pscustomobject]@{ Source = 'Senpai'; Target = 'Senpai'; CaseSensitive = $true }
        [pscustomobject]@{ Source = 'Nakama'; Target = 'Crewmate'; CaseSensitive = $false }
    )
    Test-StringEqual 'case-sensitive term ignores other case' (Expand-Glossary -Text 'senpai' -Glossary $glossaryMixed) 'senpai'
    Test-StringEqual 'case-sensitive term matches its own case' (Expand-Glossary -Text 'Senpai' -Glossary $glossaryMixed) 'Senpai'
    Test-StringEqual 'mixed glossary keeps ignoring case' (Expand-Glossary -Text 'NAKAMA' -Glossary $glossaryMixed) 'Crewmate'

    Write-Host "Relative paths"
    Test-StringEqual 'relative path strips the root' (ConvertTo-RelativePath -Path 'C:\A\b\c' -Root 'C:\A') 'b\c'
    Test-StringEqual 'root matches itself' (ConvertTo-RelativePath -Path 'C:\A' -Root 'C:\A') '.'
    Test-StringEqual 'sibling with a shared prefix is not rewritten' (ConvertTo-RelativePath -Path 'C:\AB\x' -Root 'C:\A') 'C:\AB\x'

    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('translate-names-selftest-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $testRoot -Force
    try {
        Write-Host "Rename planner"
        $null = New-TestFile -Directory $testRoot -Name 'alpha.txt'
        $null = New-TestFile -Directory $testRoot -Name 'beta.txt'
        $simpleItems = @(
            [pscustomobject]@{ FullPath = (Join-Path $testRoot 'alpha.txt'); NewName = 'Gamma.txt'; IsContainer = $false; Depth = 1 }
            [pscustomobject]@{ FullPath = (Join-Path $testRoot 'beta.txt'); NewName = 'Delta.txt'; IsContainer = $false; Depth = 1 }
        )
        $simplePlan = Get-RenamePlan -Items $simpleItems -AutoSuffix $true
        Test-StringEqual 'simple plan covers every item' ([string]$simplePlan.Count) '2'
        Test-StringEqual 'simple plan keeps the requested leaf' ([System.IO.Path]::GetFileName($simplePlan[0].Target)) 'Gamma.txt'

        $null = New-TestFile -Directory $testRoot -Name 'existing.txt'
        $null = New-TestFile -Directory $testRoot -Name 'collide.txt'
        $collideItems = @(
            [pscustomobject]@{ FullPath = (Join-Path $testRoot 'collide.txt'); NewName = 'existing.txt'; IsContainer = $false; Depth = 1 }
        )
        $collidePlan = Get-RenamePlan -Items $collideItems -AutoSuffix $true
        Test-StringEqual 'on-disk collision gets a suffix' ([System.IO.Path]::GetFileName($collidePlan[0].Target)) 'existing (1).txt'
        Test-StringEqual 'suffixed collision is annotated' $collidePlan[0].Note 'Collision resolved with suffix'
        $strictPlan = Get-RenamePlan -Items $collideItems -AutoSuffix $false
        Write-TestCheck 'strict mode blocks instead of renaming over a file' ([bool]$strictPlan[0].IsBlocked)

        $null = New-TestFile -Directory $testRoot -Name 'chain-a.txt'
        $null = New-TestFile -Directory $testRoot -Name 'chain-b.txt'
        $chainItems = @(
            [pscustomobject]@{ FullPath = (Join-Path $testRoot 'chain-a.txt'); NewName = 'chain-b.txt'; IsContainer = $false; Depth = 1 }
            [pscustomobject]@{ FullPath = (Join-Path $testRoot 'chain-b.txt'); NewName = 'chain-c.txt'; IsContainer = $false; Depth = 1 }
        )
        $chainPlan = Get-RenamePlan -Items $chainItems -AutoSuffix $false
        $firstSource = [System.IO.Path]::GetFileName($chainPlan[0].Source)
        Test-StringEqual 'chains are ordered so the target is free first' $firstSource 'chain-b.txt'
        Write-TestCheck 'chain needs no suffix' ([bool]$chainPlan[1].Target)

        $null = New-TestFile -Directory $testRoot -Name 'swap-a.txt'
        $null = New-TestFile -Directory $testRoot -Name 'swap-b.txt'
        $swapItems = @(
            [pscustomobject]@{ FullPath = (Join-Path $testRoot 'swap-a.txt'); NewName = 'swap-b.txt'; IsContainer = $false; Depth = 1 }
            [pscustomobject]@{ FullPath = (Join-Path $testRoot 'swap-b.txt'); NewName = 'swap-a.txt'; IsContainer = $false; Depth = 1 }
        )
        $swapPlan = Get-RenamePlan -Items $swapItems -AutoSuffix $true
        $swapTargets = @($swapPlan | ForEach-Object { $_.Target })
        Write-TestCheck 'swap cycle terminates with two distinct targets' (($swapTargets.Count -eq 2) -and ($swapTargets[0] -ne $swapTargets[1]))

        $subFolder = New-TestFolder -Directory $testRoot -Name 'Sub'
        $null = New-TestFile -Directory $subFolder -Name 'inside.txt'
        $deepItems = @(
            [pscustomobject]@{ FullPath = $subFolder; NewName = 'Folder'; IsContainer = $true; Depth = 1 }
            [pscustomobject]@{ FullPath = (Join-Path $subFolder 'inside.txt'); NewName = 'outside.txt'; IsContainer = $false; Depth = 2 }
        )
        $deepPlan = Get-RenamePlan -Items $deepItems -AutoSuffix $true
        Test-StringEqual 'children are planned before their parent' ([System.IO.Path]::GetFileName($deepPlan[0].Source)) 'inside.txt'

        Write-Host "Planner at scale"
        # Regression guard for the scheduler: it used to rescan every row for
        # every step, so 2 000 rows took 17 s and a 20 000-row folder froze for
        # tens of minutes. The bound is deliberately generous - it only has to
        # catch a return to quadratic behaviour (5 000 rows would take > 100 s).
        $scaleCount = 5000
        $scaleItems = New-Object 'object[]' $scaleCount
        for ($i = 0; $i -lt $scaleCount; $i++) {
            $scaleItems[$i] = [pscustomobject]@{
                FullPath    = ($testRoot + ('\scale{0:D5}.txt' -f $i))
                NewName     = ('Renamed {0:D5}.txt' -f $i)
                IsContainer = $false
                Depth       = 1
            }
        }
        $scaleTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $scalePlan = @(Get-RenamePlan -Items $scaleItems -AutoSuffix $true -NoDiskCheck)
        $scaleTimer.Stop()
        Test-StringEqual 'planner covers every row at 5,000 items' ([string]$scalePlan.Count) ([string]$scaleCount)
        Write-TestCheck 'planner stays linear at 5,000 items (< 2000 ms)' ($scaleTimer.ElapsedMilliseconds -lt 2000) ("{0} ms" -f $scaleTimer.ElapsedMilliseconds)
        $scaleTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $scalePlan) { [void]$scaleTargets.Add([string]$entry.Target) }
        Test-StringEqual 'planner keeps every target distinct at scale' ([string]$scaleTargets.Count) ([string]$scaleCount)

        Write-Host "Journaled rename round-trip"
        $roundDir = New-TestFolder -Directory $testRoot -Name 'roundtrip'
        $null = New-TestFile -Directory $roundDir -Name 'first.txt'
        $null = New-TestFile -Directory $roundDir -Name 'second.txt'
        $oldJournalPath = $script:JournalPath
        $script:JournalPath = Join-Path $testRoot 'roundtrip-journal.jsonl'
        $roundBatch = [guid]::NewGuid().ToString('N')
        $r1 = Invoke-PlannedRename -SourcePath (Join-Path $roundDir 'first.txt') -TargetPath (Join-Path $roundDir 'First.txt') -IsContainer $false -BatchId $roundBatch
        $r2 = Invoke-PlannedRename -SourcePath (Join-Path $roundDir 'second.txt') -TargetPath (Join-Path $roundDir 'Second.txt') -IsContainer $false -BatchId $roundBatch
        Write-TestCheck 'planned renames succeed' ([bool]($r1.Ok -and $r2.Ok))
        Write-TestCheck 'renamed files exist' ((Test-Path -LiteralPath (Join-Path $roundDir 'First.txt')) -and (Test-Path -LiteralPath (Join-Path $roundDir 'Second.txt')))

        $pending = @(Get-PendingJournalBatches -Records (Get-JournalRecords))
        Test-StringEqual 'journal records one pending batch' ([string]$pending.Count) '1'
        Test-StringEqual 'journal records both renames' ([string]$pending[0].Entries.Count) '2'

        # Undo newest-first, exactly as Start-UndoJob orders it.
        $undo1 = Invoke-PlannedUndo -Entry $pending[0].Entries[1]
        $undo2 = Invoke-PlannedUndo -Entry $pending[0].Entries[0]
        Write-TestCheck 'planned undos succeed' ([bool]($undo1.Ok -and $undo2.Ok))
        $restoredNames = @(Get-ChildItem -LiteralPath $roundDir -File | ForEach-Object { $_.Name })
        Write-TestCheck 'original names restored (case exact)' (
            ($restoredNames -ccontains 'first.txt') -and ($restoredNames -ccontains 'second.txt') -and -not ($restoredNames -ccontains 'First.txt')
        ) ($restoredNames -join ',')

        $pending = @(Get-PendingJournalBatches -Records (Get-JournalRecords))
        Test-StringEqual 'journal is empty after a full undo' ([string]$pending.Count) '0'

        $null = New-TestFile -Directory $roundDir -Name 'casefile.txt'
        $caseResult = Invoke-PlannedRename -SourcePath (Join-Path $roundDir 'casefile.txt') -TargetPath (Join-Path $roundDir 'CASEFILE.TXT') -IsContainer $false -BatchId $roundBatch
        $caseLeaf = [System.IO.Path]::GetFileName((Get-ChildItem -LiteralPath $roundDir -File | Where-Object { $_.Name -like 'casefile*' } | Select-Object -First 1).FullName)
        Write-TestCheck 'case-only rename works and keeps the requested case' ([bool]($caseResult.Ok -and $caseLeaf -ceq 'CASEFILE.TXT')) ("leaf='" + $caseLeaf + "'")

        $folderToMove = New-TestFolder -Directory $roundDir -Name 'Fold'
        $null = New-TestFile -Directory $folderToMove -Name 'inner.txt'
        $folderResult = Invoke-PlannedRename -SourcePath $folderToMove -TargetPath (Join-Path $roundDir 'Folder') -IsContainer $true -BatchId $roundBatch
        Write-TestCheck 'folder rename moves the subtree' ([bool]($folderResult.Ok -and (Test-Path -LiteralPath (Join-Path $roundDir 'Folder\inner.txt'))))

        $script:JournalPath = $oldJournalPath

        Write-Host "Undo journal"
        $oldJournal = $script:JournalPath
        $script:JournalPath = Join-Path $testRoot 'journal.jsonl'
        $batchId = [guid]::NewGuid().ToString('N')
        $renameId1 = [guid]::NewGuid().ToString('N')
        $renameId2 = [guid]::NewGuid().ToString('N')
        $null = Add-JournalRecord @{ op = 'rename'; id = $renameId1; batch = $batchId; dir = $testRoot; from = 'one.txt'; to = 'One.txt'; folder = $false; ts = '2026-01-01 00:00:00' }
        $null = Add-JournalRecord @{ op = 'rename'; id = $renameId2; batch = $batchId; dir = $testRoot; from = 'two.txt'; to = 'Two.txt'; folder = $false; ts = '2026-01-01 00:00:01' }
        $journalRecords = Get-JournalRecords
        Test-StringEqual 'journal records round-trip' ([string]$journalRecords.Count) '2'
        $batches = Get-PendingJournalBatches -Records $journalRecords
        Test-StringEqual 'journal groups one batch' ([string]@($batches).Count) '1'
        Test-StringEqual 'journal batch holds both renames' ([string]@($batches)[0].Entries.Count) '2'
        $null = Add-JournalRecord @{ op = 'undo'; id = $renameId1 }
        $batches = Get-PendingJournalBatches -Records (Get-JournalRecords)
        Test-StringEqual 'undone rename leaves the pending set' ([string]@($batches)[0].Entries.Count) '1'
        $null = Add-JournalRecord @{ op = 'cancel'; id = $renameId2 }
        $batches = Get-PendingJournalBatches -Records (Get-JournalRecords)
        Test-StringEqual 'cancelled rename leaves the pending set' ([string]@($batches).Count) '0'
        Compress-Journal
        Test-StringEqual 'compressing an empty journal removes the file' ([string](Test-Path -LiteralPath $script:JournalPath)) 'False'
        $script:JournalPath = $oldJournal

        Write-Host "Corrupt data handling"
        $oldWarningPreference = $WarningPreference
        $WarningPreference = 'SilentlyContinue'
        $savedSettingsPath = $script:SettingsPath
        $savedCachePath    = $script:CachePath

        $script:SettingsPath = Join-Path $testRoot 'settings.json'
        [System.IO.File]::WriteAllText($script:SettingsPath, '{ this is not json', (New-Object System.Text.UTF8Encoding($false)))
        $brokenSettings = Import-Settings
        Test-StringEqual 'corrupt settings fall back to defaults' ([string]$brokenSettings.TargetLanguage) 'English'
        Test-StringEqual 'defaults still expose every settings key' ([string]@($brokenSettings.Keys).Count) ([string]@($script:DefaultSettings.Keys).Count)

        Set-ContentAtomic -Path $script:SettingsPath -Content '{"TargetLanguage":"German","Transliteration":"Bogus","MaxDepth":-5}'
        $partialSettings = Import-Settings
        Test-StringEqual 'valid partial settings are applied' ([string]$partialSettings.TargetLanguage) 'German'
        Test-StringEqual 'unknown transliteration mode is normalised' ([string]$partialSettings.Transliteration) 'Off'
        Test-StringEqual 'negative max depth is normalised' ([string]$partialSettings.MaxDepth) '0'

        $script:CachePath = Join-Path $testRoot 'cache.json'
        [System.IO.File]::WriteAllText($script:CachePath, 'not json at all', (New-Object System.Text.UTF8Encoding($false)))
        $brokenCache = Import-TranslationCache
        Test-StringEqual 'corrupt translation cache is ignored' ([string]$brokenCache.Count) '0'

        Set-ContentAtomic -Path $script:CachePath -Content '{"Google|auto|en|hello":{"t":"Hallo","d":"de"}}'
        $goodCache = Import-TranslationCache
        Test-StringEqual 'valid cache entries are read back' ([string]$goodCache['Google|auto|en|hello'].Text) 'Hallo'

        $script:SettingsPath = $savedSettingsPath
        $script:CachePath    = $savedCachePath

        # Two pending apply batches: the newest one must be exposed for undo.
        $script:JournalPath = Join-Path $testRoot 'multi-batch.jsonl'
        $batchA = [guid]::NewGuid().ToString('N')
        $batchB = [guid]::NewGuid().ToString('N')
        $null = Add-JournalRecord @{ op = 'rename'; id = [guid]::NewGuid().ToString('N'); batch = $batchA; dir = $testRoot; from = 'a1.txt'; to = 'A1.txt'; folder = $false; ts = '2026-01-01 00:00:00' }
        $null = Add-JournalRecord @{ op = 'rename'; id = [guid]::NewGuid().ToString('N'); batch = $batchB; dir = $testRoot; from = 'b1.txt'; to = 'B1.txt'; folder = $false; ts = '2026-01-02 00:00:00' }
        $batches = @(Get-PendingJournalBatches -Records (Get-JournalRecords))
        Test-StringEqual 'two apply batches are tracked' ([string]$batches.Count) '2'
        Test-StringEqual 'newest batch is ordered last' ([string]$batches[1].Entries[0].BatchId) $batchB
        Test-StringEqual 'oldest batch is ordered first' ([string]$batches[0].Entries[0].BatchId) $batchA

        # Journal corruption: garbage and null lines must be skipped harmlessly.
        [System.IO.File]::AppendAllText($script:JournalPath, "{broken json`n", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::AppendAllText($script:JournalPath, 'null' + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        Test-StringEqual 'malformed journal lines are skipped' ([string]@(Get-JournalRecords).Count) '2'

        $script:JournalPath = $oldJournal
        $WarningPreference = $oldWarningPreference
    } finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Write-Host 'Archil disk sync'
    $archilPlan = Get-ArchilSyncPlan -HostName 'PC-1' -Prefix 'translate-names'
    Test-StringEqual 'archil keeps shared files on the shared prefix' ([string]$archilPlan['settings.json']) 'translate-names/shared/settings.json'
    Test-StringEqual 'archil keeps the undo journal per host' ([string]$archilPlan['undo-journal.jsonl']) 'translate-names/hosts/pc-1/undo-journal.jsonl'
    Write-TestCheck 'archil sync stays off without an API key' (-not (Test-ArchilConfigured -ApiKey ''))
    Write-TestCheck 'archil rejects a disk token as the API key' (-not (Test-ArchilConfigured -ApiKey 'dsk-abc123'))
    Write-TestCheck 'archil accepts an account API key' (Test-ArchilConfigured -ApiKey 'key-abc123')

    Write-Host ''
    if ($script:TestFailed -gt 0) {
        Write-Host ("FAILED: {0} passed, {1} failed" -f $script:TestPassed, $script:TestFailed) -ForegroundColor Red
        foreach ($failure in $script:TestFailures) { Write-Host ("  - {0}" -f $failure) -ForegroundColor Red }
    } else {
        Write-Host ("OK: {0} checks passed" -f $script:TestPassed) -ForegroundColor Green
    }
    return $script:TestFailed
}

function Invoke-HeadlessPlan {
    param([string]$Folder, [string]$OutCsv, [switch]$Offline)

    $rootPath = [System.IO.Path]::GetFullPath(([string]$Folder).Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "Not a folder: $rootPath"
    }

    $settings = Import-Settings
    $glossary = Import-Glossary
    $cache    = Import-TranslationCache

    $fromName = if ($From) { $From } else { [string]$settings.SourceLanguage }
    $toName   = if ($To) { $To } else { [string]$settings.TargetLanguage }
    $fromKey  = @($script:LangMap.Keys | Where-Object { $_ -ieq $fromName }) | Select-Object -First 1
    $toKey    = @($script:LangMap.Keys | Where-Object { $_ -ieq $toName }) | Select-Object -First 1
    if (-not $fromKey) { throw "Unknown source language '$fromName'." }
    if (-not $toKey)   { throw "Unknown target language '$toName'." }

    $excludeFolders = @([string]$settings.ExcludeFolders -split '[;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $skipExtensions = @([string]$settings.SkipExtensions -split '[,;\s]+' | ForEach-Object { $_.Trim().TrimStart('.').ToLowerInvariant() } | Where-Object { $_ })

    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $ctx = [hashtable]::Synchronized(@{
        Roots             = @($rootPath)
        MultiRoot         = $false
        Recurse           = [bool]$settings.Recurse
        IncludeFiles      = [bool]$settings.IncludeFiles
        IncludeFolders    = [bool]$settings.IncludeFolders
        IncludeHidden     = [bool]$settings.IncludeHidden
        SkipIfTargetLang  = [bool]$settings.SkipIfTargetLang
        ExcludePattern    = [string]$settings.ExcludePattern
        ExcludeFolders    = $excludeFolders
        SkipExtensions    = $skipExtensions
        MaxDepth          = [int]$settings.MaxDepth
        Template          = [string]$settings.Template
        CaseMode          = [string]$settings.CaseMode
        MaxNameLength     = [int]$settings.MaxNameLength
        DelayMs           = if ($Offline) { 0 } else { [int]$settings.DelayMs }
        Provider          = [string]$settings.Provider
        ApiKey            = ''
        From              = [string]$script:LangMap[$fromKey]
        To                = [string]$script:LangMap[$toKey]
        Cache             = $cache
        HelperSource      = $script:HelperSource
        Queue             = $queue
        Cancel            = $false
        Done              = $false
        FatalError        = $null
        Total             = 0
        ProtectTags       = [bool]$settings.ProtectTags
        Transliteration   = [string]$settings.Transliteration
        Glossary          = $glossary
        NoNetwork         = [bool]$Offline
        ConsecutiveFailures = 0
        Lock              = (New-Object object)
        Processed         = 0
        WorkersRemaining  = 1
        ParallelRequests  = 1
        NextRequestAt     = [DateTime]::MinValue
        ThrottleCount     = 0
        ThrottleUntil     = [DateTime]::MinValue
        ThrottleWindowStart = $null
        SuccessSinceThrottle = 0
        LastThrottleReason = ''
    })

    & $script:ScanWorker $ctx

    $items = New-Object System.Collections.Generic.List[object]
    $fatal = $null
    $message = $null
    while ($ctx.Queue.TryDequeue([ref]$message)) {
        switch ($message.Kind) {
            'Item' { $items.Add($message) }
        }
    }
    $fatal = $ctx.FatalError

    $planInput = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if ($item.State -eq 'Unchanged' -or $item.State -eq 'Failed' -or $item.State -eq 'Queued') { continue }
        if ([string]::Equals([string]$item.NewName, [string]$item.Original, [StringComparison]::Ordinal)) { continue }
        $planInput.Add([pscustomobject]@{
            FullPath    = $item.FullPath
            NewName     = [string]$item.NewName
            IsContainer = [bool]$item.IsContainer
            Depth       = [int]$item.Depth
        })
    }

    $plan = @()
    if ($planInput.Count -gt 0) {
        $plan = @(Get-RenamePlan -Items $planInput.ToArray() -AutoSuffix ([bool]$settings.AutoSuffix))
    }
    $planBySource = @{}
    foreach ($entry in $plan) { $planBySource[([string]$entry.Source).ToLowerInvariant()] = $entry }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        $entry = $planBySource[([string]$item.FullPath).ToLowerInvariant()]
        $final = if ($entry -and $entry.Target) { [System.IO.Path]::GetFileName($entry.Target) } else { '' }
        $status = [string]$item.State
        $note = ''
        if ($entry) { $note = [string]$entry.Note }
        if ($entry -and $entry.IsBlocked) { $status = 'Conflict' }
        if ($status -eq 'Skipped (offline)') { $note = 'offline: not translated' }
        $rows.Add([pscustomobject]@{
            Type         = if ($item.IsContainer) { 'Folder' } else { 'File' }
            RelativeDir  = [string]$item.RelativeDir
            OriginalName = [string]$item.Original
            ProposedName = [string]$item.NewName
            FinalName    = $final
            Language     = [string]$item.Detected
            Status       = $status
            Note         = $note
            FullPath     = [string]$item.FullPath
        })
    }

    $targetCsv = if ($OutCsv) { [System.IO.Path]::GetFullPath($OutCsv) } else { Join-Path $script:DataDir 'translate-names-plan.csv' }
    $rows | Export-Csv -LiteralPath $targetCsv -NoTypeInformation -Encoding UTF8

    if (-not $Quiet) {
        Write-Host ("Plan for {0}" -f $rootPath) -ForegroundColor Cyan
        Write-Host ("  scanned: {0}  to rename: {1}  conflicts: {2}" -f $items.Count, $planInput.Count, @($plan | Where-Object { $_.IsBlocked }).Count)
        if ($fatal) { Write-Host ("  stopped: {0}" -f $fatal) -ForegroundColor Red }
        Write-Host ("  csv: {0}" -f $targetCsv) -ForegroundColor DarkGray
    }
    if ($fatal) { return 2 }
    return 0
}

if ($SelfTest) {
    $failures = Invoke-SelfTest
    exit ([int]$failures)
}
if ($Plan) {
    try {
        exit (Invoke-HeadlessPlan -Folder $Plan -OutCsv $PlanOut -Offline:$NoNetwork)
    } catch {
        Write-Error $_.Exception.Message
        exit 2
    }
}

#endregion

#region ---------------------------------------------------------- State

# Restore anything missing (settings, glossary, cache, undo journal) from the
# Archil disk before it is read. A no-op unless ARCHIL_API_KEY is set.
$null = Sync-ArchilSnapshot -Action Pull

$script:Settings       = Import-Settings
$script:Cache          = $null
$script:CacheLoaded    = $false
$script:CacheLoadedCount = 0
Write-BootLog 'state-loaded'
$script:Glossary       = Import-Glossary
$script:RecentFolders  = @()
if ($script:Settings.RecentFolders) {
    $script:RecentFolders = @(@($script:Settings.RecentFolders) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -First 8)
}
$script:PathComboUpdating = $false
$script:PreviewItems   = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
$script:UndoJournal    = New-Object System.Collections.Generic.List[object]
$script:UndoBatches    = @()
$script:FinalPlan      = @()
$script:GlossaryPattern = $null
# target path -> plan entry, so a single-row edit can tell in one lookup whether
# its new name is free without re-planning the whole queue.
$script:PlanIndex      = $null
$script:InstanceMutex  = $null
$script:SortColumn     = -1
$script:SortOrder      = [System.Windows.Forms.SortOrder]::Ascending
$script:Context        = $null
$script:Runspace       = $null
$script:PowerShell     = $null
$script:AsyncHandle    = $null
$script:Workers        = @()
$script:ScanRoot       = ''
# Every path the next preview will scan: one folder in the common case, or the
# whole set from a multi-select drop (folders and single files). Empty means
# "just what the folder box says".
$script:ScanRoots      = @()
$script:ScanMultiRoot  = $false
$script:Job            = $null
$script:Brushes        = @{}
$script:Busy           = $false
$script:BusyActivity   = ''

function Get-ThemeBrush {
    param([System.Drawing.Color]$Color)
    $key = $Color.ToArgb().ToString()
    if (-not $script:Brushes.ContainsKey($key)) {
        $script:Brushes[$key] = New-Object System.Drawing.SolidBrush($Color)
    }
    return $script:Brushes[$key]
}

#endregion

#region ---------------------------------------------------------- Control factories

function New-ThemedLabel {
    param([string]$Text, [switch]$Bold, [switch]$Subtle)
    $label = New-Object System.Windows.Forms.Label
    $label.Text     = $Text
    $label.AutoSize = $true
    $label.Anchor   = 'Left'
    $label.Margin   = New-Object System.Windows.Forms.Padding(0, (Scale-Px 6), (Scale-Px 8), (Scale-Px 4))
    $label.ForeColor = if ($Subtle) { $script:Theme.Subtle } else { $script:Theme.Foreground }
    if ($Bold) { $label.Font = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold) }
    return $label
}

function New-ThemedTextBox {
    param([string]$Text = '', [switch]$Password)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text        = $Text
    $box.Dock        = 'Fill'
    $box.BorderStyle = 'FixedSingle'
    $box.BackColor   = $script:Theme.ControlBack
    $box.ForeColor   = $script:Theme.ControlFore
    $box.Margin      = New-Object System.Windows.Forms.Padding(0, (Scale-Px 3), (Scale-Px 12), (Scale-Px 3))
    if ($Password) { $box.UseSystemPasswordChar = $true }
    return $box
}

function New-ThemedCombo {
    param([string[]]$Items, [string]$Selected)
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.FlatStyle     = 'Flat'
    $combo.Dock          = 'Fill'
    $combo.BackColor     = $script:Theme.ControlBack
    $combo.ForeColor     = $script:Theme.ControlFore
    $combo.Margin        = New-Object System.Windows.Forms.Padding(0, (Scale-Px 3), (Scale-Px 12), (Scale-Px 3))
    $combo.IntegralHeight = $false
    $combo.MaxDropDownItems = 18
    [void]$combo.Items.AddRange([object[]]$Items)
    if ($Selected -and $combo.Items.Contains($Selected)) { $combo.SelectedItem = $Selected }
    elseif ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
    return $combo
}

function New-ThemedCheckBox {
    param([string]$Text, [bool]$Checked)
    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text      = $Text
    $check.Checked   = $Checked
    $check.AutoSize  = $true
    $check.ForeColor = $script:Theme.Foreground
    $check.Margin    = New-Object System.Windows.Forms.Padding(0, (Scale-Px 3), 0, (Scale-Px 3))
    return $check
}

function New-ThemedNumeric {
    param([int]$Value, [int]$Minimum, [int]$Maximum, [int]$Increment = 1, [int]$Width = 90)
    $numeric = if ($script:InteropReady) {
        New-Object TranslateNames.WheelNumericUpDown
    } else {
        New-Object System.Windows.Forms.NumericUpDown
    }
    $numeric.Minimum     = $Minimum
    $numeric.Maximum     = $Maximum
    $numeric.Increment   = $Increment
    $numeric.Value       = [Math]::Max($Minimum, [Math]::Min($Maximum, $Value))
    $numeric.BorderStyle = 'FixedSingle'
    $numeric.BackColor   = $script:Theme.ControlBack
    $numeric.ForeColor   = $script:Theme.ControlFore
    $numeric.Width       = (Scale-Px $Width)
    $numeric.Anchor      = 'Left'
    $numeric.Margin      = New-Object System.Windows.Forms.Padding(0, (Scale-Px 3), (Scale-Px 12), (Scale-Px 3))
    return $numeric
}

function New-AccentButton {
    param([string]$Text, [System.Drawing.Color]$Accent, [int]$Width = 150, [switch]$Disabled, [switch]$FitText)
    $button = New-Object System.Windows.Forms.Button
    $button.Text      = $Text
    $button.Width     = (Scale-Px $Width)
    $button.Height    = (Scale-Px 34)
    $button.FlatStyle = 'Flat'
    $button.BackColor = $Accent
    $button.UseVisualStyleBackColor = $false
    $button.Margin    = New-Object System.Windows.Forms.Padding(0, 0, (Scale-Px 10), 0)
    $button.Enabled   = -not $Disabled
    if ($FitText) {
        # At 150%+ scaling a caption can be wider than its nominal width; let the
        # button grow to its text instead of clipping it.
        $button.AutoSize = $true
        $button.AutoSizeMode = 'GrowAndShrink'
        $button.MinimumSize = New-Object System.Drawing.Size((Scale-Px $Width), 0)
        $button.Padding = New-Object System.Windows.Forms.Padding((Scale-Px 8), (Scale-Px 2), (Scale-Px 8), (Scale-Px 2))
    }

    # Pick readable text for the accent instead of assuming white.
    $luminance = (0.299 * $Accent.R + 0.587 * $Accent.G + 0.114 * $Accent.B)
    $button.ForeColor = if ($luminance -gt 150) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
    $button.FlatAppearance.BorderSize = 0
    return $button
}

#endregion

#region ---------------------------------------------------------- Form

$form = New-Object System.Windows.Forms.Form
$form.Text            = "$script:AppName $script:AppVersion"
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Regular)
$form.AutoScaleMode   = 'Font'
$form.StartPosition   = 'CenterScreen'
$form.MinimumSize     = New-Object System.Drawing.Size((Scale-Px 480), (Scale-Px 400))
$form.AllowDrop       = $true
$form.BackColor       = $script:Theme.Background
$form.ForeColor       = $script:Theme.Foreground
$form.KeyPreview      = $true
$form.ClientSize      = New-Object System.Drawing.Size(
    [int]$script:Settings.WindowWidth,
    [int]$script:Settings.WindowHeight)

$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.AutoPopDelay = 20000
$tooltip.InitialDelay = 400
$tooltip.ReshowDelay  = 100

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock        = 'Fill'
$root.ColumnCount = 1
$root.RowCount    = 9
$root.Padding     = New-Object System.Windows.Forms.Padding((Scale-Px 12), (Scale-Px 10), (Scale-Px 12), (Scale-Px 8))
$root.BackColor   = $script:Theme.Background
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
foreach ($i in 0..4) {
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
}
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
foreach ($i in 0..2) {
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
}

# --- Row 0: folder picker -------------------------------------------------
$pathRow = New-Object System.Windows.Forms.TableLayoutPanel
$pathRow.Dock         = 'Fill'
$pathRow.AutoSize     = $true
$pathRow.AutoSizeMode = 'GrowAndShrink'
$pathRow.ColumnCount  = 3
$pathRow.RowCount     = 1
$pathRow.Margin       = New-Object System.Windows.Forms.Padding(0, 0, 0, (Scale-Px 8))
[void]$pathRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$pathRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$pathRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

$lblFolder = New-ThemedLabel -Text 'Folder'
$txtPath = New-Object System.Windows.Forms.ComboBox
$txtPath.DropDownStyle = 'DropDown'
$txtPath.FlatStyle     = 'Flat'
$txtPath.Dock          = 'Fill'
$txtPath.MaxLength     = 2048
$txtPath.BackColor     = $script:Theme.ControlBack
$txtPath.ForeColor     = $script:Theme.ControlFore
$txtPath.Text          = [string]$script:Settings.LastFolder
$txtPath.Margin        = New-Object System.Windows.Forms.Padding(0, (Scale-Px 4), (Scale-Px 8), (Scale-Px 4))
$btnBrowse = New-AccentButton -Text 'Browse...' -Accent $script:AccentNeutral -Width 104 -FitText
$btnBrowse.Margin = New-Object System.Windows.Forms.Padding(0, (Scale-Px 2), 0, (Scale-Px 2))

$pathRow.Controls.Add($lblFolder, 0, 0)
$pathRow.Controls.Add($txtPath,   1, 0)
$pathRow.Controls.Add($btnBrowse, 2, 0)

# --- Row 1: options -------------------------------------------------------
$options = New-Object System.Windows.Forms.TableLayoutPanel
$options.Dock         = 'Fill'
$options.AutoSize     = $true
$options.AutoSizeMode = 'GrowAndShrink'
$options.ColumnCount  = 5
$options.RowCount     = 9
$options.Margin       = New-Object System.Windows.Forms.Padding(0, 0, 0, (Scale-Px 10))
[void]$options.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$options.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$options.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$options.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$options.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

$languageNames = [string[]]$script:LangMap.Keys

$cmbProvider = New-ThemedCombo -Items @('Google', 'DeepL') -Selected ([string]$script:Settings.Provider)
$cmbSource   = New-ThemedCombo -Items $languageNames -Selected ([string]$script:Settings.SourceLanguage)
$cmbTarget   = New-ThemedCombo -Items $languageNames -Selected ([string]$script:Settings.TargetLanguage)
$cmbCase     = New-ThemedCombo -Items $script:CaseModes -Selected ([string]$script:Settings.CaseMode)
$txtApiKey   = New-ThemedTextBox -Text '' -Password
$txtTemplate = New-ThemedTextBox -Text ([string]$script:Settings.Template)
$txtExclude  = New-ThemedTextBox -Text ([string]$script:Settings.ExcludePattern)
$txtSkipExt  = New-ThemedTextBox -Text ([string]$script:Settings.SkipExtensions)
$numDelay    = New-ThemedNumeric -Value ([int]$script:Settings.DelayMs) -Minimum 0 -Maximum 10000 -Increment 50
$numMaxLen   = New-ThemedNumeric -Value ([int]$script:Settings.MaxNameLength) -Minimum 20 -Maximum 240 -Increment 5
$numDepth    = New-ThemedNumeric -Value ([int]$script:Settings.MaxDepth) -Minimum 0 -Maximum 99 -Increment 1
$numParallel = New-ThemedNumeric -Value ([int]$script:Settings.ParallelRequests) -Minimum 1 -Maximum 3 -Increment 1

$cmbTranslit = New-ThemedCombo -Items @('Off', 'Append', 'Replace') -Selected ([string]$script:Settings.Transliteration)

$lblApiKey = New-ThemedLabel -Text 'DeepL key'

$lblSource = New-ThemedLabel -Text 'From'
$lblTarget = New-ThemedLabel -Text 'To'

$options.Controls.Add((New-ThemedLabel -Text 'Provider'),        0, 0)
$options.Controls.Add($cmbProvider,                              1, 0)

# The two limits take the right-hand cells of these rows; the languages stay
# in the band above the grid, exactly as they do in Simple mode.
$lblMaxLen   = New-ThemedLabel -Text 'Max name length'
$lblDepth    = New-ThemedLabel -Text 'Max depth (0 = all)'
$options.Controls.Add($lblMaxLen,                               2, 0)
$options.Controls.Add($numMaxLen,                                3, 0)

$options.Controls.Add($lblApiKey,                                0, 1)
$options.Controls.Add($txtApiKey,                                1, 1)
$options.Controls.Add($lblDepth,                                 2, 1)
$options.Controls.Add($numDepth,                                 3, 1)

$options.Controls.Add((New-ThemedLabel -Text 'Capitalisation'),  0, 2)
$options.Controls.Add($cmbCase,                                  1, 2)

$options.Controls.Add((New-ThemedLabel -Text 'Request delay ms'), 0, 3)
$options.Controls.Add($numDelay,                                  1, 3)

$lblTemplate = New-ThemedLabel -Text 'Name template'
$options.Controls.Add($lblTemplate,  0, 4)
$options.Controls.Add($txtTemplate,  1, 4)
$options.SetColumnSpan($txtTemplate, 3)

$lblExclude = New-ThemedLabel -Text 'Exclude regex'
$options.Controls.Add($lblExclude,  0, 5)
$options.Controls.Add($txtExclude,  1, 5)
$options.SetColumnSpan($txtExclude, 3)

$lblSkipExt = New-ThemedLabel -Text 'Skip extensions'
$options.Controls.Add($lblSkipExt,  0, 6)
$options.Controls.Add($txtSkipExt,  1, 6)

$lblTranslit = New-ThemedLabel -Text 'Transliteration'
$options.Controls.Add($lblTranslit, 2, 6)
$options.Controls.Add($cmbTranslit, 3, 6)

$lblExcludeFolders = New-ThemedLabel -Text 'Skip folders'
$txtExcludeFolders = New-ThemedTextBox -Text ([string]$script:Settings.ExcludeFolders)
$options.Controls.Add($lblExcludeFolders, 0, 7)
$options.Controls.Add($txtExcludeFolders, 1, 7)
$options.SetColumnSpan($txtExcludeFolders, 3)

$lblParallel = New-ThemedLabel -Text 'Parallel requests'
$options.Controls.Add($lblParallel, 0, 8)
$options.Controls.Add($numParallel, 1, 8)
$lblParallelNote = New-ThemedLabel -Text '1 is safest; Google may throttle above that.' -Subtle
$options.Controls.Add($lblParallelNote, 2, 8)
$options.SetColumnSpan($lblParallelNote, 2)

$checkPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$checkPanel.FlowDirection = 'TopDown'
$checkPanel.WrapContents  = $false
$checkPanel.AutoSize      = $true
$checkPanel.AutoSizeMode  = 'GrowAndShrink'
$checkPanel.Margin        = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)

$chkFiles      = New-ThemedCheckBox -Text 'Include files'                  -Checked ([bool]$script:Settings.IncludeFiles)
$chkFolders    = New-ThemedCheckBox -Text 'Include folders'                -Checked ([bool]$script:Settings.IncludeFolders)
$chkRecurse    = New-ThemedCheckBox -Text 'Include subfolders'             -Checked ([bool]$script:Settings.Recurse)
$chkHidden     = New-ThemedCheckBox -Text 'Include hidden and system'      -Checked ([bool]$script:Settings.IncludeHidden)
$chkSkipTarget = New-ThemedCheckBox -Text 'Skip names already in target'   -Checked ([bool]$script:Settings.SkipIfTargetLang)
$chkHide       = New-ThemedCheckBox -Text 'Hide unchanged rows'            -Checked ([bool]$script:Settings.HideUnchanged)
$chkCsv        = New-ThemedCheckBox -Text 'Write CSV log on apply'         -Checked ([bool]$script:Settings.WriteCsvLog)
$chkProtect    = New-ThemedCheckBox -Text 'Preserve release tags'          -Checked ([bool]$script:Settings.ProtectTags)
$chkAutoSuffix = New-ThemedCheckBox -Text 'Auto-suffix collisions'         -Checked ([bool]$script:Settings.AutoSuffix)

foreach ($check in @($chkFiles, $chkFolders, $chkRecurse, $chkHidden, $chkSkipTarget, $chkHide, $chkCsv, $chkProtect, $chkAutoSuffix)) {
    [void]$checkPanel.Controls.Add($check)
}
$options.Controls.Add($checkPanel, 4, 0)
$options.SetRowSpan($checkPanel, 9)

Write-BootLog 'options-built'

# --- Row 0: simple/advanced switch ----------------------------------------
# Simple mode is the drag-drop-and-translate flow: folder, the two languages,
# a compact "Include" menu, the action buttons and the list. Everything else
# stays in the options grid above. The source/target combos are the same two
# objects in both modes - Set-UiMode reparents them, so settings, import and
# reset keep working on one copy of the state.
$modeRow = New-Object System.Windows.Forms.TableLayoutPanel
$modeRow.Dock         = 'Fill'
$modeRow.AutoSize     = $true
$modeRow.AutoSizeMode = 'GrowAndShrink'
$modeRow.ColumnCount  = 6
$modeRow.RowCount     = 1
$modeRow.Margin       = New-Object System.Windows.Forms.Padding(0, 0, 0, (Scale-Px 8))
foreach ($columnWidth in @('Auto', 50, 'Auto', 50, 'Auto', 'Auto')) {
    $style = if ($columnWidth -eq 'Auto') {
        New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)
    } else {
        New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, [double]$columnWidth)
    }
    [void]$modeRow.ColumnStyles.Add($style)
}

$menuInclude = New-Object System.Windows.Forms.ContextMenuStrip
$menuInclude.BackColor = $script:Theme.ControlBack
$menuInclude.ForeColor = $script:Theme.ControlFore
$menuIncFiles   = New-Object System.Windows.Forms.ToolStripMenuItem 'Include files'
$menuIncFolders = New-Object System.Windows.Forms.ToolStripMenuItem 'Include folders'
$menuIncRecurse = New-Object System.Windows.Forms.ToolStripMenuItem 'Include subfolders'
$menuIncHidden  = New-Object System.Windows.Forms.ToolStripMenuItem 'Include hidden and system'
foreach ($item in @($menuIncFiles, $menuIncFolders, $menuIncRecurse, $menuIncHidden)) {
    $item.CheckOnClick = $true
    [void]$menuInclude.Items.Add($item)
}
[void]$menuInclude.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$menuIncAdvanced = New-Object System.Windows.Forms.ToolStripMenuItem 'All options...'
[void]$menuInclude.Items.Add($menuIncAdvanced)

$btnInclude = New-AccentButton -Text 'Include...' -Accent $script:AccentNeutral -Width 96 -FitText
$btnInclude.ContextMenuStrip = $menuInclude
$btnInclude.Add_Click({
    $menuInclude.Show($btnInclude, (New-Object System.Drawing.Point(0, $btnInclude.Height)))
})
$menuIncAdvanced.Add_Click({ $chkAdvanced.Checked = $true })

$chkAdvanced = New-ThemedCheckBox -Text 'Advanced' -Checked $false
$chkAdvanced.Anchor = 'Right'

$modeRow.Controls.Add($lblSource,   0, 0)
$modeRow.Controls.Add($cmbSource,   1, 0)
$modeRow.Controls.Add($lblTarget,   2, 0)
$modeRow.Controls.Add($cmbTarget,   3, 0)
$modeRow.Controls.Add($btnInclude,  4, 0)
$modeRow.Controls.Add($chkAdvanced, 5, 0)

# --- Row 2: actions -------------------------------------------------------
$actions = New-Object System.Windows.Forms.FlowLayoutPanel
$actions.Dock         = 'Fill'
$actions.AutoSize     = $true
$actions.AutoSizeMode = 'GrowAndShrink'
$actions.Margin       = New-Object System.Windows.Forms.Padding(0, 0, 0, (Scale-Px 10))

$btnPreview = New-AccentButton -Text '&Preview translations' -Accent $script:AccentPrimary -Width 170 -FitText
$btnApply   = New-AccentButton -Text '&Apply renames'        -Accent $script:AccentApply   -Width 150 -Disabled -FitText
$btnUndo    = New-AccentButton -Text '&Undo last apply'      -Accent $script:AccentUndo    -Width 150 -Disabled -FitText
$btnCancel  = New-AccentButton -Text 'Cancel'                -Accent $script:AccentNeutral -Width 100 -Disabled -FitText
$btnClear   = New-AccentButton -Text 'C&lear list'           -Accent $script:AccentNeutral -Width 110 -FitText
$btnGlossary = New-AccentButton -Text '&Help / Glossary'     -Accent $script:AccentNeutral -Width 150 -FitText
$btnDefaults = New-AccentButton -Text 'De&faults'            -Accent $script:AccentNeutral -Width 110 -FitText

foreach ($button in @($btnPreview, $btnApply, $btnUndo, $btnCancel, $btnClear, $btnGlossary, $btnDefaults)) {
    [void]$actions.Controls.Add($button)
}

# --- Row 4: filter bar -----------------------------------------------------
$filterRow = New-Object System.Windows.Forms.TableLayoutPanel
$filterRow.Dock         = 'Fill'
$filterRow.AutoSize     = $true
$filterRow.AutoSizeMode = 'GrowAndShrink'
$filterRow.ColumnCount  = 4
$filterRow.RowCount     = 1
$filterRow.Margin       = New-Object System.Windows.Forms.Padding(0, 0, 0, (Scale-Px 6))
[void]$filterRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$filterRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$filterRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$filterRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

$lblFind = New-ThemedLabel -Text 'Find'
$txtFilter = New-ThemedTextBox
$txtFilter.Margin = New-Object System.Windows.Forms.Padding(0, (Scale-Px 2), (Scale-Px 8), (Scale-Px 2))
$chkFailedOnly = New-ThemedCheckBox -Text 'Failed only' -Checked $false
$chkConflictOnly = New-ThemedCheckBox -Text 'Conflicts only' -Checked $false

$filterRow.Controls.Add($lblFind,          0, 0)
$filterRow.Controls.Add($txtFilter,        1, 0)
$filterRow.Controls.Add($chkFailedOnly,    2, 0)
$filterRow.Controls.Add($chkConflictOnly,  3, 0)

# --- Row 5: results -------------------------------------------------------
$lvResults = if ($script:InteropReady) {
    New-Object TranslateNames.BufferedListView
} else {
    New-Object System.Windows.Forms.ListView
}
$lvResults.Dock          = 'Fill'
$lvResults.View          = 'Details'
$lvResults.FullRowSelect = $true
$lvResults.GridLines     = $false
$lvResults.HideSelection = $false
$lvResults.BackColor     = $script:Theme.ControlBack
$lvResults.ForeColor     = $script:Theme.ControlFore
$lvResults.BorderStyle   = 'FixedSingle'
$lvResults.Margin        = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
[void]$lvResults.Columns.Add('Type', (Scale-Px 58))
[void]$lvResults.Columns.Add('Lang', (Scale-Px 82))
[void]$lvResults.Columns.Add('Location', (Scale-Px 140))
[void]$lvResults.Columns.Add('Original name', (Scale-Px 210))
[void]$lvResults.Columns.Add('New name', (Scale-Px 210))
[void]$lvResults.Columns.Add('Status', (Scale-Px 90))
[void]$lvResults.Columns.Add('Final target', (Scale-Px 220))

$lvResults.VirtualMode = $true
$script:ViewRows = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
$script:RetrieveCount = 0
$lvResults.Add_RetrieveVirtualItem({
    param($sender, $e)
    if ($e.ItemIndex -ge 0 -and $e.ItemIndex -lt $script:ViewRows.Count) {
        $script:RetrieveCount++
        $e.Item = $script:ViewRows[$e.ItemIndex]
    }
})

$menu        = New-Object System.Windows.Forms.ContextMenuStrip
$menu.BackColor = $script:Theme.ControlBack
$menu.ForeColor = $script:Theme.ControlFore
$menuEdit    = New-Object System.Windows.Forms.ToolStripMenuItem 'Edit new name...'
$menuRevert  = New-Object System.Windows.Forms.ToolStripMenuItem 'Reset to translated name'
$menuOpen    = New-Object System.Windows.Forms.ToolStripMenuItem 'Show in Explorer'
$menuRemove  = New-Object System.Windows.Forms.ToolStripMenuItem 'Remove from queue'
$menuCopy    = New-Object System.Windows.Forms.ToolStripMenuItem 'Copy selected rows'
$menuExport  = New-Object System.Windows.Forms.ToolStripMenuItem 'Export preview to CSV...'
$menuEdit.ShortcutKeyDisplayString   = 'F2'
$menuRemove.ShortcutKeyDisplayString = 'Del'
$menuCopy.ShortcutKeyDisplayString   = 'Ctrl+C'
[void]$menu.Items.AddRange(@(
    $menuEdit, $menuRevert, $menuOpen,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $menuRemove, $menuCopy,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $menuExport
))
$lvResults.ContextMenuStrip = $menu
Write-BootLog 'list-built'

# --- Rows 4-6: progress, status -------------------------------------------
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Anchor  = 'Left,Right'
$progress.Height  = (Scale-Px 12)
$progress.Style   = 'Continuous'
$progress.Margin  = New-Object System.Windows.Forms.Padding(0, 0, 0, (Scale-Px 4))

# Fixed label heights are a classic high-DPI clipping bug: derive them from the
# font so the descenders always fit, and ellipsise instead of cutting words.
$script:LineHeight = [int][Math]::Ceiling($form.Font.GetHeight())

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Anchor       = 'Left,Right'
$lblStatus.AutoSize     = $false
$lblStatus.AutoEllipsis = $true
$lblStatus.Height       = $script:LineHeight + (Scale-Px 6)
$lblStatus.TextAlign    = 'MiddleLeft'
$lblStatus.ForeColor    = $script:Theme.Foreground
$lblStatus.Text         = 'Drop a folder onto this window, or use Browse.'

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Anchor       = 'Left,Right'
$lblHint.AutoSize     = $false
$lblHint.AutoEllipsis = $true
$lblHint.Height       = $script:LineHeight + (Scale-Px 2)
$lblHint.TextAlign    = 'MiddleLeft'
$lblHint.ForeColor    = $script:Theme.Subtle
$lblHint.Text         = 'F5 preview  -  F1 help  -  Ctrl+F find  -  F2 edit  -  Del remove  -  Esc cancel'

$root.Controls.Add($modeRow,   0, 0)
$root.Controls.Add($pathRow,   0, 1)
$root.Controls.Add($options,   0, 2)
$root.Controls.Add($actions,   0, 3)
$root.Controls.Add($filterRow, 0, 4)
$root.Controls.Add($lvResults, 0, 5)
$root.Controls.Add($progress,  0, 6)
$root.Controls.Add($lblStatus, 0, 7)
$root.Controls.Add($lblHint,   0, 8)

$form.Controls.Add($root)

# In-place editor for the "New name" column. A virtual-mode ListView forbids
# LabelEdit (there are no items to edit), so this is a plain TextBox floated
# over the cell that is being changed and taken down again on commit.
$txtCellEdit = New-ThemedTextBox
$txtCellEdit.Dock      = 'None'
$txtCellEdit.Margin    = New-Object System.Windows.Forms.Padding(0)
$txtCellEdit.Visible   = $false
$txtCellEdit.TabStop   = $false
$txtCellEdit.AccessibleName = 'New name'
$form.Controls.Add($txtCellEdit)
Write-BootLog 'chrome-added'

$tooltip.SetToolTip($txtPath,     'Folder to scan. Type a path and press Enter, pick a recent folder from the drop-down, or drag a folder onto the window.')
$tooltip.SetToolTip($txtTemplate, 'Tokens: {translated} {original} {lang}. Leave empty for {translated}. A template without {translated} gives every item the same name - the app warns before scanning.')
$tooltip.SetToolTip($txtExclude,  'Case-insensitive .NET regex matched against the leaf name and the relative path. Example: ^node_modules[\\/]')
$tooltip.SetToolTip($txtSkipExt,  'Extensions to leave alone, comma or space separated. Example: srt, nfo, jpg')
$tooltip.SetToolTip($txtExcludeFolders, 'Folder names to skip (wildcards allowed), separated by semicolons. Whole subtrees are ignored. Clearing this makes the app recurse into node_modules, .git, $RECYCLE.BIN and similar folders - it warns before scanning.')
$tooltip.SetToolTip($numDelay,    'Pause between live requests. Only applies on cache misses. Raise it if you hit HTTP 429.')
$tooltip.SetToolTip($numMaxLen,   'Maximum length of the translated part of the name, before the extension.')
$tooltip.SetToolTip($numDepth,    'How many folder levels below the selected folder to scan. 0 scans everything.')
$tooltip.SetToolTip($numParallel, 'Live translation workers: 1 (default, safest) to 3. All workers share one request rate and one throttle gate, so raising this hides latency but never increases the request rate. Google may still rate-limit; the scan pauses and then stops with a clear message if it happens repeatedly.')
$tooltip.SetToolTip($cmbTranslit, 'Romanise Japanese/Chinese/Korean/Cyrillic names. Append adds (romaji), Replace uses only the romanisation.')
$tooltip.SetToolTip($chkProtect,  'Keep release tags intact (S01E02, 1080p, x265, WEB-DL, [Group], ...) and translate only the title. Turn off to translate the whole name.')
$tooltip.SetToolTip($chkAutoSuffix, 'On: a taken name becomes "Name (1)". Off: conflicting items are skipped and reported.')
$tooltip.SetToolTip($txtApiKey,   'DeepL auth key. Keys ending in :fx use the free API endpoint. Not written to disk.')
$tooltip.SetToolTip($chkHidden,   'Hidden and system entries are skipped by default. Reparse points are always skipped.')
$tooltip.SetToolTip($btnUndo,     'Reverses the most recent apply, newest rename first. Survives restarts.')
$tooltip.SetToolTip($btnGlossary, 'Quick guide, glossary syntax, keyboard shortcuts and file locations.')
$tooltip.SetToolTip($btnDefaults, 'Restore the name template, skip folders, exclude regex and skip extensions to their default values.')

#endregion

#region ---------------------------------------------------------- Dark-mode polish

if ($script:IsDark) {
    # The ListView header is drawn by comctl32 in light colours regardless of
    # BackColor, so draw it ourselves and let the rows draw normally.
    $lvResults.OwnerDraw = $true
    $lvResults.Add_DrawColumnHeader({
        param($sender, $e)
        $e.Graphics.FillRectangle((Get-ThemeBrush $script:Theme.HeaderBack), $e.Bounds)
        $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                 [System.Windows.Forms.TextFormatFlags]::LeftAndRightPadding -bor
                 [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        [System.Windows.Forms.TextRenderer]::DrawText(
            $e.Graphics, $e.Header.Text, $e.Font, $e.Bounds, $script:Theme.Foreground, $flags)
        $pen = New-Object System.Drawing.Pen($script:Theme.HeaderLine)
        try {
            $e.Graphics.DrawLine($pen, $e.Bounds.Right - 1, $e.Bounds.Top + 4, $e.Bounds.Right - 1, $e.Bounds.Bottom - 4)
        } finally { $pen.Dispose() }
    })
    $lvResults.Add_DrawItem({    param($sender, $e) $e.DrawDefault = $true })
    $lvResults.Add_DrawSubItem({ param($sender, $e) $e.DrawDefault = $true })
}

$form.Add_HandleCreated({
    if ($script:InteropReady -and $script:IsDark) {
        [TranslateNames.Native]::SetDarkTitleBar($form.Handle, $true)
    }
})

#endregion

#region ---------------------------------------------------------- Simple / advanced UI

# One switch, two layouts. Simple mode hides the options grid and the filter
# bar (both AutoSize rows, so the list takes the freed space) and keeps the
# folder box, the two languages, the Include menu and the action buttons.

$script:UserMode     = 'Simple'
$script:ModeUpdating = $false

function Update-IncludeLabel {
    if (-not $btnInclude) { return }
    $btnInclude.Text = Get-IncludeLabel -Files ([bool]$chkFiles.Checked) -Folders ([bool]$chkFolders.Checked)
    $btnInclude.AccessibleName = $btnInclude.Text
}

function Update-IncludeMenu {
    $menuIncFiles.Checked   = [bool]$chkFiles.Checked
    $menuIncFolders.Checked = [bool]$chkFolders.Checked
    $menuIncRecurse.Checked = [bool]$chkRecurse.Checked
    $menuIncHidden.Checked  = [bool]$chkHidden.Checked
    Update-IncludeLabel
}

# Called with the option that was just cleared. When that would leave neither
# selected, the *other* one is turned on instead: one click switches between
# files, folders and both, and "neither" is never reachable. Re-checking the
# same box just looked like the click did nothing.
function Assert-IncludeChoice {
    param([string]$Cleared = 'files')
    if ([bool]$chkFiles.Checked -or [bool]$chkFolders.Checked) { return }
    if ($Cleared -eq 'files') {
        $chkFolders.Checked = $true
        Set-Status 'Switched to folders so something is included.'
    } else {
        $chkFiles.Checked = $true
        Set-Status 'Switched to files so something is included.'
    }
}

# Grow the window so the auto-sized chrome and a usable results list fit, then
# pin MinimumSize so the bottom rows cannot be shrunk back into clipping. Runs
# once on first show and again whenever the layout switches modes.
function Update-WindowFit {
    try {
        $form.PerformLayout()
        $heights = $root.GetRowHeights()
        $fixedHeight = $root.Padding.Top + $root.Padding.Bottom
        foreach ($index in @(0, 1, 2, 3, 4, 6, 7, 8)) { $fixedHeight += [int]$heights[$index] }
        $neededHeight = $fixedHeight + (Scale-Px 170)
        $actionsWidth = $actions.GetPreferredSize([System.Drawing.Size]::Empty).Width + $root.Padding.Horizontal
        $neededWidth = [Math]::Max([int](Scale-Px 760), [int]$actionsWidth)

        $working = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        $maxWidth  = [Math]::Max((Scale-Px 400), $working.Width  - (Scale-Px 40))
        $maxHeight = [Math]::Max((Scale-Px 320), $working.Height - (Scale-Px 60))
        $newWidth  = [Math]::Min([Math]::Max($form.ClientSize.Width,  $neededWidth),  $maxWidth)
        $newHeight = [Math]::Min([Math]::Max($form.ClientSize.Height, $neededHeight), $maxHeight)
        if ($newWidth -ne $form.ClientSize.Width -or $newHeight -ne $form.ClientSize.Height) {
            $form.ClientSize = New-Object System.Drawing.Size($newWidth, $newHeight)
        }

        $frameWidth  = $form.Width - $form.ClientSize.Width
        $frameHeight = $form.Height - $form.ClientSize.Height
        $form.MinimumSize = New-Object System.Drawing.Size(
            ($neededWidth + $frameWidth),
            ($neededHeight + $frameHeight))
    } catch { }
}

function Set-UiMode {
    param([string]$Mode, [switch]$Persist, [switch]$NoFit)

    $advanced = ([string]$Mode -eq 'Advanced')
    $script:UserMode = if ($advanced) { 'Advanced' } else { 'Simple' }

    # Languages and limits keep the same homes in both modes: the languages in
    # the top band (as in Simple) and the two limits in the grid's right column.
    # Simple mode only hides the grid, so nothing has to move between modes.

    $options.Visible    = $advanced
    $filterRow.Visible  = $advanced
    $btnInclude.Visible = -not $advanced
    $lblHint.Text = if ($advanced) {
        'F5 preview  -  F1 help  -  Ctrl+F find  -  F2 edit  -  Del remove  -  Esc cancel'
    } else {
        'Drop a folder here  -  F5 preview  -  F1 help  -  Esc cancel'
    }

    # Keep the checkbox in step with the mode without re-entering this function.
    $script:ModeUpdating = $true
    try {
        if ($chkAdvanced.Checked -ne $advanced) { $chkAdvanced.Checked = $advanced }
    } finally {
        $script:ModeUpdating = $false
    }

    Update-IncludeMenu
    if (-not $NoFit) {
        $form.PerformLayout()
        Update-WindowFit
    }
    if ($Persist) {
        Save-CurrentSettings
        Set-Status $(if ($advanced) { 'Advanced mode - every option is visible.' } else { 'Simple mode - Advanced shows every option.' })
    }
}

# Drop a folder and translate: Simple mode starts the preview on the folder the
# user deliberately picked (drop, Browse, typed path). Apply stays a click.
#endregion

#region ---------------------------------------------------------- Status and rows

function Set-Status {
    param([string]$Text)
    $lblStatus.Text = $Text
}

function Set-Progress {
    param([int]$Current, [int]$Total)
    if ($Total -le 0) { $progress.Value = 0; return }
    $percent = [int](($Current / $Total) * 100)
    $progress.Value = [Math]::Max(0, [Math]::Min(100, $percent))
}

$script:StateColors = @{
    'Preview'   = @{ Back = $script:Theme.ControlBack; Fore = $script:Theme.ControlFore }
    'Edited'    = @{ Back = $script:Theme.EditedBg;    Fore = $script:Theme.EditedFg }
    'Unchanged' = @{ Back = $script:Theme.UnchangedBg; Fore = $script:Theme.UnchangedFg }
    'Conflict'  = @{ Back = $script:Theme.ConflictBg;  Fore = $script:Theme.ConflictFg }
    'Failed'    = @{ Back = $script:Theme.ErrorBg;     Fore = $script:Theme.ErrorFg }
    'Missing'   = @{ Back = $script:Theme.ErrorBg;     Fore = $script:Theme.ErrorFg }
    'Error'     = @{ Back = $script:Theme.ErrorBg;     Fore = $script:Theme.ErrorFg }
    'Renamed'   = @{ Back = $script:Theme.SuccessBg;   Fore = $script:Theme.SuccessFg }
    'Restored'  = @{ Back = $script:Theme.ControlBack; Fore = $script:Theme.ControlFore }
    'Queued'    = @{ Back = $script:Theme.ControlBack; Fore = $script:Theme.UnchangedFg }
}

function Set-RowState {
    param(
        [System.Windows.Forms.ListViewItem]$Row,
        [string]$State,
        [string]$Detail
    )
    $Row.Tag.State = $State
    $Row.SubItems[5].Text = if ($Detail) { $Detail } else { $State }
    $colors = if ($script:StateColors.ContainsKey($State)) { $script:StateColors[$State] } else { $script:StateColors['Preview'] }
    $Row.BackColor = $colors.Back
    $Row.ForeColor = $colors.Fore
}

function Get-LanguageDisplay {
    param([string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return '' }
    if ($Code -eq '-') { return '-' }
    if ($script:CodeToName.ContainsKey($Code)) { return $script:CodeToName[$Code] }
    return $Code
}

function New-PreviewRow {
    param($Payload)

    $relative = [string]$Payload.RelativeDir
    if ([string]::IsNullOrEmpty($relative)) {
        try {
            $parent = [System.IO.Path]::GetDirectoryName($Payload.FullPath)
            $root = if ($Payload.Root) { [string]$Payload.Root } else { $script:ScanRoot }
            $relative = ConvertTo-RelativePath -Path $parent -Root $root
        } catch { $relative = '' }
    }
    if ([string]::IsNullOrEmpty($relative)) { $relative = '.' }

    $row = New-Object System.Windows.Forms.ListViewItem($(if ($Payload.IsContainer) { 'Folder' } else { 'File' }))
    [void]$row.SubItems.Add((Get-LanguageDisplay $Payload.Detected))
    [void]$row.SubItems.Add($relative)
    [void]$row.SubItems.Add($Payload.Original)
    [void]$row.SubItems.Add($Payload.NewName)
    [void]$row.SubItems.Add($Payload.State)
    [void]$row.SubItems.Add('')

    $row.Tag = [pscustomobject]@{
        FullPath     = $Payload.FullPath
        Root         = if ($Payload.Root) { [string]$Payload.Root } else { $script:ScanRoot }
        OriginalName = $Payload.Original
        NewName      = $Payload.NewName
        Extension    = $Payload.Extension
        IsContainer  = [bool]$Payload.IsContainer
        Depth        = [int]$Payload.Depth
        BaseState    = $Payload.State
        InitialState = $Payload.State
        State        = $Payload.State
        Translated   = $Payload.NewName
    }

    Set-RowState -Row $row -State $Payload.State
    return $row
}

function Test-RowVisible {
    param([System.Windows.Forms.ListViewItem]$Row)
    if ($chkHide.Checked -and $Row.Tag.BaseState -eq 'Unchanged') { return $false }
    $state = [string]$Row.Tag.State
    if ($chkFailedOnly.Checked -and $state -notin @('Failed', 'Error', 'Missing')) { return $false }
    if ($chkConflictOnly.Checked -and $state -ne 'Conflict') { return $false }
    $needle = [string]$txtFilter.Text
    if (-not [string]::IsNullOrWhiteSpace($needle)) {
        $haystack = (@($Row.SubItems | ForEach-Object { $_.Text }) -join ' | ')
        if ($haystack.IndexOf($needle.Trim(), [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

# Virtual-mode list plumbing. Rows live in $script:PreviewItems; $script:ViewRows
# holds only the rows currently visible (filter + sort applied), and the native
# ListView asks for an item only when it needs to paint one.
function Get-SelectedRows {
    $rows = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
    if (-not $lvResults.VirtualMode) {
        foreach ($row in $lvResults.SelectedItems) { $rows.Add($row) }
        return $rows.ToArray()
    }
    foreach ($index in $lvResults.SelectedIndices) {
        if ($index -ge 0 -and $index -lt $script:ViewRows.Count) { $rows.Add($script:ViewRows[$index]) }
    }
    return $rows.ToArray()
}

function Sort-ResultsRows {
    param([object[]]$Rows)
    if ($script:SortColumn -lt 0 -or $Rows.Count -le 1) { return $Rows }
    $array = [System.Windows.Forms.ListViewItem[]]$Rows
    if ($script:InteropReady) {
        $comparer = New-Object TranslateNames.NaturalListViewComparer($script:SortColumn, $script:SortOrder)
        [System.Array]::Sort($array, $comparer)
    } else {
        $column = $script:SortColumn
        $descending = $script:SortOrder -eq [System.Windows.Forms.SortOrder]::Descending
        $array = [System.Windows.Forms.ListViewItem[]]@($Rows | Sort-Object -Property @{
            Expression = { if ($_.SubItems.Count -gt $column) { $_.SubItems[$column].Text } else { '' } }
        } -Descending:$descending)
    }
    return $array
}

function Clear-ResultsView {
    try { $lvResults.SelectedIndices.Clear() } catch { }
    $script:ViewRows.Clear()
    $lvResults.VirtualListSize = 0
    $lvResults.Invalidate()
}

function Append-ResultsRows {
    param([object[]]$Rows)
    $added = 0
    foreach ($row in $Rows) {
        if (Test-RowVisible $row) {
            $script:ViewRows.Add($row)
            $added++
        }
    }
    if ($added -gt 0) {
        $lvResults.VirtualListSize = $script:ViewRows.Count
        $lvResults.Invalidate()
    }
}

function Update-ResultsView {
    # Rebuilding the view invalidates the row the editor is floating over.
    if ($script:CellEditRow) { Complete-CellEdit -Cancel }
    $lvResults.BeginUpdate()
    try {
        try { $lvResults.SelectedIndices.Clear() } catch { }
        # Inline the filter predicate: for 20k rows a Where-Object + function call
        # per row costs seconds, while this loop is a few hundred ms.
        $hideUnchanged = [bool]$chkHide.Checked
        $failedOnly    = [bool]$chkFailedOnly.Checked
        $conflictOnly  = [bool]$chkConflictOnly.Checked
        $needle        = ([string]$txtFilter.Text).Trim()
        $hasFilter     = -not [string]::IsNullOrWhiteSpace($needle)
        $visible = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
        foreach ($row in $script:PreviewItems) {
            if ($hideUnchanged -and $row.Tag.BaseState -eq 'Unchanged') { continue }
            $state = [string]$row.Tag.State
            if ($failedOnly -and $state -ne 'Failed' -and $state -ne 'Error' -and $state -ne 'Missing') { continue }
            if ($conflictOnly -and $state -ne 'Conflict') { continue }
            if ($hasFilter) {
                $haystack = (@($row.SubItems | ForEach-Object { $_.Text }) -join ' | ')
                if ($haystack.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            }
            $visible.Add($row)
        }
        $sorted = @(Sort-ResultsRows -Rows $visible.ToArray())
        $script:ViewRows.Clear()
        foreach ($row in $sorted) { $script:ViewRows.Add($row) }
        $lvResults.VirtualListSize = $script:ViewRows.Count
        $lvResults.Invalidate()
    } finally {
        $lvResults.EndUpdate()
    }
}

function Update-Counts {
    $total = $script:PreviewItems.Count
    if ($total -eq 0) {
        Set-Status 'No items in the queue.'
        return
    }

    # One pass with the filter inlined. The pipeline version (Where-Object plus a
    # function call per row) cost 1.6 s at 20 000 rows, on every edit now that
    # names are edited in the list.
    $hideUnchanged = [bool]$chkHide.Checked
    $failedOnly    = [bool]$chkFailedOnly.Checked
    $conflictOnly  = [bool]$chkConflictOnly.Checked
    $needle        = ([string]$txtFilter.Text).Trim()
    $hasFilter     = -not [string]::IsNullOrWhiteSpace($needle)

    $pending   = 0
    $unchanged = 0
    $conflicts = 0
    $failed    = 0
    $visible   = 0
    foreach ($row in $script:PreviewItems) {
        $state = [string]$row.Tag.State
        switch ($state) {
            'Unchanged' { $unchanged++ }
            'Conflict'  { $conflicts++; $pending++ }
            'Failed'    { $failed++ }
            'Renamed'   { }
            default     { $pending++ }
        }

        if ($hideUnchanged -and $row.Tag.BaseState -eq 'Unchanged') { continue }
        if ($failedOnly -and $state -ne 'Failed' -and $state -ne 'Error' -and $state -ne 'Missing') { continue }
        if ($conflictOnly -and $state -ne 'Conflict') { continue }
        if ($hasFilter) {
            $hit = $false
            foreach ($cell in $row.SubItems) {
                $text = [string]$cell.Text
                if ($text -and $text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
            }
            if (-not $hit) { continue }
        }
        $visible++
    }

    $message = "$total scanned  |  $pending to rename  |  $unchanged unchanged"
    if ($conflicts -gt 0) { $message += "  |  $conflicts name collision(s)" }
    if ($failed -gt 0)    { $message += "  |  $failed translation failure(s)" }
    if ($visible -ne $total) { $message += "  |  showing $visible" }
    Set-Status $message
}

# Resolve the whole batch against the disk before anything moves, and show the
# real final leaf in the "Final target" column. This is the single place that
# decides whether a name will be suffixed, skipped, or reordered as a chain.
function Update-FinalPlan {
    foreach ($row in $script:PreviewItems) {
        # Renamed rows keep the leaf they actually got; others are recomputed.
        if ($row.Tag.State -ne 'Renamed' -and $row.SubItems.Count -gt 6) { $row.SubItems[6].Text = '' }
        if ($row.Tag.State -eq 'Conflict') { Set-RowState -Row $row -State $row.Tag.BaseState }
    }

    $applyRows = @($script:PreviewItems | Where-Object {
        $_.Tag.BaseState -ne 'Unchanged' -and $_.Tag.BaseState -ne 'Failed' -and $_.Tag.BaseState -ne 'Queued' -and $_.Tag.State -ne 'Renamed'
    })

    $script:FinalPlan = @()
    $script:PlanIndex = $null
    if ($applyRows.Count -eq 0) { return }

    $items = @($applyRows | ForEach-Object {
        [pscustomobject]@{
            FullPath    = $_.Tag.FullPath
            NewName     = $_.Tag.NewName
            IsContainer = [bool]$_.Tag.IsContainer
            Depth       = [int]$_.Tag.Depth
            ListRow     = $_
        }
    })

    $plan = @(Get-RenamePlan -Items $items -AutoSuffix ([bool]$chkAutoSuffix.Checked))
    foreach ($entry in $plan) {
        $listRow = $entry.Row.ListRow
        if ($entry.Target) {
            if ($listRow.SubItems.Count -gt 6) { $listRow.SubItems[6].Text = $entry.FinalLeaf }
            if ($entry.Note) { Set-RowState -Row $listRow -State 'Conflict' -Detail ('-> ' + $entry.FinalLeaf) }
        } else {
            if ($listRow.SubItems.Count -gt 6) { $listRow.SubItems[6].Text = $entry.Note }
            Set-RowState -Row $listRow -State 'Conflict' -Detail $entry.Note
        }
    }
    $script:FinalPlan = $plan
    $script:PlanIndex = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $plan) {
        $target = [string]$entry.Target
        if ($target) { $script:PlanIndex[$target] = $entry }
    }
}

#endregion

#region ---------------------------------------------------------- Dialogs

function Show-Message {
    param(
        [string]$Text,
        [string]$Title = $script:AppName,
        [string]$Buttons = 'OK',
        [string]$Icon = 'Information'
    )
    # Automation hook for the end-to-end smoke test only (see Startup).
    if ($env:TRANSLATENAMES_SMOKE_APPLY -or $env:TRANSLATENAMES_SMOKE_SETTINGS) { return [System.Windows.Forms.DialogResult]::Yes }
    return [System.Windows.Forms.MessageBox]::Show($form, $Text, $Title, $Buttons, $Icon)
}

# Themed replacement for Microsoft.VisualBasic InputBox, which is unavailable
# on PowerShell 7 and always renders light.
function Show-InputDialog {
    param(
        [string]$Title,
        [string]$Prompt,
        [string]$Value
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text            = $Title
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.StartPosition   = 'CenterParent'
    $dialog.MinimizeBox     = $false
    $dialog.MaximizeBox     = $false
    $dialog.ClientSize      = New-Object System.Drawing.Size((Scale-Px 560), (Scale-Px 190))
    $dialog.BackColor       = $script:Theme.Background
    $dialog.ForeColor       = $script:Theme.Foreground
    $dialog.Font            = $form.Font

    $label = New-Object System.Windows.Forms.Label
    $label.Text      = $Prompt
    $label.Location  = New-Object System.Drawing.Point((Scale-Px 14), (Scale-Px 14))
    $label.Size      = New-Object System.Drawing.Size((Scale-Px 532), (Scale-Px 50))
    $label.ForeColor = $script:Theme.Foreground

    $input = New-Object System.Windows.Forms.TextBox
    $input.Text        = $Value
    $input.Location    = New-Object System.Drawing.Point((Scale-Px 14), (Scale-Px 74))
    $input.Size        = New-Object System.Drawing.Size((Scale-Px 532), (Scale-Px 30))
    $input.BorderStyle = 'FixedSingle'
    $input.BackColor   = $script:Theme.ControlBack
    $input.ForeColor   = $script:Theme.ControlFore

    $ok = New-AccentButton -Text 'OK' -Accent $script:AccentPrimary -Width 100
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancel = New-AccentButton -Text 'Cancel' -Accent $script:AccentNeutral -Width 100
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $buttonY = $dialog.ClientSize.Height - (Scale-Px 14) - $ok.Height
    $cancel.Location = New-Object System.Drawing.Point(($dialog.ClientSize.Width - (Scale-Px 14) - $cancel.Width), $buttonY)
    $ok.Location     = New-Object System.Drawing.Point(($cancel.Location.X - $ok.Width - (Scale-Px 10)), $buttonY)

    $dialog.Controls.AddRange(@($label, $input, $ok, $cancel))
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    $dialog.Add_Shown({
        if ($script:InteropReady -and $script:IsDark) {
            [TranslateNames.Native]::SetDarkTitleBar($dialog.Handle, $true)
        }
        $input.SelectAll()
        $input.Focus()
    })

    try {
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            return $input.Text
        }
        return $null
    } finally {
        $dialog.Dispose()
    }
}

function Select-FolderDialog {
    param([string]$Initial)
    $browser = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $browser.Description  = 'Select the folder whose names should be translated'
        $browser.ShowNewFolderButton = $false
        if ($Initial -and (Test-Path -LiteralPath $Initial -PathType Container)) {
            $browser.SelectedPath = $Initial
        }
        if ($browser.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            return $browser.SelectedPath
        }
        return $null
    } finally {
        $browser.Dispose()
    }
}

# Help / Glossary / Info. One window so the glossary button answers "what does
# this app do", explains the syntax and shows where everything lives.
function New-HelpDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text            = "$script:AppName $script:AppVersion - Help / Glossary"
    $dialog.FormBorderStyle = 'Sizable'
    $dialog.StartPosition   = 'CenterParent'
    $dialog.MinimizeBox     = $false
    $dialog.ShowInTaskbar   = $false
    $dialog.KeyPreview      = $true
    $dialog.BackColor       = $script:Theme.Background
    $dialog.ForeColor       = $script:Theme.Foreground
    $dialog.Font            = $form.Font
    $dialog.ClientSize      = New-Object System.Drawing.Size((Scale-Px 980), (Scale-Px 660))
    $dialog.MinimumSize     = New-Object System.Drawing.Size((Scale-Px 720), (Scale-Px 460))

    $about = @(
        ("Version: " + $script:AppVersion)
        ("Windows PowerShell: " + $PSVersionTable.PSVersion.ToString())
        ("Display scale: " + $script:DpiScale + "x")
        ("Provider: " + [string]$script:Settings.Provider + "   Target: " + [string]$script:Settings.TargetLanguage)
        ''
        'Data folder:'
        ('  ' + $script:DataDir)
        ''
        'Files:'
        ('  settings.json  ' + $script:SettingsPath)
        ('  cache.json     ' + $script:CachePath)
        ('  glossary.csv   ' + $script:GlossaryPath)
        ('  journal        ' + $script:JournalPath)
        ''
        ('Glossary terms loaded: ' + @($script:Glossary).Count)
        ('Undo batches pending: ' + @($script:UndoBatches).Count)
        ('Rows currently in the preview: ' + $script:PreviewItems.Count)
        ''
        'Portable mode: create an empty TranslateNames.portable file next to'
        'TranslateNames.exe, or start with -Portable. Data then lives in'
        'TranslateNamesData\ beside the exe.'
    ) -join [Environment]::NewLine

    $sections = @(
        [pscustomobject]@{ Title = 'Quick start'; Body = @'
The window has two layouts. Simple (the default) shows the folder box, the two
languages, an "Include..." menu, the buttons and the results. Tick "Advanced"
for every option at once; the choice is remembered. In Simple mode a folder you
pick on purpose - a drop, Browse, a recent folder, or a typed path plus Enter -
starts the preview immediately.

1. Browse to a folder, pick a recent one from the drop-down, or drag a folder
   onto the window. Drag as many folders or files as you like: everything you
   drop is queued together, and a file inside a dropped folder is not counted
   twice.
2. Pick source and target languages. Auto-Detect works for most cases.
3. Press "Preview translations" (F5) and wait for the rows.
4. Review "New name" and "Final target". Double-click the new name (or press
   F2) to edit it right in the list: Enter or Tab saves and moves to the next
   row, Shift+Tab to the previous one, Esc abandons the change.
   Delete drops a row from the queue.
5. Press "Apply renames" and confirm.
6. If anything looks wrong, press "Undo last apply". It works across restarts.

Nothing on disk changes until you press Apply.
'@ }
        [pscustomobject]@{ Title = 'Preview and apply'; Body = @'
Preview only builds a plan. Before Apply, every target path is resolved:

- two items translating to the same name get " (1)", " (2)", ...
  (or are skipped when "Auto-suffix collisions" is off);
- a name that already exists on disk is suffixed or blocked, never silently
  overwritten;
- rename chains such as A -> B while B -> C are reordered so B moves first;
- children are renamed before their parent folder;
- case-only renames go through a temporary name so NTFS accepts them.

The "Final target" column shows the leaf each row will really get.

The results list is virtualized: with 20,000 rows only the visible ones are
painted, so scrolling and filtering stay responsive. Filter and sort operate on
the model; Apply always uses the whole queue.
'@ }
        [pscustomobject]@{ Title = 'Undo and safety'; Body = @'
Every rename is appended to the undo journal BEFORE the file is moved, so a
crash or power cut cannot lose the trail. Locations:

  %LOCALAPPDATA%\TranslateNames\undo-journal.jsonl
  (portable: <exe folder>\TranslateNamesData\undo-journal.jsonl)

Undo restores the newest batch first. Older finished batches stay on disk, so
pressing Undo again can revert the previous apply as well. Failed renames keep
their entries pending. A partial undo never pretends to have restored
everything.

Closing during a scan cancels it; closing during Apply asks first.
'@ }
        [pscustomobject]@{ Title = 'Name template'; Body = @'
The template builds the new base name. Tokens:

  {translated}   the translated title
  {original}     the original base name
  {lang}         detected source language code

Examples:
  {translated}
  {translated} [{original}]
  {original} - {translated}

Leave it blank to use {translated}. The original extension is always kept.
Invalid characters are replaced and long names truncated. A template without
{translated} gives every item the same base name - the app warns before it
scans.
'@ }
        [pscustomobject]@{ Title = 'Skip folders and filters'; Body = @'
Skip folders: semicolon-separated folder-name globs, for example
  node_modules;.git;.svn;.hg;$RECYCLE.BIN;System Volume Information;Vendor;*.bak
A matching folder and its whole subtree are not scanned. Clearing the field
lets the app walk into version-control and package folders; it warns first.

Exclude regex: case-insensitive .NET regex tested against the leaf name and
the relative path, for example ^node_modules[\\/] or \.git$.

Skip extensions: comma or space separated, for example srt, nfo, jpg.
Max depth: 0 means everything below the chosen folder; 1 means direct children.
Include hidden and system: reparse points (junctions, symlinks) are always
skipped.
'@ }
        [pscustomobject]@{ Title = 'Glossary'; Body = @'
The glossary keeps names and terms that must not be translated, and can force
a specific translation.

File:
  %LOCALAPPDATA%\TranslateNames\glossary.csv
  (portable: <exe folder>\TranslateNamesData\glossary.csv)

One term per line:
  Source,Target[,CaseSensitive]

Examples:
  One Piece,One Piece,false
  Nakama,Crewmate,false
  Senpai,Senpai,true

Lines starting with # are comments. The third column is optional; 1/true/yes
means match case exactly. An exact match on a translatable segment wins; other
terms are substituted in the translated text. Longer terms win over shorter
ones that start with them ("Show Name" beats "Show"), and a substitution is
never substituted again in the same name. The file is reloaded before every
preview, and the button below opens it in Notepad.
'@ }
        [pscustomobject]@{ Title = 'Languages and providers'; Body = @'
Google uses the free web endpoint and needs no key. On large trees it can
throttle; raise "Request delay ms" if many requests fail.

DeepL needs an auth key (not written to disk). Keys ending in :fx use the free
api-free endpoint.

Parallel requests: 1 (default, safest) to 3. All workers share one request
rate (Request delay applies between any two requests in the whole scan) and
one throttle gate, so raising this hides latency but never increases the
request rate. If the provider answers 429/503, an HTML page or an empty body,
the scan pauses with exponential backoff (about 5s, 10s, 20s); a fourth event
within two minutes stops the scan and keeps everything cached for a later
retry. No proxy tricks are used.

Transliteration (Google only):
  Off      - keep the provider output
  Append   - add the romanisation in brackets when the result is still CJK
  Replace  - use only the romanisation (for example target = same language)

Preserve release tags keeps S01E02, 1080p, x265, WEB-DL, [Group], 第3話 and
similar tags intact and translates only the title. Turning it off translates
the whole name.
'@ }
        [pscustomobject]@{ Title = 'Keyboard and mouse'; Body = @'
F5              start preview
F2              edit the selected row's new name in place
Enter / Tab     in the editor: save and move to the next row
Shift+Tab       in the editor: save and move to the previous row
Esc             in the editor: abandon the change
Delete          remove selected rows from the queue
Ctrl+A          select all rows
Ctrl+C          copy selected rows
Esc             cancel the running scan or apply (or clear the Find box)
F1              open this help
Ctrl+Z          undo the last apply
Ctrl+F          focus the Find box
Ctrl+D          copy diagnostics to the clipboard

Double-click a row        edit its new name
Right-click a row         edit / reset / reveal / remove / copy / export
Drag a folder onto the window   load that folder
'@ }
        [pscustomobject]@{ Title = 'Tests and diagnostics'; Body = @'
Offline self-test (113 checks, no network):
  TranslateNames.exe -SelfTest
  powershell -File TranslateNamesApp.ps1 -SelfTest

Dry run without renaming, with or without translation:
  TranslateNames.exe -Plan "D:\SomeFolder" -NoNetwork -PlanOut plan.csv
  (GUI-subsystem exe: use Start-Process -Wait in scripts)

Failure suite (corpus, locked files, crash-kill, long paths):
  Run-CorpusTests.ps1   - see TESTING.md

Logs: rename-log-*.csv in the data folder, when "Write CSV log" is enabled.
Version snapshots: <data folder>\versions\TranslateNamesApp-<version>.ps1
'@ }
        [pscustomobject]@{ Title = 'Filtering the list'; Body = @'
The filter bar above the results changes only what you see; Apply still uses
the whole queue.

  Find            substring match across type, language, location, original
                  name, new name and status (case-insensitive).
  Failed only     translation failures, errors and missing rows.
  Conflicts only  rows whose new name collides with another row or with a
                  file already on disk.

Ctrl+F focuses the Find box. Press Esc while the Find box has focus to clear
it. The status line shows "showing N" when a filter hides rows.
'@ }
        [pscustomobject]@{ Title = 'Settings and diagnostics'; Body = @'
Settings live in %LOCALAPPDATA%\TranslateNames\settings.json
(portable: TranslateNamesData\settings.json). They are saved when you start a
preview and when the window closes.

Buttons at the bottom of this window:
  Export settings   save every option to a JSON file (the API key is never
                    saved or exported).
  Import settings   load such a file and apply it to the window.
  Reset settings    restore all shipped defaults. Cache, glossary and the undo
                    journal are not touched.
  Copy diagnostics  version, display scale, paths, current options, row and
                    undo counts plus recent warnings - ideal for a bug report.

Recent folders: the Folder box is a drop-down; the last eight folders are
remembered. Type a path and press Enter to load it.
'@ }
    )
    $sections += [pscustomobject]@{ Title = 'About this install'; Body = $about }

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock        = 'Fill'
    $layout.ColumnCount = 2
    $layout.RowCount    = 2
    $layout.Padding     = New-Object System.Windows.Forms.Padding((Scale-Px 10))
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, (Scale-Px 200))))
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $sectionList = New-Object System.Windows.Forms.ListBox
    $sectionList.Dock        = 'Fill'
    $sectionList.BorderStyle = 'FixedSingle'
    $sectionList.BackColor   = $script:Theme.ControlBack
    $sectionList.ForeColor   = $script:Theme.ControlFore
    $sectionList.IntegralHeight = $false
    $sectionList.Margin      = New-Object System.Windows.Forms.Padding(0, 0, (Scale-Px 8), (Scale-Px 8))
    foreach ($section in $sections) { [void]$sectionList.Items.Add($section.Title) }

    $bodyBox = New-Object System.Windows.Forms.RichTextBox
    $bodyBox.Dock        = 'Fill'
    $bodyBox.ReadOnly    = $true
    $bodyBox.BorderStyle = 'None'
    $bodyBox.BackColor   = $script:Theme.ControlBack
    $bodyBox.ForeColor   = $script:Theme.ControlFore
    $bodyBox.Font        = New-Object System.Drawing.Font('Consolas', 9.75, [System.Drawing.FontStyle]::Regular)
    $bodyBox.WordWrap    = $true
    $bodyBox.ScrollBars  = 'Vertical'
    $bodyBox.DetectUrls  = $false
    $bodyBox.Margin      = New-Object System.Windows.Forms.Padding(0, 0, 0, (Scale-Px 8))

    $sectionList.Add_SelectedIndexChanged({
        param($sender, $e)
        if ($sender.SelectedIndex -ge 0 -and $script:HelpSections -and $script:HelpBodyBox) {
            $script:HelpBodyBox.Text = $script:HelpSections[$sender.SelectedIndex].Body
            $script:HelpBodyBox.SelectionStart = 0
            $script:HelpBodyBox.SelectionLength = 0
        }
    })
    $script:HelpSections = $sections
    $script:HelpBodyBox = $bodyBox
    $startIndex = 0
    if ($env:TRANSLATENAMES_SMOKE_HELP_INDEX) {
        try {
            $candidateIndex = [int]$env:TRANSLATENAMES_SMOKE_HELP_INDEX
            if ($candidateIndex -ge 0 -and $candidateIndex -lt $sections.Count) { $startIndex = $candidateIndex }
        } catch { }
    }
    $sectionList.SelectedIndex = $startIndex
    $bodyBox.Text = $sections[$startIndex].Body

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock          = 'Fill'
    $buttons.FlowDirection = 'LeftToRight'
    # The six captions need ~940px. Wrapping lets the row use a second line in a
    # narrow window instead of running off the right edge, where the last two
    # buttons (Import/Reset settings) used to be cut off and unreachable.
    $buttons.WrapContents  = $true
    $buttons.AutoSize      = $true
    $buttons.AutoSizeMode  = 'GrowAndShrink'

    # No Close button: the title-bar X and Esc both close the window.
    $btnOpenGloss = New-AccentButton -Text 'Open glossary file' -Accent $script:AccentNeutral -Width 160
    $btnOpenData  = New-AccentButton -Text 'Open data folder' -Accent $script:AccentNeutral -Width 150
    $btnCopyDiag  = New-AccentButton -Text 'Copy diagnostics' -Accent $script:AccentNeutral -Width 150
    $btnExportSet = New-AccentButton -Text 'Export settings' -Accent $script:AccentNeutral -Width 140
    $btnImportSet = New-AccentButton -Text 'Import settings' -Accent $script:AccentNeutral -Width 140
    $btnResetSet  = New-AccentButton -Text 'Reset settings' -Accent $script:AccentNeutral -Width 140

    $btnOpenData.Add_Click({
        try {
            Initialize-DataDir
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:DataDir)
        } catch { }
    })
    $btnOpenGloss.Add_Click({
        try {
            if (-not (Test-Path -LiteralPath $script:GlossaryPath)) { $null = Import-Glossary }
            Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:GlossaryPath)
        } catch { }
    })
    $btnCopyDiag.Add_Click({
        if (Copy-Diagnostics) {
            [void](Show-Message -Text 'Diagnostics copied to the clipboard.' -Title 'Diagnostics' -Icon 'Information')
        }
    })
    $btnExportSet.Add_Click({ Export-SettingsFile })
    $btnImportSet.Add_Click({
        if (Import-SettingsFile) { $btnImportSet.FindForm().Close() }
    })
    $btnResetSet.Add_Click({
        if (Reset-AllSettings) { $btnResetSet.FindForm().Close() }
    })

    $script:HelpButtons = @($btnOpenGloss, $btnOpenData, $btnCopyDiag, $btnExportSet, $btnImportSet, $btnResetSet)
    foreach ($button in $script:HelpButtons) {
        [void]$buttons.Controls.Add($button)
    }

    $layout.Controls.Add($sectionList, 0, 0)
    $layout.Controls.Add($bodyBox,     1, 0)
    $layout.Controls.Add($buttons,     0, 1)
    $layout.SetColumnSpan($buttons, 2)
    $dialog.Controls.Add($layout)

    $dialog.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq 'Escape') {
            $sender.Close()
            $e.Handled = $true
        }
    })

    return $dialog
}

function Show-HelpDialog {
    $dialog = New-HelpDialog
    try {
        return $dialog.ShowDialog($form)
    } finally {
        $dialog.Dispose()
    }
}

#endregion

#region ---------------------------------------------------------- Rename engine

# Invoke-EntryRename, Resolve-TargetPath, Invoke-PlannedRename and
# Invoke-PlannedUndo live in the shared helper source so the offline self-test
# exercises the exact same transaction code the GUI applies.

#endregion

#region ---------------------------------------------------------- Undo journal

# Load the pending batches from the JSONL journal and expose the newest one in
# $script:UndoJournal (what the Undo button acts on). Older batches stay on
# disk and become undoable once the newest one has been reverted.
function Refresh-UndoState {
    $batches = @(Get-PendingJournalBatches -Records (Get-JournalRecords))
    $script:UndoBatches = @($batches)
    $script:UndoJournal = New-Object System.Collections.Generic.List[object]

    if ($batches.Count -eq 0) { return }

    $latest = $batches[$batches.Count - 1]
    foreach ($entry in $latest.Entries) { $script:UndoJournal.Add($entry) }
}

function Get-UndoBatchSummary {
    if ($script:UndoBatches.Count -eq 0) { return '' }
    $latest = $script:UndoBatches[$script:UndoBatches.Count - 1]
    $older = $script:UndoBatches.Count - 1
    $summary = "Undo available: {0} rename(s) from {1}." -f $latest.Entries.Count, $latest.Timestamp
    if ($older -gt 0) { $summary += " {0} older batch(es) also pending." -f $older }
    return $summary
}

#endregion

#region ---------------------------------------------------------- Worker plumbing

$script:ScanTotal     = 0
$script:ScanProcessed = 0
$script:ScanFinished  = $false
$script:Warnings      = New-Object System.Collections.Generic.List[string]

$timerDrain = New-Object System.Windows.Forms.Timer
$timerDrain.Interval = 75

$timerJob = New-Object System.Windows.Forms.Timer
$timerJob.Interval = 10

function Clear-ScanWorker {
    param([switch]$Abandon)
    # -Abandon is used when the window is closing: waiting on EndInvoke could
    # block for up to the HTTP timeout, and the process is about to exit anyway.
    if (-not $Abandon) {
        foreach ($worker in @($script:Workers)) {
            try {
                if ($worker.PowerShell -and $worker.Handle) { [void]$worker.PowerShell.EndInvoke($worker.Handle) }
            } catch { }
            try { if ($worker.PowerShell) { $worker.PowerShell.Dispose() } } catch { }
            try {
                if ($worker.Runspace) {
                    $worker.Runspace.Close()
                    $worker.Runspace.Dispose()
                }
            } catch { }
        }
    }
    $script:Workers     = @()
    $script:PowerShell  = $null
    $script:Runspace    = $null
    $script:AsyncHandle = $null
}

function Set-BusyState {
    param([bool]$Busy, [string]$Activity = '')
    $script:Busy = $Busy
    $btnPreview.Enabled = -not $Busy
    $btnBrowse.Enabled  = -not $Busy
    $btnCancel.Enabled  = $Busy
    if ($btnClear) { $btnClear.Enabled = -not $Busy }
    if ($Busy) {
        $btnApply.Enabled = $false
        $btnUndo.Enabled  = $false
    } else {
        $pending = @($script:PreviewItems | Where-Object {
            $_.Tag.BaseState -ne 'Unchanged' -and $_.Tag.BaseState -ne 'Failed' -and $_.Tag.BaseState -ne 'Queued' -and $_.Tag.State -ne 'Renamed'
        }).Count
        $btnApply.Enabled = ($pending -gt 0)
        $btnUndo.Enabled  = ($script:UndoJournal.Count -gt 0)
    }
    $script:BusyActivity = $Activity
}

# Refresh the buttons without pretending the window is idle. Row actions used
# to call Set-BusyState -Busy $false, which re-enabled Preview in the middle of
# a scan (starting a second one orphans the running workers) and disabled
# Cancel in the middle of an apply.
function Update-ActionState {
    Set-BusyState -Busy ([bool]$script:Busy) -Activity $script:BusyActivity
}

function Complete-Scan {
    $timerDrain.Stop()
    Clear-ScanWorker

    $fatal = if ($script:Context) { $script:Context.FatalError } else { $null }
    $cancelled = if ($script:Context) { [bool]$script:Context.Cancel } else { $false }
    $listOnly = if ($script:Context) { [bool]$script:Context.ListOnly } else { $false }

    Update-FinalPlan
    Update-ResultsView
    Save-TranslationCacheIfChanged
    Set-Progress 1 1
    Set-BusyState -Busy $false
    Update-Counts

    if ($fatal) {
        Set-Status "Stopped: $fatal"
        [void](Show-Message -Text $fatal -Title 'Translation stopped' -Icon 'Warning')
    } elseif ($cancelled) {
        Set-Status ("Cancelled after {0} item(s)." -f $script:PreviewItems.Count)
    } elseif ($listOnly) {
        Set-Status ("{0} item(s) listed. Press Preview translations (F5) to translate them." -f $script:PreviewItems.Count)
    }

    if ($script:Warnings.Count -gt 0) {
        $lblStatus.Text += "  |  $($script:Warnings.Count) warning(s)"
        $tooltip.SetToolTip($lblStatus, (($script:Warnings | Select-Object -First 20) -join [Environment]::NewLine))
    }

    $script:Context = $null
}

function Receive-WorkerMessages {
    if (-not $script:Context) { $timerDrain.Stop(); return }

    $message = $null
    $newRows = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
    $drained = 0

    while ($drained -lt 400 -and $script:Context.Queue.TryDequeue([ref]$message)) {
        $drained++
        switch ($message.Kind) {
            'Total' {
                $script:ScanTotal = [int]$message.Value
                if ($script:ScanTotal -eq 0) { Set-Status 'Nothing matched the current filters.' }
            }
            'Status' { Set-Status ([string]$message.Text) }
            'Warn'   { $script:Warnings.Add([string]$message.Text) }
            'Item'   {
                $row = New-PreviewRow $message
                $script:PreviewItems.Add($row)
                if (Test-RowVisible $row) { $newRows.Add($row) }
                $script:ScanProcessed = [Math]::Max([int]$script:ScanProcessed, [int]$message.Processed)
            }
            'Done'   { $script:ScanFinished = $true }
        }
    }

    if ($newRows.Count -gt 0) {
        Append-ResultsRows -Rows $newRows.ToArray()
    }

    if ($script:ScanTotal -gt 0 -and -not $script:ScanFinished) {
        Set-Progress $script:ScanProcessed $script:ScanTotal
        Set-Status ("Translating {0} of {1}..." -f $script:ScanProcessed, $script:ScanTotal)
    }

    if ($script:ScanFinished) { Complete-Scan }
}

$timerDrain.Add_Tick({
    try {
        Receive-WorkerMessages
    } catch {
        # Never leave the window stuck "busy" because a UI refresh threw.
        $script:Warnings.Add("UI update failed: $($_.Exception.Message)")
        if ($env:TRANSLATENAMES_SMOKE_REPORT) {
            [System.IO.File]::AppendAllText($env:TRANSLATENAMES_SMOKE_REPORT,
                ("TICK ERROR: " + $_.Exception.Message + [Environment]::NewLine + "STACK: " + $_.ScriptStackTrace + [Environment]::NewLine))
        }
        $timerDrain.Stop()
        Clear-ScanWorker -Abandon
        $script:Context = $null
        Set-BusyState -Busy $false
        Set-Status ("Scan failed: {0}" -f $_.Exception.Message)
    }
})

function Clear-Queue {
    # Empty the queue and the list. Nothing on disk is touched.
    if ($script:Context -or $script:Job) { return }
    $script:ScanRoots = @()
    $script:PreviewItems.Clear()
    Clear-ResultsView
    $script:FinalPlan = @()
    $script:PlanIndex = $null
    $script:ScanTotal = 0
    $script:ScanProcessed = 0
    $script:ScanFinished = $false
    $script:SortColumn = -1
    $txtPath.Text = ''
    $progress.Value = 0
    # Update-Counts owns the empty-state message ("No items in the queue.").
    Update-Counts
    Update-ActionState
}

function Start-Scan {
    # -ListOnly enumerates what is there and fills the list without asking the
    # provider anything, so a drop shows its contents before any request is
    # spent.
    param([switch]$ListOnly)

    # One job at a time. A second scan would replace the context the running
    # workers still publish to and leave them unreachable.
    if ($script:Context -or $script:Job) { return }
    $rootPath = $txtPath.Text.Trim().Trim('"')
    # A queued multi-selection wins over the folder box; otherwise the box is the
    # whole plan. Anything that has since disappeared is dropped silently.
    $roots = @()
    if ($script:ScanRoots.Count -gt 0) { $roots = @($script:ScanRoots) }
    elseif (-not [string]::IsNullOrWhiteSpace($rootPath)) { $roots = @($rootPath) }
    $roots = @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) })
    if ($roots.Count -eq 0) {
        if (-not $ListOnly) {
            [void](Show-Message -Text 'Pick a folder that exists before running a preview.' -Title 'No folder' -Icon 'Warning')
        }
        return
    }
    $folderRoots = @($roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })

    $protected = New-Object System.Collections.Generic.List[string]
    foreach ($folderRoot in $folderRoots) {
        $reason = Get-ProtectedRootReason -Path $folderRoot
        if ($reason) { $protected.Add(('{0} is {1}' -f $folderRoot, $reason)) }
    }
    if ($protected.Count -gt 0 -and -not $ListOnly) {
        $prompt = (($protected -join "`r`n") + "`r`n`r`nRenaming files there can break Windows or installed applications. Continue only if you really mean it.")
        if ((Show-Message -Text $prompt -Title 'System folder' -Buttons 'YesNo' -Icon 'Warning') -ne [System.Windows.Forms.DialogResult]::Yes) {
            $txtPath.Focus()
            return
        }
    }
    if (-not $chkFiles.Checked -and -not $chkFolders.Checked) {
        [void](Show-Message -Text 'Enable "Include files", "Include folders", or both.' -Title 'Nothing to scan' -Icon 'Warning')
        return
    }
    if ($txtExclude.Text) {
        try { [void][regex]::new($txtExclude.Text) }
        catch {
            [void](Show-Message -Text "That exclude pattern is not a valid regex:`r`n$($_.Exception.Message)" -Title 'Invalid regex' -Icon 'Warning')
            return
        }
    }

    $sourceCode = [string]$script:LangMap[[string]$cmbSource.SelectedItem]
    $targetCode = [string]$script:LangMap[[string]$cmbTarget.SelectedItem]
    if ($targetCode -eq 'auto') {
        [void](Show-Message -Text 'Pick a real target language. Auto-detect only makes sense as a source.' -Title 'Invalid target' -Icon 'Warning')
        return
    }
    if (-not $ListOnly -and ([string]$cmbProvider.SelectedItem) -eq 'DeepL' -and [string]::IsNullOrWhiteSpace($txtApiKey.Text)) {
        [void](Show-Message -Text 'DeepL needs an auth key. Paste one, or switch the provider back to Google.' -Title 'No API key' -Icon 'Warning')
        return
    }

    $templateIssues = @(Get-NameTemplateIssues -Template $txtTemplate.Text)
    if ($templateIssues.Count -gt 0 -and -not $ListOnly) {
        $prompt = "The name template has a problem:`r`n - " + ($templateIssues -join "`r`n - ") + "`r`n`r`nPreview will show the result. Continue?"
        if ((Show-Message -Text $prompt -Title 'Name template' -Buttons 'YesNo' -Icon 'Warning') -ne [System.Windows.Forms.DialogResult]::Yes) {
            $txtTemplate.Focus()
            return
        }
    }
    if ([string]::IsNullOrWhiteSpace($txtExcludeFolders.Text) -and -not $ListOnly) {
        # The defaults exist for a reason: removing them can make the app walk
        # into node_modules or a version-control store. Make that deliberate.
        $prompt = "Skip folders is empty, so node_modules, .git, `$RECYCLE.BIN and similar folders will be included.`r`n`r`nContinue?"
        if ((Show-Message -Text $prompt -Title 'Skip folders is empty' -Buttons 'YesNo' -Icon 'Warning') -ne [System.Windows.Forms.DialogResult]::Yes) {
            $txtExcludeFolders.Focus()
            return
        }
    }

    if (-not $ListOnly) {
        Save-CurrentSettings
        $script:Glossary = Import-Glossary
        # The cache is only needed from here on, not to draw the window.
        Initialize-TranslationCache
    }

    $anchor = if ($folderRoots.Count -gt 0) { [string]$folderRoots[0] } else { Split-Path -Parent ([string]$roots[0]) }
    if (-not $anchor) { $anchor = [string]$roots[0] }
    $script:ScanRoot = ([System.IO.Path]::GetFullPath($anchor)).TrimEnd('\', '/')
    # Location is only meaningfully "relative to the root" when there is exactly
    # one folder; with a mixed queue every row shows its own parent path.
    $script:ScanMultiRoot = ($roots.Count -gt 1 -or $folderRoots.Count -eq 0)
    $script:ScanRoots     = $roots
    $script:PreviewItems.Clear()
    Clear-ResultsView
    $script:Warnings.Clear()
    $script:ScanTotal = 0
    $script:ScanProcessed = 0
    $script:ScanFinished = $false
    $script:SortColumn = -1
    $script:FinalPlan = @()
    $script:PlanIndex = $null
    $tooltip.SetToolTip($lblStatus, '')
    $progress.Value = 0

    $skipExtensions = @(
        $txtSkipExt.Text -split '[,;\s]+' |
            Where-Object { $_ } |
            ForEach-Object { $_.Trim().TrimStart('.').ToLowerInvariant() }
    )
    $excludeFolders = @(
        $txtExcludeFolders.Text -split ';' |
            Where-Object { $_ } |
            ForEach-Object { $_.Trim() }
    )

    $script:Context = [hashtable]::Synchronized(@{
        Roots            = $roots
        ListOnly         = [bool]$ListOnly
        MultiRoot        = [bool]$script:ScanMultiRoot
        Recurse          = [bool]$chkRecurse.Checked
        IncludeFiles     = [bool]$chkFiles.Checked
        IncludeFolders   = [bool]$chkFolders.Checked
        IncludeHidden    = [bool]$chkHidden.Checked
        SkipIfTargetLang = [bool]$chkSkipTarget.Checked
        ExcludePattern   = [string]$txtExclude.Text
        ExcludeFolders   = $excludeFolders
        SkipExtensions   = $skipExtensions
        MaxDepth         = [int]$numDepth.Value
        Template         = [string]$txtTemplate.Text
        CaseMode         = [string]$cmbCase.SelectedItem
        MaxNameLength    = [int]$numMaxLen.Value
        DelayMs          = [int]$numDelay.Value
        Provider         = [string]$cmbProvider.SelectedItem
        ApiKey           = [string]$txtApiKey.Text
        From             = $sourceCode
        To               = $targetCode
        Cache            = $script:Cache
        HelperSource     = $script:HelperSource
        Queue            = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        Cancel           = $false
        Done             = $false
        FatalError       = $null
        Total            = 0
        ProtectTags      = [bool]$chkProtect.Checked
        Transliteration  = [string]$cmbTranslit.SelectedItem
        Glossary         = @($script:Glossary)
        NoNetwork        = $false
        ConsecutiveFailures = 0
        Lock             = (New-Object object)
        Processed        = 0
        WorkersRemaining = 0
        ParallelRequests = [int]$numParallel.Value
        NextRequestAt    = [DateTime]::MinValue
        ThrottleCount    = 0
        ThrottleUntil    = [DateTime]::MinValue
        ThrottleWindowStart = $null
        SuccessSinceThrottle = 0
        LastThrottleReason = ''
    })

    $parallelCount = [Math]::Max(1, [Math]::Min(3, [int]$numParallel.Value))
    $script:Workers = @()
    $script:Context.WorkersRemaining = $parallelCount
    try {
        for ($workerIndex = 0; $workerIndex -lt $parallelCount; $workerIndex++) {
            $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            $workerRunspace = [runspacefactory]::CreateRunspace($sessionState)
            try { $workerRunspace.ApartmentState = 'MTA' } catch { }
            try { $workerRunspace.ThreadOptions = 'ReuseThread' } catch { }
            $workerRunspace.Open()

            $workerPowerShell = [powershell]::Create()
            $workerPowerShell.Runspace = $workerRunspace
            [void]$workerPowerShell.AddScript($script:ScanWorker.ToString()).AddArgument($script:Context).AddArgument($workerIndex).AddArgument($parallelCount)
            $workerHandle = $workerPowerShell.BeginInvoke()
            $script:Workers += [pscustomobject]@{
                PowerShell = $workerPowerShell
                Runspace   = $workerRunspace
                Handle     = $workerHandle
            }
        }
    } catch {
        if ($script:Context) { $script:Context.Cancel = $true }
        Clear-ScanWorker
        $script:Context = $null
        [void](Show-Message -Text "Could not start the background worker:`r`n$($_.Exception.Message)" -Title 'Startup failed' -Icon 'Error')
        return
    }

    Set-BusyState -Busy $true -Activity 'Scan'
    Set-Status 'Scanning folder...'
    $timerDrain.Start()
}

#endregion

#region ---------------------------------------------------------- Apply and undo jobs

# Keep every queued row's absolute path correct after an ancestor folder moves.
function Update-PathsUnder {
    param([string]$OldPath, [string]$NewPath)
    if ([string]::IsNullOrEmpty($OldPath) -or [string]::IsNullOrEmpty($NewPath)) { return }
    $prefix = $OldPath.TrimEnd('\', '/') + '\'
    foreach ($row in $script:PreviewItems) {
        $current = [string]$row.Tag.FullPath
        if ($current.Length -le $prefix.Length) { continue }
        if (-not $current.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $suffix = $current.Substring($prefix.Length)
        $row.Tag.FullPath = Join-Path $NewPath $suffix
        $parent = [System.IO.Path]::GetDirectoryName($row.Tag.FullPath)
        $relative = if ($script:ScanMultiRoot) {
            Get-ShortFolderPath -Path $parent
        } else {
            $root = if ($row.Tag.Root) { [string]$row.Tag.Root } else { $script:ScanRoot }
            ConvertTo-RelativePath -Path $parent -Root $root
        }
        if ([string]::IsNullOrEmpty($relative)) { $relative = '.' }
        if ($row.SubItems.Count -gt 2) { $row.SubItems[2].Text = $relative }
    }
}

function Complete-Job {
    $job = $script:Job
    $timerJob.Stop()
    $script:Job = $null
    if (-not $job) { return }

    if ($job.Kind -eq 'Apply') {
        if ($chkCsv.Checked -and $job.Log.Count -gt 0) {
            try {
                Initialize-DataDir
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $logPath = Join-Path $script:DataDir "rename-log-$stamp.csv"
                $job.Log | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8
                $job.LogPath = $logPath
            } catch {
                $script:Warnings.Add("Could not write the CSV log: $($_.Exception.Message)")
            }
        }
        $summary = "Renamed {0} item(s)" -f $job.Renamed
        if ($job.Skipped -gt 0) { $summary += ", {0} skipped" -f $job.Skipped }
        if ($job.Failed -gt 0)  { $summary += ", {0} failed" -f $job.Failed }
        if ($job.Cancel)        { $summary += " (cancelled)" }
        if ($job.LogPath)       { $summary += ". Log: $($job.LogPath)" }
        Set-Status $summary

        Refresh-UndoState
        # Re-attach the in-memory rows so Undo can repaint them without a rescan.
        if ($job.Journal.Count -gt 0) {
            $byId = @{}
            foreach ($entry in $job.Journal) { $byId[$entry.Id] = $entry }
            foreach ($entry in $script:UndoJournal) {
                if ($byId.ContainsKey($entry.Id)) { $entry.Row = $byId[$entry.Id].Row }
            }
        }
    } else {
        Compress-Journal
        Refresh-UndoState
        $summary = "Reverted {0} of {1} rename(s)" -f $job.Renamed, $job.Items.Count
        if ($job.Failed -gt 0) { $summary += ", {0} could not be reverted" -f $job.Failed }
        if ($script:UndoBatches.Count -gt 0) {
            $summary += ". {0} older batch(es) still undoable." -f $script:UndoBatches.Count
        }
        Set-Status $summary
    }

    # Keep the data folder on the Archil disk, so the journal and settings this
    # job just wrote are there on the next run (and on another machine).
    $archilNote = Sync-ArchilSnapshot -Action Push
    if ($archilNote) { Set-Status ("{0}. {1}" -f $summary, $archilNote) }

    Update-FinalPlan
    Set-Progress 1 1
    Set-BusyState -Busy $false
    $lvResults.Invalidate()
    Update-Counts
}

function Invoke-ApplyStep {
    param($Job)

    $entry = $Job.Items[$Job.Index]
    $row   = $entry.Row.ListRow
    $source = [string]$row.Tag.FullPath

    if (-not (Test-Path -LiteralPath $source)) {
        $Job.Failed++
        Set-RowState -Row $row -State 'Missing' -Detail 'Missing'
        $Job.Log.Add([pscustomobject]@{ Type = 'Item'; Directory = ''; OriginalName = [System.IO.Path]::GetFileName($source); NewName = ''; Status = 'Failed: missing' })
        return
    }

    if (-not $entry.Target) {
        $Job.Skipped++
        Set-RowState -Row $row -State 'Conflict' -Detail 'Skipped: name in use'
        return
    }

    $target = [string]$entry.Target
    $sourceDir = [System.IO.Path]::GetDirectoryName($source)
    if ([System.IO.Path]::GetDirectoryName($target) -ine $sourceDir) {
        $target = Join-Path $sourceDir ([System.IO.Path]::GetFileName($target))
    }

    if ([string]::Equals($target, $source, [StringComparison]::Ordinal)) {
        Set-RowState -Row $row -State 'Unchanged'
        $row.Tag.BaseState = 'Unchanged'
        return
    }

    $originalLeaf = [System.IO.Path]::GetFileName($source)
    $finalLeaf    = [System.IO.Path]::GetFileName($target)

    # Journal first, then move: see Invoke-PlannedRename.
    $result = Invoke-PlannedRename -SourcePath $source -TargetPath $target -IsContainer ([bool]$entry.IsContainer) -BatchId $Job.BatchId

    if (-not $result.Ok) {
        Set-RowState -Row $row -State 'Error' -Detail 'Error'
        $Job.Failed++
        $script:Warnings.Add("$originalLeaf -> $finalLeaf : $($result.Error)")
        $Job.Log.Add([pscustomobject]@{
            Type         = if ($entry.IsContainer) { 'Folder' } else { 'File' }
            Directory    = $sourceDir
            OriginalName = $originalLeaf
            NewName      = $finalLeaf
            Status       = "Failed: $($result.Error)"
        })
        return
    }

    $row.SubItems[4].Text = $finalLeaf
    if ($row.SubItems.Count -gt 6) { $row.SubItems[6].Text = $finalLeaf }
    $tag = $row.Tag
    $tag.NewName  = $finalLeaf
    $tag.FullPath = $target
    Set-RowState -Row $row -State 'Renamed'
    if ($entry.IsContainer) { Update-PathsUnder -OldPath $source -NewPath $target }

    $journalEntry = [pscustomobject]@{
        Id           = $result.Id
        BatchId      = $Job.BatchId
        Directory    = $sourceDir
        OriginalLeaf = $originalLeaf
        NewLeaf      = $finalLeaf
        IsContainer  = [bool]$entry.IsContainer
        Timestamp    = $result.Timestamp
        Row          = $row
    }
    $script:UndoJournal.Add($journalEntry)
    $Job.Journal.Add($journalEntry)
    $Job.Renamed++

    $Job.Log.Add([pscustomobject]@{
        Type         = if ($entry.IsContainer) { 'Folder' } else { 'File' }
        Directory    = $sourceDir
        OriginalName = $originalLeaf
        NewName      = $finalLeaf
        Status       = 'Renamed'
    })
}

function Invoke-UndoStep {
    param($Job)

    $entry = $Job.Items[$Job.Index]
    $currentPath  = Join-Path $entry.Directory $entry.NewLeaf
    $restoredPath = Join-Path $entry.Directory $entry.OriginalLeaf

    $result = Invoke-PlannedUndo -Entry $entry
    if (-not $result.Ok) {
        if ($result.Error -like 'Missing*') {
            if ($entry.Row) { Set-RowState -Row $entry.Row -State 'Missing' -Detail 'Undo: missing' }
        } else {
            if ($entry.Row) { Set-RowState -Row $entry.Row -State 'Error' -Detail 'Undo failed' }
            $script:Warnings.Add("Undo $($entry.NewLeaf) -> $($entry.OriginalLeaf) : $($result.Error)")
        }
        $Job.Failed++
        return
    }

    $Job.Renamed++
    if ($entry.Row) {
        $tag = $entry.Row.Tag
        $tag.FullPath = $restoredPath
        $entry.Row.SubItems[4].Text = $tag.Translated
        $tag.NewName = $tag.Translated
        if ($entry.Row.SubItems.Count -gt 6) { $entry.Row.SubItems[6].Text = '' }
        Set-RowState -Row $entry.Row -State $tag.BaseState
    }
    if ($entry.IsContainer) { Update-PathsUnder -OldPath $currentPath -NewPath $restoredPath }
}

$timerJob.Add_Tick({
    $job = $script:Job
    if (-not $job) { $timerJob.Stop(); return }

    $budget = 40
    while ($budget -gt 0 -and $job.Index -lt $job.Items.Count -and -not $job.Cancel) {
        if ($job.Kind -eq 'Apply') { Invoke-ApplyStep -Job $job } else { Invoke-UndoStep -Job $job }
        $job.Index++
        $budget--
    }

    Set-Progress $job.Index $job.Items.Count
    Set-Status ("{0} {1} of {2}..." -f $job.Verb, $job.Index, $job.Items.Count)

    if ($job.Cancel -or $job.Index -ge $job.Items.Count) { Complete-Job }
})

function Start-ApplyJob {
    if ($script:Context -or $script:Job) { return }
    Update-FinalPlan
    $plan = @($script:FinalPlan)
    if ($plan.Count -eq 0) {
        [void](Show-Message -Text 'Nothing in the queue needs renaming.' -Title 'Nothing to do' -Icon 'Information')
        return
    }

    $applyable = @($plan | Where-Object { -not $_.IsBlocked })
    $blocked   = @($plan | Where-Object { $_.IsBlocked })
    $suffixed  = @($plan | Where-Object { $_.Note -eq 'Collision resolved with suffix' })

    if ($applyable.Count -eq 0) {
        [void](Show-Message -Text "All $($plan.Count) item(s) collide with a name already on disk. Re-enable auto-suffix or edit the names." -Title 'Nothing to do' -Icon 'Warning')
        return
    }

    $prompt = "Rename $($applyable.Count) item(s)?"
    if ($suffixed.Count -gt 0) {
        $prompt += "`r`n`r`n$($suffixed.Count) name collision(s) will get a numeric suffix (see Final target)."
    }
    if ($blocked.Count -gt 0) {
        $prompt += "`r`n`r`n$($blocked.Count) item(s) will be SKIPPED because auto-suffix is off and the name is in use."
    }
    $prompt += "`r`n`r`nEvery rename is journalled before it happens and can be undone."

    if ((Show-Message -Text $prompt -Title 'Confirm renames' -Buttons 'YesNo' -Icon 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    $script:Warnings.Clear()
    $progress.Value = 0

    $script:Job = @{
        Kind    = 'Apply'
        Verb    = 'Renaming'
        Items   = $applyable
        Index   = 0
        Renamed = 0
        Failed  = 0
        Skipped = 0
        Cancel  = $false
        BatchId = [guid]::NewGuid().ToString('N')
        Log     = (New-Object System.Collections.Generic.List[object])
        Journal = (New-Object System.Collections.Generic.List[object])
        LogPath = $null
    }

    Set-BusyState -Busy $true -Activity 'Apply'
    $timerJob.Start()
}

function Start-UndoJob {
    if ($script:Context -or $script:Job) { return }
    if ($script:UndoJournal.Count -eq 0) { return }

    $prompt = "Undo the last $($script:UndoJournal.Count) rename(s)?"
    if ((Show-Message -Text $prompt -Title 'Confirm undo' -Buttons 'YesNo' -Icon 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    # Reverse order: newest rename first, so nested paths resolve correctly.
    $ordered = New-Object System.Collections.Generic.List[object]
    for ($i = $script:UndoJournal.Count - 1; $i -ge 0; $i--) { $ordered.Add($script:UndoJournal[$i]) }

    $progress.Value = 0
    $script:Job = @{
        Kind    = 'Undo'
        Verb    = 'Reverting'
        Items   = $ordered
        Index   = 0
        Renamed = 0
        Failed  = 0
        Skipped = 0
        Cancel  = $false
        BatchId = ''
        Log     = (New-Object System.Collections.Generic.List[object])
        Journal = (New-Object System.Collections.Generic.List[object])
        LogPath = $null
    }

    Set-BusyState -Busy $true -Activity 'Undo'
    $timerJob.Start()
}

#endregion

#region ---------------------------------------------------------- Settings capture

function Get-CurrentSettings {
    $columnWidths = @()
    if ($lvResults) { $columnWidths = @($lvResults.Columns | ForEach-Object { [int]$_.Width }) }
    return @{
        SourceLanguage   = [string]$cmbSource.SelectedItem
        TargetLanguage   = [string]$cmbTarget.SelectedItem
        Provider         = [string]$cmbProvider.SelectedItem
        CaseMode         = [string]$cmbCase.SelectedItem
        Template         = [string]$txtTemplate.Text
        ExcludePattern   = [string]$txtExclude.Text
        SkipExtensions   = [string]$txtSkipExt.Text
        DelayMs          = [int]$numDelay.Value
        MaxNameLength    = [int]$numMaxLen.Value
        MaxDepth         = [int]$numDepth.Value
        ParallelRequests = [int]$numParallel.Value
        IncludeFiles     = [bool]$chkFiles.Checked
        IncludeFolders   = [bool]$chkFolders.Checked
        Recurse          = [bool]$chkRecurse.Checked
        IncludeHidden    = [bool]$chkHidden.Checked
        SkipIfTargetLang = [bool]$chkSkipTarget.Checked
        HideUnchanged    = [bool]$chkHide.Checked
        UiMode           = [string]$script:UserMode
        WriteCsvLog      = [bool]$chkCsv.Checked
        ProtectTags      = [bool]$chkProtect.Checked
        AutoSuffix       = [bool]$chkAutoSuffix.Checked
        Transliteration  = [string]$cmbTranslit.SelectedItem
        ExcludeFolders   = [string]$txtExcludeFolders.Text
        LastFolder       = [string]$txtPath.Text
        RecentFolders    = @($script:RecentFolders)
        ColumnWidths     = $columnWidths
        WindowWidth      = [int]$form.ClientSize.Width
        WindowHeight     = [int]$form.ClientSize.Height
    }
}

function Save-CurrentSettings {
    # The API key is deliberately not persisted.
    Export-Settings -Settings (Get-CurrentSettings)
}

# --- settings import/export, recent folders, columns, diagnostics ----------

function ConvertTo-SettingsHashtable {
    param($Raw)
    $settings = @{}
    foreach ($key in $script:DefaultSettings.Keys) { $settings[$key] = $script:DefaultSettings[$key] }
    if ($Raw) {
        foreach ($property in $Raw.PSObject.Properties) {
            if ($settings.ContainsKey($property.Name) -and $null -ne $property.Value) {
                $settings[$property.Name] = $property.Value
            }
        }
    }
    return $settings
}

function Set-ComboValue {
    param($Combo, [string]$Value)
    if (-not $Combo -or [string]::IsNullOrEmpty($Value)) { return }
    for ($i = 0; $i -lt $Combo.Items.Count; $i++) {
        if ([string]$Combo.Items[$i] -ieq $Value) { $Combo.SelectedIndex = $i; return }
    }
}

function Apply-ColumnWidths {
    param($Widths)
    $values = @($Widths)
    if (-not $lvResults -or $values.Count -ne $lvResults.Columns.Count) { return }
    for ($i = 0; $i -lt $values.Count; $i++) {
        $width = [int]$values[$i]
        if ($width -ge (Scale-Px 30)) { $lvResults.Columns[$i].Width = $width }
    }
}

function Update-RecentCombo {
    if (-not $txtPath -or -not ($txtPath -is [System.Windows.Forms.ComboBox])) { return }
    $script:PathComboUpdating = $true
    try {
        $current = [string]$txtPath.Text
        $txtPath.Items.Clear()
        foreach ($entry in @($script:RecentFolders)) {
            if ($entry) { [void]$txtPath.Items.Add([string]$entry) }
        }
        $txtPath.Text = $current
    } finally {
        $script:PathComboUpdating = $false
    }
}

function Add-RecentFolder {
    param([string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder)) { return }
    try { $full = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/') } catch { return }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return }
    $list = @($script:RecentFolders | Where-Object { $_ -and ($_ -ine $full) })
    $script:RecentFolders = @(@($full) + $list | Select-Object -First 8)
    Update-RecentCombo
}

function Apply-SettingsToControls {
    param($Settings)
    if (-not $Settings) { return }
    Set-ComboValue $cmbProvider ([string]$Settings.Provider)
    Set-ComboValue $cmbSource ([string]$Settings.SourceLanguage)
    Set-ComboValue $cmbTarget ([string]$Settings.TargetLanguage)
    Set-ComboValue $cmbCase ([string]$Settings.CaseMode)
    Set-ComboValue $cmbTranslit ([string]$Settings.Transliteration)

    $txtTemplate.Text        = [string]$Settings.Template
    $txtExclude.Text         = [string]$Settings.ExcludePattern
    $txtSkipExt.Text         = [string]$Settings.SkipExtensions
    $txtExcludeFolders.Text  = [string]$Settings.ExcludeFolders

    $numDelay.Value  = [decimal][Math]::Max([int]$numDelay.Minimum,  [Math]::Min([int]$numDelay.Maximum,  [int]$Settings.DelayMs))
    $numMaxLen.Value = [decimal][Math]::Max([int]$numMaxLen.Minimum, [Math]::Min([int]$numMaxLen.Maximum, [int]$Settings.MaxNameLength))
    $numDepth.Value  = [decimal][Math]::Max([int]$numDepth.Minimum,  [Math]::Min([int]$numDepth.Maximum,  [int]$Settings.MaxDepth))
    $numParallel.Value = [decimal][Math]::Max([int]$numParallel.Minimum, [Math]::Min([int]$numParallel.Maximum, [int]$Settings.ParallelRequests))

    $chkFiles.Checked      = [bool]$Settings.IncludeFiles
    $chkFolders.Checked    = [bool]$Settings.IncludeFolders
    $chkRecurse.Checked    = [bool]$Settings.Recurse
    $chkHidden.Checked     = [bool]$Settings.IncludeHidden
    $chkSkipTarget.Checked = [bool]$Settings.SkipIfTargetLang
    $chkHide.Checked       = [bool]$Settings.HideUnchanged
    $chkCsv.Checked        = [bool]$Settings.WriteCsvLog
    $chkProtect.Checked    = [bool]$Settings.ProtectTags
    $chkAutoSuffix.Checked = [bool]$Settings.AutoSuffix

    $script:RecentFolders = @(@($Settings.RecentFolders) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -First 8)
    Update-RecentCombo
    Apply-ColumnWidths $Settings.ColumnWidths
    Set-UiMode -Mode ([string]$Settings.UiMode)
}

function Export-SettingsFile {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $dialog.Filter   = 'Settings JSON (*.json)|*.json'
        $dialog.FileName = 'translate-names-settings.json'
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $json = (Get-CurrentSettings | ConvertTo-Json -Depth 5)
        [System.IO.File]::WriteAllText($dialog.FileName, $json, (New-Object System.Text.UTF8Encoding($false)))
        Set-Status ("Settings exported to {0}" -f $dialog.FileName)
    } catch {
        [void](Show-Message -Text "Could not export settings:`r`n$($_.Exception.Message)" -Title 'Export settings' -Icon 'Warning')
    } finally {
        $dialog.Dispose()
    }
}

function Import-SettingsFile {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Filter = 'Settings JSON (*.json)|*.json|All files (*.*)|*.*'
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
        $raw = Get-Content -LiteralPath $dialog.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $raw) { throw 'The file does not contain a settings object.' }
        $merged = ConvertTo-SettingsHashtable $raw
        $answer = Show-Message -Text ("Apply settings from:`r`n{0}`r`n`r`nThe current options will be replaced." -f $dialog.FileName) -Title 'Import settings' -Buttons 'YesNo' -Icon 'Question'
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
        Apply-SettingsToControls $merged
        Save-CurrentSettings
        Update-ResultsView
        Set-Status ("Settings imported from {0}" -f $dialog.FileName)
        return $true
    } catch {
        [void](Show-Message -Text "Could not import settings:`r`n$($_.Exception.Message)" -Title 'Import settings' -Icon 'Warning')
        return $false
    } finally {
        $dialog.Dispose()
    }
}

function Reset-AllSettings {
    $answer = Show-Message -Text "Reset every option to its default value?`r`n`r`nThe undo journal, cache and glossary are not touched." -Title 'Reset settings' -Buttons 'YesNo' -Icon 'Question'
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
    Apply-SettingsToControls $script:DefaultSettings
    Save-CurrentSettings
    Update-ResultsView
    Set-Status 'All options reset to defaults.'
    return $true
}

function Get-DiagnosticsText {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Translate Names diagnostics')
    $lines.Add('==========================')
    $lines.Add('Version: ' + $script:AppVersion)
    $lines.Add('PowerShell: ' + $PSVersionTable.PSVersion.ToString() + ' (' + $PSVersionTable.PSEdition + ')')
    $lines.Add('OS: ' + [System.Environment]::OSVersion.VersionString)
    $lines.Add('Display scale: ' + $script:DpiScale + 'x')
    $lines.Add('Data folder: ' + $script:DataDir)
    $lines.Add('Settings: ' + $script:SettingsPath)
    $lines.Add('Cache: ' + $script:CachePath)
    $lines.Add('Glossary: ' + $script:GlossaryPath)
    $lines.Add('Journal: ' + $script:JournalPath)
    $lines.Add('')
    $lines.Add('Folder: ' + [string]$txtPath.Text)
    $lines.Add('Provider/target: ' + [string]$cmbProvider.SelectedItem + ' / ' + [string]$cmbSource.SelectedItem + ' -> ' + [string]$cmbTarget.SelectedItem)
    $lines.Add('Template: ' + [string]$txtTemplate.Text)
    $lines.Add('Skip folders: ' + [string]$txtExcludeFolders.Text)
    $lines.Add('Exclude regex: ' + [string]$txtExclude.Text)
    $lines.Add('Skip extensions: ' + [string]$txtSkipExt.Text)
    $lines.Add('Depth: ' + [string]$numDepth.Value + '   Delay: ' + [string]$numDelay.Value + '   Parallel: ' + [string]$numParallel.Value)
    $lines.Add('Protect tags: ' + [bool]$chkProtect.Checked + '   Auto suffix: ' + [bool]$chkAutoSuffix.Checked)
    $lines.Add('Transliteration: ' + [string]$cmbTranslit.SelectedItem)
    $lines.Add('')
    $lines.Add('Preview rows: ' + $script:PreviewItems.Count)
    $lines.Add('Glossary terms: ' + @($script:Glossary).Count)
    $lines.Add('Undo batches pending: ' + @($script:UndoBatches).Count)
    $lines.Add('Warnings: ' + $script:Warnings.Count)
    if ($script:Warnings.Count -gt 0) {
        foreach ($warning in @($script:Warnings | Select-Object -Last 15)) {
            $lines.Add('  - ' + [string]$warning)
        }
    }
    return ($lines -join "`r`n")
}

function Set-ClipboardText {
    # Windows refuses a clipboard write while another process holds it open
    # ("Requested Clipboard operation did not succeed"). Retrying a few times
    # with a short backoff is the standard fix.
    param([string]$Text, [int]$Attempts = 6)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return $true
        } catch {
            if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds (40 * $attempt) }
        }
    }
    try {
        $data = New-Object System.Windows.Forms.DataObject
        $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Text)
        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true)
        return $true
    } catch { }
    return $false
}

function Copy-Diagnostics {
    $text = Get-DiagnosticsText
    if (Set-ClipboardText -Text $text) {
        Set-Status 'Diagnostics copied to the clipboard.'
        return $true
    }
    # Last resort: never lose the information just because the clipboard is busy.
    $fallback = Join-Path ([System.IO.Path]::GetTempPath()) 'translate-names-diagnostics.txt'
    try {
        [System.IO.File]::WriteAllText($fallback, $text, (New-Object System.Text.UTF8Encoding($false)))
        Set-Status ("Clipboard busy; diagnostics saved to {0}" -f $fallback)
        [void](Show-Message -Text ("The clipboard is busy, so the diagnostics were saved to:`r`n{0}`r`n`r`nYou can open that file and copy from it." -f $fallback) -Title 'Diagnostics' -Icon 'Information')
    } catch {
        [void](Show-Message -Text "Could not copy diagnostics and could not write the fallback file." -Title 'Diagnostics' -Icon 'Warning')
    }
    return $false
}

function Get-ProtectedRootReason {
    param([string]$Path)
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return '' }
    if ($full -match '^[A-Za-z]:$') { return 'a drive root' }
    $roots = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:windir)
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $clean = $root.TrimEnd('\', '/')
        if ($full -ieq $clean -or $full.StartsWith($clean + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return ('inside ' + $clean)
        }
    }
    return ''
}


#endregion

#region ---------------------------------------------------------- Row actions

# --- In-place editing of the "New name" column ------------------------------
# LabelEdit is unavailable in virtual mode (there are no items to edit), so the
# editor is a TextBox floated over the cell. Enter and Tab commit and step down
# the list, Shift+Tab steps up, Esc abandons the edit. Reviewing fifty rows is
# one pass instead of fifty dialogs.

$script:CellEditRow = $null

# A single edit usually changes nothing else: the new name is free, the row was
# already in the plan and stays in it. That case is a dictionary lookup plus one
# disk check instead of re-planning the whole queue, which costs seconds at
# 20 000 rows and is what every Enter in the inline editor used to pay.
function Update-SingleRowPlan {
    param([System.Windows.Forms.ListViewItem]$Row, [string]$Name)

    if (-not $script:PlanIndex -or $script:PlanIndex.Count -eq 0) { return $false }
    if ($Row.Tag.BaseState -eq 'Unchanged' -or $Row.Tag.State -eq 'Renamed') { return $false }

    $entry = $null
    foreach ($candidate in $script:FinalPlan) {
        if ([object]::ReferenceEquals($candidate.Row.ListRow, $Row)) { $entry = $candidate; break }
    }
    if (-not $entry) { return $false }

    $parent = [System.IO.Path]::GetDirectoryName([string]$Row.Tag.FullPath)
    if ([string]::IsNullOrEmpty($parent)) { return $false }
    $target = $parent + '\' + $Name

    # Taken by another row, or still on disk (which also covers chains, where a
    # queued row has not vacated its old name yet): let the planner decide.
    $owner = $null
    if ($script:PlanIndex.TryGetValue($target, [ref]$owner) -and -not [object]::ReferenceEquals($owner, $entry)) { return $false }
    if (Test-PathExists $target) { return $false }

    $oldTarget = [string]$entry.Target
    $entry.Target    = $target
    $entry.FinalLeaf = $Name
    if ($oldTarget -and $script:PlanIndex.ContainsKey($oldTarget)) { [void]$script:PlanIndex.Remove($oldTarget) }
    $script:PlanIndex[$target] = $entry

    if ($Row.SubItems.Count -gt 6) { $Row.SubItems[6].Text = $Name }
    return $true
}

function Apply-RowNewName {
    param([System.Windows.Forms.ListViewItem]$Row, [string]$Name)
    $tag = $Row.Tag
    $tag.NewName = $Name
    $Row.SubItems[4].Text = $Name
    $tag.BaseState = if ($Name -ceq $tag.OriginalName) { 'Unchanged' } else { 'Edited' }
    Set-RowState -Row $Row -State $tag.BaseState

    if (-not (Update-SingleRowPlan -Row $Row -Name $Name)) { Update-FinalPlan }
    Update-Counts
    Update-ActionState
    $lvResults.Invalidate()
}

# Client-area bounds of the cell the editor has to cover. Falls back to the item
# rectangle plus the widths of the columns before it where the native call is
# unavailable.
function Get-CellEditBounds {
    param([System.Windows.Forms.ListViewItem]$Row)
    $index = -1
    try { $index = $script:ViewRows.IndexOf($Row) } catch { }
    if ($index -lt 0) { return [System.Drawing.Rectangle]::Empty }

    $bounds = [System.Drawing.Rectangle]::Empty
    if ($script:InteropReady) {
        try { $bounds = [TranslateNames.Native]::GetCellBounds($lvResults, $index, 4) } catch { }
    }
    if ($bounds.Width -le 0 -or $bounds.Height -le 0) {
        $item = $lvResults.GetItemRect($index)
        if ($item.Width -le 0) { return [System.Drawing.Rectangle]::Empty }
        $left = $item.Left
        for ($column = 0; $column -lt 4 -and $column -lt $lvResults.Columns.Count; $column++) {
            $left += $lvResults.Columns[$column].Width
        }
        $width = if ($lvResults.Columns.Count -gt 4) { $lvResults.Columns[4].Width } else { (Scale-Px 210) }
        $bounds = New-Object System.Drawing.Rectangle($left, $item.Top, $width, $item.Height)
    }
    return $bounds
}

# Which visible row is under a client point. HitTest cannot be trusted in
# virtual mode, and row heights are uniform, so walk down from the top row.
function Get-RowAtPoint {
    param([System.Drawing.Point]$Point)
    if ($script:ViewRows.Count -eq 0) { return $null }
    $index = 0
    try { if ($lvResults.TopItem) { $index = [int]$lvResults.TopItem.Index } } catch { }
    $index = [Math]::Max(0, [Math]::Min($index, $script:ViewRows.Count - 1))

    $guard = 0
    while ($index -lt $script:ViewRows.Count -and $guard -lt 400) {
        $guard++
        $rect = $lvResults.GetItemRect($index)
        if ($rect.Height -le 0) { $index++; continue }
        if ($Point.Y -lt $rect.Top) { return $null }
        if ($Point.Y -lt $rect.Bottom) {
            return [pscustomobject]@{ Row = $script:ViewRows[$index]; Index = $index; Bounds = $rect }
        }
        $index++
    }
    return $null
}

function Start-CellEdit {
    param([System.Windows.Forms.ListViewItem]$Row)

    if (-not $Row) { return }
    if ($script:Job) {
        Set-Status 'A rename job is running; editing is paused until it finishes.'
        return
    }
    if ($script:Context) {
        Set-Status 'Wait for the preview to finish before editing names.'
        return
    }
    if ($Row.Tag.State -eq 'Renamed') {
        Set-Status 'That item has already been renamed. Undo first to change it.'
        return
    }
    if ($txtCellEdit.Visible) { Complete-CellEdit }

    $index = $script:ViewRows.IndexOf($Row)
    if ($index -lt 0) { return }
    try {
        $lvResults.EnsureVisible($index)
        $lvResults.SelectedIndices.Clear()
        [void]$lvResults.SelectedIndices.Add($index)
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }

    $bounds = Get-CellEditBounds -Row $Row
    if ($bounds.Width -le 4 -or $bounds.Height -le 0) { return }
    $corner = $lvResults.PointToScreen((New-Object System.Drawing.Point($bounds.X, $bounds.Y)))
    $origin = $form.PointToClient($corner)

    $value = [string]$Row.Tag.NewName
    $txtCellEdit.Bounds = New-Object System.Drawing.Rectangle($origin.X, $origin.Y, $bounds.Width, $bounds.Height)
    $txtCellEdit.Text   = $value
    $script:CellEditRow = $Row
    $txtCellEdit.Visible = $true
    $txtCellEdit.BringToFront()
    [void]$txtCellEdit.Focus()

    # Preselect the name but not the extension: that is the part people change.
    $extension = [System.IO.Path]::GetExtension($value)
    $selectLength = if ($extension -and $extension.Length -lt $value.Length) { $value.Length - $extension.Length } else { $value.Length }
    $txtCellEdit.Select(0, [Math]::Max(0, $selectLength))
}

function Complete-CellEdit {
    param([switch]$Cancel, [int]$Advance = 0)

    $row = $script:CellEditRow
    $script:CellEditRow = $null
    $text = [string]$txtCellEdit.Text
    try { $txtCellEdit.Visible = $false } catch { }
    if (-not $row) { return }

    if (-not $Cancel) {
        $trimmed = $text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $safe = Get-SafeFileName -Name $trimmed -MaxLength 240
            if ([string]::IsNullOrWhiteSpace($safe)) {
                Set-Status 'That name is empty once invalid characters are removed.'
            } elseif ($safe -cne [string]$row.Tag.NewName) {
                Apply-RowNewName -Row $row -Name $safe
                if ($safe -cne $trimmed) { Set-Status ("Name adjusted to what Windows accepts: " + $safe) }
            }
        }
    }

    if ($Advance -ne 0) {
        $index = $script:ViewRows.IndexOf($row)
        $next = $index + $Advance
        if ($index -ge 0 -and $next -ge 0 -and $next -lt $script:ViewRows.Count) {
            Start-CellEdit -Row $script:ViewRows[$next]
            return
        }
    }
    try { [void]$lvResults.Focus() } catch { }
}

function Edit-SelectedRow {
    if ($script:Job) {
        Set-Status 'A rename job is running; editing is paused until it finishes.'
        return
    }
    $selected = @(Get-SelectedRows)
    if ($selected.Count -ne 1) { return }
    Start-CellEdit -Row $selected[0]
}

function Reset-SelectedRows {
    if ($script:Job) {
        Set-Status 'A rename job is running; editing is paused until it finishes.'
        return
    }
    $selected = @(Get-SelectedRows)
    if ($selected.Count -eq 0) { return }
    foreach ($row in $selected) {
        $tag = $row.Tag
        if ($tag.State -eq 'Renamed') { continue }
        $tag.NewName   = $tag.Translated
        $tag.BaseState = $tag.InitialState
        $row.SubItems[4].Text = $tag.Translated
        Set-RowState -Row $row -State $tag.BaseState
    }
    Update-FinalPlan
    Update-Counts
    Update-ActionState
    $lvResults.Invalidate()
}

function Remove-SelectedRows {
    if ($script:Job) {
        Set-Status 'A rename job is running; editing is paused until it finishes.'
        return
    }
    $selected = @(Get-SelectedRows)
    if ($selected.Count -eq 0) { return }
    foreach ($row in $selected) { [void]$script:PreviewItems.Remove($row) }
    Update-ResultsView
    Update-FinalPlan
    Update-Counts
    Update-ActionState
}

function Copy-SelectedRows {
    $selected = @(Get-SelectedRows)
    if ($selected.Count -eq 0) { return }
    $lines = foreach ($row in $selected) {
        ($row.SubItems | ForEach-Object { $_.Text }) -join "`t"
    }
    if (-not (Set-ClipboardText -Text ($lines -join [Environment]::NewLine))) {
        Set-Status 'Clipboard busy; could not copy the selected rows.'
    }
}

function Export-PreviewCsv {
    if ($script:PreviewItems.Count -eq 0) { return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $dialog.Filter   = 'CSV file (*.csv)|*.csv'
        $dialog.FileName = 'translate-names-preview.csv'
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $rows = foreach ($row in $script:PreviewItems) {
            [pscustomobject]@{
                Type         = $row.SubItems[0].Text
                Language     = $row.SubItems[1].Text
                Location     = $row.SubItems[2].Text
                OriginalName = $row.SubItems[3].Text
                NewName      = $row.SubItems[4].Text
                Status       = $row.SubItems[5].Text
                FinalTarget  = if ($row.SubItems.Count -gt 6) { $row.SubItems[6].Text } else { '' }
                FullPath     = $row.Tag.FullPath
            }
        }
        $rows | Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8
        Set-Status "Preview exported to $($dialog.FileName)"
    } catch {
        [void](Show-Message -Text "Export failed:`r`n$($_.Exception.Message)" -Title 'Export failed' -Icon 'Warning')
    } finally {
        $dialog.Dispose()
    }
}

function Show-SelectedInExplorer {
    $selected = @(Get-SelectedRows)
    if ($selected.Count -ne 1) { return }
    $path = $selected[0].Tag.FullPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $path) } catch { }
}

# Turn a multi-selection into the list of things to scan: folders stay folders,
# files stay files, a folder inside another selected folder is dropped (it would
# otherwise be scanned twice), and duplicates disappear.
function Get-DroppedRoots {
    param([string[]]$Paths)
    $files = New-Object System.Collections.Generic.List[string]
    $folders = New-Object System.Collections.Generic.List[string]

    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath($path).TrimEnd('\', '/') } catch { continue }
        if ([string]::IsNullOrWhiteSpace($full)) { continue }
        if (Test-Path -LiteralPath $full -PathType Container) { $folders.Add($full) }
        elseif (Test-Path -LiteralPath $full -PathType Leaf) { $files.Add($full) }
    }

    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($folder in $folders) {
        $covered = $false
        foreach ($other in $folders) {
            if ($other -eq $folder) { continue }
            if ($folder.StartsWith(($other + '\'), [StringComparison]::OrdinalIgnoreCase)) { $covered = $true; break }
        }
        if (-not $covered -and $seen.Add($folder)) { $result.Add($folder) }
    }
    foreach ($file in $files) {
        # A file inside a folder that is also selected would be scanned twice.
        $inside = $false
        foreach ($folder in $folders) {
            if ($file.StartsWith(($folder + '\'), [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break }
        }
        if (-not $inside -and $seen.Add($file)) { $result.Add($file) }
    }
    return $result.ToArray()
}

# Queue every path from a multi-select drop. The folder box keeps showing a real
# folder (so recents and re-running still work); the queued set is what the scan
# actually walks, and the status line says so.
function Set-ScanRoots {
    param([string[]]$Paths)

    if ($script:Context -or $script:Job) {
        Set-Status 'A job is running; finish or cancel it before choosing another folder.'
        return
    }
    $roots = @(Get-DroppedRoots -Paths $Paths)
    if ($roots.Count -eq 0) { return }

    if ($roots.Count -eq 1 -and (Test-Path -LiteralPath $roots[0] -PathType Container)) {
        Set-FolderPath $roots[0]
        return
    }

    $folderRoots = @($roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    $anchor = if ($folderRoots.Count -gt 0) { [string]$folderRoots[0] }
              elseif (Test-Path -LiteralPath $roots[0] -PathType Container) { [string]$roots[0] }
              else { Split-Path -Parent ([string]$roots[0]) }

    $script:ScanRoots     = $roots
    $script:ScanMultiRoot = $true
    if ($anchor) { $script:ScanRoot = ([System.IO.Path]::GetFullPath($anchor)).TrimEnd('\', '/') }

    $script:PathComboUpdating = $true
    try { $txtPath.Text = $script:ScanRoot } finally { $script:PathComboUpdating = $false }
    Add-RecentFolder $script:ScanRoot
    $script:PreviewItems.Clear()
    Clear-ResultsView
    $script:SortColumn = -1
    $progress.Value = 0
    Update-ActionState

    $folderCount = $folderRoots.Count
    $fileCount = $roots.Count - $folderCount
    $parts = @()
    if ($folderCount -gt 0) { $parts += ('{0} folder(s)' -f $folderCount) }
    if ($fileCount -gt 0)   { $parts += ('{0} file(s)' -f $fileCount) }
    Set-Status ('Queued {0}: {1}. Press F5 or click Preview translations.' -f $roots.Count, ($parts -join ', '))
}

function Set-FolderPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # A drop or a typed path during a scan/apply would clear the queue the
    # running job is working from.
    if ($script:Context -or $script:Job) {
        Set-Status 'A job is running; finish or cancel it before choosing another folder.'
        return
    }
    $resolved = $Path
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $resolved = Split-Path -Parent $Path }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return }

    $script:ScanRoots      = @($resolved)
    $script:ScanMultiRoot  = $false
    $script:PathComboUpdating = $true
    try { $txtPath.Text = $resolved } finally { $script:PathComboUpdating = $false }
    Add-RecentFolder $resolved
    $script:PreviewItems.Clear()
    Clear-ResultsView
    $script:SortColumn = -1
    $progress.Value = 0
    Update-ActionState
    Set-Status 'Folder selected. Press F5 or click Preview translations.'
}

#endregion

#region ---------------------------------------------------------- Event wiring

$btnPreview.Add_Click({ Start-Scan })
$btnClear.Add_Click({ Clear-Queue })
$btnApply.Add_Click({ Start-ApplyJob })
$btnUndo.Add_Click({ Start-UndoJob })

$btnCancel.Add_Click({
    if ($script:Context) { $script:Context.Cancel = $true }
    if ($script:Job)     { $script:Job.Cancel = $true }
    $btnCancel.Enabled = $false
    Set-Status 'Cancelling...'
})

$btnBrowse.Add_Click({
    $selected = Select-FolderDialog -Initial $txtPath.Text
    if ($selected) {
        # Selecting a folder lists its contents without spending requests;
        # translating still waits for Preview/F5.
        Set-FolderPath $selected
        Start-Scan -ListOnly
    }
})

$txtPath.Add_SelectedIndexChanged({
    if ($script:PathComboUpdating) { return }
    $selected = [string]$txtPath.SelectedItem
    if ($selected) {
        Set-FolderPath $selected
        Start-Scan -ListOnly
    }
})

$txtPath.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Enter') {
        Set-FolderPath $txtPath.Text
        Start-Scan -ListOnly
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    }
})

$chkAdvanced.Add_CheckedChanged({
    if ($script:ModeUpdating) { return }
    Set-UiMode -Mode $(if ($chkAdvanced.Checked) { 'Advanced' } else { 'Simple' }) -Persist
})

$menuIncFiles.Add_Click({
    $chkFiles.Checked = $menuIncFiles.Checked
    Assert-IncludeChoice -Cleared 'files'
    Update-IncludeMenu
})
$menuIncFolders.Add_Click({
    $chkFolders.Checked = $menuIncFolders.Checked
    Assert-IncludeChoice -Cleared 'folders'
    Update-IncludeMenu
})

# The Advanced checkboxes are the same two choices, so they get the same guard.
foreach ($chkInclude in @($chkFiles, $chkFolders)) {
    $chkInclude.Add_CheckedChanged({
        if ($script:ModeUpdating) { return }
        $cleared = if ($this -eq $chkFolders) { 'folders' } else { 'files' }
        Assert-IncludeChoice -Cleared $cleared
        Update-IncludeMenu
    })
}
$menuIncRecurse.Add_Click({
    $chkRecurse.Checked = $menuIncRecurse.Checked
    Update-IncludeMenu
})
$menuIncHidden.Add_Click({
    $chkHidden.Checked = $menuIncHidden.Checked
    Update-IncludeMenu
})
$menuInclude.Add_Opening({ Update-IncludeMenu })

$btnGlossary.Add_Click({
    [void](Show-HelpDialog)
    $script:Glossary = Import-Glossary
})

$btnDefaults.Add_Click({
    $answer = Show-Message -Text "Restore the default name template, skip folders, exclude regex and skip extensions?`r`n`r`nOther options are left untouched." -Title 'Restore defaults' -Buttons 'YesNo' -Icon 'Question'
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $txtTemplate.Text      = '{translated}'
    $txtExcludeFolders.Text = $script:DefaultSkipFolders
    $txtExclude.Text       = ''
    $txtSkipExt.Text       = ''
    Set-Status 'Defaults restored: template, skip folders, exclude regex, skip extensions.'
})

$cmbProvider.Add_SelectedIndexChanged({
    $isDeepL = ([string]$cmbProvider.SelectedItem) -eq 'DeepL'
    $txtApiKey.Enabled = $isDeepL
    $lblApiKey.ForeColor = if ($isDeepL) { $script:Theme.Foreground } else { $script:Theme.Subtle }
})

$chkHide.Add_CheckedChanged({ Update-ResultsView })
$txtFilter.Add_TextChanged({ Update-ResultsView })
$chkFailedOnly.Add_CheckedChanged({ Update-ResultsView })
$chkConflictOnly.Add_CheckedChanged({ Update-ResultsView })

$chkFiles.Add_CheckedChanged({
    if (-not $chkFiles.Checked -and -not $chkFolders.Checked) { $chkFolders.Checked = $true }
})
$chkFolders.Add_CheckedChanged({
    if (-not $chkFiles.Checked -and -not $chkFolders.Checked) { $chkFiles.Checked = $true }
})

$lvResults.Add_ColumnClick({
    param($sender, $e)
    if ($e.Column -eq $script:SortColumn) {
        $script:SortOrder = if ($script:SortOrder -eq [System.Windows.Forms.SortOrder]::Ascending) {
            [System.Windows.Forms.SortOrder]::Descending
        } else {
            [System.Windows.Forms.SortOrder]::Ascending
        }
    } else {
        $script:SortColumn = $e.Column
        $script:SortOrder  = [System.Windows.Forms.SortOrder]::Ascending
    }
    # Virtual mode has no ListViewItemSorter: sort the visible model instead.
    Update-ResultsView
})

$lvResults.Add_DoubleClick({
    param($sender, $e)
    $hit = Get-RowAtPoint -Point $e.Location
    if (-not $hit) { return }
    # Clicks past the "New name" column (Status, Final target) are not edits.
    $bounds = Get-CellEditBounds -Row $hit.Row
    if ($bounds.Width -gt 4 -and $e.X -gt $bounds.Right) { return }
    Start-CellEdit -Row $hit.Row
})

$lvResults.Add_KeyDown({
    param($sender, $e)
    switch ($e.KeyCode) {
        'F2'     { Edit-SelectedRow;   $e.Handled = $true }
        'Delete' { Remove-SelectedRows; $e.Handled = $true }
        'A'      {
            if ($e.Control) {
                $lvResults.BeginUpdate()
                try {
                    $lvResults.SelectedIndices.Clear()
                    for ($i = 0; $i -lt $lvResults.VirtualListSize; $i++) { [void]$lvResults.SelectedIndices.Add($i) }
                } finally { $lvResults.EndUpdate() }
                $e.Handled = $true
                $e.SuppressKeyPress = $true
            }
        }
        'C'      { if ($e.Control) { Copy-SelectedRows; $e.Handled = $true; $e.SuppressKeyPress = $true } }
    }
})

# Inline editor: Enter and Tab commit and walk down the list, Shift+Tab walks
# up, Esc abandons the edit, and clicking anywhere else commits.
$txtCellEdit.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Enter' -or $e.KeyCode -eq 'Tab') {
        Complete-CellEdit -Advance $(if ($e.Shift) { -1 } else { 1 })
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    } elseif ($e.KeyCode -eq 'Escape') {
        Complete-CellEdit -Cancel
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    }
})

$txtCellEdit.Add_LostFocus({
    if ($script:CellEditRow) { Complete-CellEdit }
})

# Anything that moves the rows out from under the editor has to close it first.
$lvResults.Add_MouseWheel({ if ($script:CellEditRow) { Complete-CellEdit -Cancel } })
$lvResults.Add_Resize({ if ($script:CellEditRow) { Complete-CellEdit } })
$lvResults.Add_ColumnWidthChanged({ if ($script:CellEditRow) { Complete-CellEdit -Cancel } })

$menuEdit.Add_Click({ Edit-SelectedRow })
$menuRevert.Add_Click({ Reset-SelectedRows })
$menuOpen.Add_Click({ Show-SelectedInExplorer })
$menuRemove.Add_Click({ Remove-SelectedRows })
$menuCopy.Add_Click({ Copy-SelectedRows })
$menuExport.Add_Click({ Export-PreviewCsv })

$menu.Add_Opening({
    param($sender, $e)
    $selectedCount = @(Get-SelectedRows).Count
    $hasSelection = $selectedCount -gt 0
    $single       = $selectedCount -eq 1
    # Editing is paused while a rename batch runs: the job works from the plan
    # captured at Start-ApplyJob, so a change now would not be applied.
    $editable     = -not [bool]$script:Job
    $menuEdit.Enabled   = ($single -and $editable)
    $menuRevert.Enabled = ($hasSelection -and $editable)
    $menuOpen.Enabled   = $single
    $menuRemove.Enabled = ($hasSelection -and $editable)
    $menuCopy.Enabled   = $hasSelection
    $menuExport.Enabled = ($script:PreviewItems.Count -gt 0)
})

$form.Add_DragEnter({
    param($sender, $e)
    $e.Effect = if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        [System.Windows.Forms.DragDropEffects]::Copy
    } else {
        [System.Windows.Forms.DragDropEffects]::None
    }
})

$form.Add_DragDrop({
    param($sender, $e)
    $paths = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if (-not $paths -or $paths.Count -eq 0) { return }
    # One folder behaves as before; several folders and files are queued
    # together, so a multi-selection in Explorer is one preview.
    Set-ScanRoots -Paths ([string[]]$paths)
    # A drop lists the contents right away (no requests are sent) and leaves
    # the translation itself to Preview/F5.
    Start-Scan -ListOnly
})

$form.Add_KeyDown({
    param($sender, $e)
    # While a cell is being edited the keystrokes belong to the editor: only Esc
    # is handled here, so Ctrl+Z cannot start an undo mid-edit and F5 cannot
    # start a scan over the top of it.
    if ($script:CellEditRow) {
        if ($e.KeyCode -eq 'Escape') {
            Complete-CellEdit -Cancel
            $e.Handled = $true
        }
        return
    }
    if ($e.Control -and $e.KeyCode -eq 'Z') {
        if ($btnUndo.Enabled) { Start-UndoJob }
        $e.Handled = $true
    } elseif ($e.Control -and $e.KeyCode -eq 'F') {
        $txtFilter.Focus()
        $txtFilter.SelectAll()
        $e.Handled = $true
    } elseif ($e.Control -and $e.KeyCode -eq 'D') {
        Copy-Diagnostics
        $e.Handled = $true
    } elseif ($e.KeyCode -eq 'F5') {
        if ($btnPreview.Enabled) { Start-Scan }
        $e.Handled = $true
    } elseif ($e.KeyCode -eq 'F1') {
        [void](Show-HelpDialog)
        $script:Glossary = Import-Glossary
        $e.Handled = $true
    } elseif ($e.KeyCode -eq 'Escape') {
        if ($txtFilter.Focused -and $txtFilter.Text) {
            $txtFilter.Clear()
            $e.Handled = $true
        } elseif ($btnCancel.Enabled) {
            $btnCancel.PerformClick()
            $e.Handled = $true
        }
    }
})

Write-BootLog 'form-built'
$form.Add_Shown({
    Write-BootLog 'window-shown'
    # One-time fit: make sure the auto-sized chrome plus a usable results list
    # fits the window, then pin the minimum size so it cannot be shrunk back
    # into a clipped bottom row at high DPI.
    if (-not $script:LayoutFitted) {
        $script:LayoutFitted = $true
        Update-WindowFit
    }

    # -Help: show the guide once, then leave (useful for shortcuts).
    if ($Help -and -not $script:StartupHelpShown) {
        $script:StartupHelpShown = $true
        [void](Show-HelpDialog)
        $form.Close()
    }
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:Context -or $script:Job) {
        $answer = Show-Message -Text 'A job is still running. Stop it and close?' -Title 'Job in progress' -Buttons 'YesNo' -Icon 'Question'
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            return
        }
    }
    if ($script:Context) { $script:Context.Cancel = $true }
    if ($script:Job)     { $script:Job.Cancel = $true }
    $timerDrain.Stop()
    $timerJob.Stop()
    # Do not wait for an in-flight HTTP request here; the process exits next.
    Clear-ScanWorker -Abandon
    Save-CurrentSettings
    Save-TranslationCacheIfChanged
    Compress-Journal
})

$form.Add_FormClosed({
    foreach ($brush in $script:Brushes.Values) { try { $brush.Dispose() } catch { } }
    try { $timerDrain.Dispose() } catch { }
    try { $timerJob.Dispose() }   catch { }
    try { $tooltip.Dispose() }    catch { }
    if ($script:InstanceMutex) {
        try { [void]$script:InstanceMutex.ReleaseMutex() } catch { }
        try { $script:InstanceMutex.Dispose() } catch { }
        $script:InstanceMutex = $null
    }
})

[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    [void][System.Windows.Forms.MessageBox]::Show(
        "Something went wrong, but the app is still running.`r`n`r`n$($e.Exception.Message)",
        $script:AppName, 'OK', 'Warning')
})

#endregion

#region ---------------------------------------------------------- Startup

$txtApiKey.Enabled = (([string]$cmbProvider.SelectedItem) -eq 'DeepL')
$lblApiKey.ForeColor = if ($txtApiKey.Enabled) { $script:Theme.Foreground } else { $script:Theme.Subtle }

# Keep one snapshot per app version in the data folder, so a bad edit to the
# script can always be compared against (or restored from) the last good copy.
try {
    if (Test-Path -LiteralPath $script:ScriptPath) {
        $versionsDir = Join-Path $script:DataDir 'versions'
        $snapshot = Join-Path $versionsDir ("TranslateNamesApp-{0}.ps1" -f $script:AppVersion)
        if (-not (Test-Path -LiteralPath $snapshot)) {
            if (-not (Test-Path -LiteralPath $versionsDir)) { $null = New-Item -ItemType Directory -Path $versionsDir -Force }
            Copy-Item -LiteralPath $script:ScriptPath -Destination $snapshot -Force
        }
    }
} catch { }

# Single instance: two windows applying renames to the same tree would race.
# Automation runs are exempt: a real window holding the lock would otherwise
# activate itself and swallow the run before any report is written.
$smokeMode = [bool]($env:TRANSLATENAMES_SMOKE_APPLY -or $env:TRANSLATENAMES_SMOKE_HELP -or
                      $env:TRANSLATENAMES_SMOKE_SETTINGS -or $env:TRANSLATENAMES_SMOKE_VIRTUAL -or
                      $env:TRANSLATENAMES_SMOKE_EDIT)
try {
    if ($smokeMode) {
        Write-BootLog 'mutex-skipped-smoke'
    } else {
        $script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\TranslateNamesApp-2')
        $acquired = $false
        try { $acquired = $script:InstanceMutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            $activated = $false
            if ($script:InteropReady) {
                $activated = [TranslateNames.Native]::ActivateWindow("$script:AppName $script:AppVersion")
            }
            if ($activated) {
                $script:InstanceMutex.Dispose()
                $script:InstanceMutex = $null
                Write-BootLog 'mutex-activated-return'
                return
            }
            # The mutex is held but there is no window to activate: a previous
            # run died without releasing it. Refusing to start forever would be
            # worse than the tiny chance of two windows, so continue unlocked.
            try { $script:InstanceMutex.Dispose() } catch { }
            $script:InstanceMutex = $null
            Write-BootLog 'mutex-stale-continue'
        } else {
            Write-BootLog 'mutex-acquired'
        }
    }
} catch {
    # A mutex failure must never stop the app from starting.
    $script:InstanceMutex = $null
}

Update-RecentCombo
Apply-ColumnWidths $script:Settings.ColumnWidths
Set-UiMode -Mode ([string]$script:Settings.UiMode) -NoFit

if ($InitialPath) {
    # Context menu or command line with a folder: load it, but leave the scan
    # to the user (F5 or Preview translations).
    Set-FolderPath $InitialPath
} elseif ($script:Settings.LastFolder -and (Test-Path -LiteralPath ([string]$script:Settings.LastFolder) -PathType Container)) {
    $txtPath.Text = [string]$script:Settings.LastFolder
}

Refresh-UndoState
if ($script:UndoJournal.Count -gt 0) {
    $btnUndo.Enabled = $true
    Set-Status (Get-UndoBatchSummary)
}

# Help-window automation for the test suite: open the real dialog off-screen,
# optionally save a PNG, then exit without touching any files.
if ($env:TRANSLATENAMES_SMOKE_HELP) {
    $form.ShowInTaskbar = $false
    $form.Opacity = 0.01
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $helpDialog = New-HelpDialog
    try {
        $helpDialog.ShowInTaskbar = $false
        $helpDialog.Opacity = 0.01
        $helpDialog.Show($form)
        [System.Windows.Forms.Application]::DoEvents()
        if ($env:TRANSLATENAMES_SMOKE_HELP_SIZE) {
            try {
                # 'min' asks for the smallest size the dialog allows, whatever the
                # display scaling is; WxH forces an exact client size instead.
                $sizeText = [string]$env:TRANSLATENAMES_SMOKE_HELP_SIZE
                if ($sizeText -eq 'min') {
                    $helpDialog.Size = $helpDialog.MinimumSize
                } else {
                    $sizeParts = $sizeText -split 'x'
                    $helpDialog.ClientSize = New-Object System.Drawing.Size([int]$sizeParts[0], [int]$sizeParts[1])
                }
                [System.Windows.Forms.Application]::DoEvents()
            } catch { }
        }
        if ($env:TRANSLATENAMES_SMOKE_HELP_REPORT) {
            $helpBody = $script:HelpBodyBox.Text
            $helpLines = @(
                ('sections=' + $script:HelpSections.Count)
                ('bodyLength=' + $helpBody.Length)
                ('firstLine=' + (($helpBody -split "`r?`n")[0]))
                ('bodyVisible=' + $script:HelpBodyBox.Visible + ' size=' + $script:HelpBodyBox.Width + 'x' + $script:HelpBodyBox.Height)
                ('fore=' + $script:HelpBodyBox.ForeColor.ToString() + ' back=' + $script:HelpBodyBox.BackColor.ToString())
                ('client=' + $helpDialog.ClientSize.Width + 'x' + $helpDialog.ClientSize.Height)
            )
            foreach ($helpButton in $script:HelpButtons) {
                $inside = ($helpButton.Left -ge 0 -and $helpButton.Top -ge 0 -and
                           ($helpButton.Right -le $helpButton.Parent.ClientSize.Width) -and
                           ($helpButton.Bottom -le $helpButton.Parent.ClientSize.Height))
                $helpLines += ('button=' + $helpButton.Text.Replace(' ', '_') + ' visible=' + $helpButton.Visible + ' inside=' + $inside)
            }
            [System.IO.File]::WriteAllLines($env:TRANSLATENAMES_SMOKE_HELP_REPORT, [string[]]$helpLines)
        }
        if ($env:TRANSLATENAMES_SMOKE_SHOT) {
            $bitmap = New-Object System.Drawing.Bitmap($helpDialog.Width, $helpDialog.Height)
            $helpDialog.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $helpDialog.Width, $helpDialog.Height)))
            $bitmap.Save($env:TRANSLATENAMES_SMOKE_SHOT, [System.Drawing.Imaging.ImageFormat]::Png)
            $bitmap.Dispose()
        }
    } finally {
        try { $helpDialog.Close() } catch { }
        try { $helpDialog.Dispose() } catch { }
        $form.Close()
        try { $form.Dispose() } catch { }
    }
    return
}

# Settings/filter/diagnostics automation used by the release checks.
if ($env:TRANSLATENAMES_SMOKE_SETTINGS) {
    $settingsReport = $env:TRANSLATENAMES_SMOKE_SETTINGS
    $form.ShowInTaskbar = $false
    $form.Opacity = 0.01
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $checks = New-Object System.Collections.Generic.List[string]
    try {
        $before = Get-CurrentSettings
        $checks.Add('settingsKeys=' + $before.Keys.Count)

        $overrides = [pscustomobject]@{
            TargetLanguage = 'German'
            Template       = '{original} - {translated}'
            MaxDepth       = 3
            IncludeFiles   = $false
            DelayMs        = 750
            AutoSuffix     = $false
            RecentFolders  = @('C:\', 'D:\')
        }
        Apply-SettingsToControls (ConvertTo-SettingsHashtable $overrides)
        $checks.Add('target=' + [string]$cmbTarget.SelectedItem)
        $checks.Add('template=' + [string]$txtTemplate.Text)
        $checks.Add('depth=' + [string]$numDepth.Value)
        $checks.Add('includeFiles=' + [string]$chkFiles.Checked)
        $checks.Add('delay=' + [string]$numDelay.Value)
        $checks.Add('autoSuffix=' + [string]$chkAutoSuffix.Checked)
        $checks.Add('recent=' + (@($script:RecentFolders) -join ';'))
        $checks.Add('diagnosticsHasVersion=' + [bool]((Get-DiagnosticsText) -match ('Version: ' + [regex]::Escape($script:AppVersion))))
        $checks.Add('protectedDrive=' + (Get-ProtectedRootReason -Path 'C:\'))
        $checks.Add('protectedTemp=' + [bool](Get-ProtectedRootReason -Path $env:TEMP))
        $checks.Add('columnsPersisted=' + [bool](@($before.ColumnWidths).Count -eq $lvResults.Columns.Count))

        # Simple/advanced switch: same controls, reparented; the advanced block
        # and the filter bar collapse in Simple mode.
        $checks.Add('uiModeDefault=' + [string]$script:UserMode)
        Set-UiMode -Mode 'Advanced' -NoFit
        $checks.Add('advancedOptionsVisible=' + [bool]$options.Visible)
        $checks.Add('advancedFilterVisible=' + [bool]$filterRow.Visible)
        $checks.Add('advancedTargetInHeader=' + [bool]($cmbTarget.Parent -eq $modeRow))
        $checks.Add('advancedSourceInHeader=' + [bool]($cmbSource.Parent -eq $modeRow))
        $checks.Add('advancedLimitsInGrid=' + [bool](($numMaxLen.Parent -eq $options) -and ($numDepth.Parent -eq $options)))
        $checks.Add('advancedIncludeHidden=' + (-not [bool]$btnInclude.Visible))
        $form.PerformLayout()
        $advancedRows = $root.GetRowHeights()
        $checks.Add('advancedOptionsRow=' + [int]$advancedRows[2])
        $checks.Add('advancedFilterRow=' + [int]$advancedRows[4])
        Set-UiMode -Mode 'Simple' -NoFit
        $checks.Add('simpleOptionsHidden=' + (-not [bool]$options.Visible))
        $checks.Add('simpleFilterHidden=' + (-not [bool]$filterRow.Visible))
        $checks.Add('simpleTargetInHeader=' + [bool]($cmbTarget.Parent -eq $modeRow))
        $checks.Add('simpleSourceInHeader=' + [bool]($cmbSource.Parent -eq $modeRow))
        $checks.Add('simpleIncludeVisible=' + [bool]$btnInclude.Visible)
        $checks.Add('simpleCheckbox=' + [bool]$chkAdvanced.Checked)
        $form.PerformLayout()
        $simpleRows = $root.GetRowHeights()
        $checks.Add('simpleOptionsRow=' + [int]$simpleRows[2])
        $checks.Add('simpleFilterRow=' + [int]$simpleRows[4])
        $checks.Add('simpleListRow=' + [int]$simpleRows[5])
        # CheckOnClick toggles the item before Click fires, exactly as a real
        # mouse click does, so PerformClick on an unchecked item means "check it".
        $chkFiles.Checked = $false
        $menuIncFiles.Checked = $false
        $menuIncFiles.PerformClick()
        $checks.Add('includeMenuChecksFile=' + [bool]$chkFiles.Checked)

        $failedRow = New-Object System.Windows.Forms.ListViewItem('File')
        foreach ($text in @('ja', '.', 'a.txt', 'b.txt', 'Failed', '')) { [void]$failedRow.SubItems.Add($text) }
        $failedRow.Tag = [pscustomobject]@{ BaseState = 'Preview'; State = 'Failed' }
        $okRow = New-Object System.Windows.Forms.ListViewItem('File')
        foreach ($text in @('ja', '.', 'c.txt', 'd.txt', 'Preview', '')) { [void]$okRow.SubItems.Add($text) }
        $okRow.Tag = [pscustomobject]@{ BaseState = 'Preview'; State = 'Preview' }
        $chkHide.Checked = $false
        $txtFilter.Text = ''
        $chkFailedOnly.Checked = $true
        $checks.Add('filterFailedOnly=' + [bool]((Test-RowVisible $failedRow) -and -not (Test-RowVisible $okRow)))
        $chkFailedOnly.Checked = $false
        $txtFilter.Text = 'a.txt'
        $checks.Add('filterFind=' + [bool]((Test-RowVisible $failedRow) -and -not (Test-RowVisible $okRow)))
        $txtFilter.Text = ''
        $chkConflictOnly.Checked = $false

        $null = Reset-AllSettings
        $checks.Add('afterResetTarget=' + [string]$cmbTarget.SelectedItem)
        $checks.Add('afterResetTemplate=' + [string]$txtTemplate.Text)
        $checks.Add('afterResetUiMode=' + [string]$script:UserMode)

        $json = Get-CurrentSettings | ConvertTo-Json -Depth 5
        $roundTrip = ConvertTo-SettingsHashtable ($json | ConvertFrom-Json)
        $checks.Add('roundTripTarget=' + [string]$roundTrip.TargetLanguage)
        $checks.Add('result=PASS')
    } catch {
        $checks.Add('result=FAIL ' + $_.Exception.Message)
        $checks.Add('stack=' + $_.ScriptStackTrace)
    }
    [System.IO.File]::WriteAllLines($settingsReport, $checks.ToArray())
    try { $form.Close() } catch { }
    try { $form.Dispose() } catch { }
    return
}

# Virtual-list benchmark/automation for release checks.
if ($env:TRANSLATENAMES_SMOKE_VIRTUAL) {
    $virtualReport = $env:TRANSLATENAMES_SMOKE_VIRTUAL
    $form.ShowInTaskbar = $false
    $form.Opacity = 0.01
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $virtualChecks = New-Object System.Collections.Generic.List[string]
    try {
        $rowCount = 20000
        if ($env:TRANSLATENAMES_SMOKE_VIRTUAL_ROWS) {
            try { $rowCount = [int]$env:TRANSLATENAMES_SMOKE_VIRTUAL_ROWS } catch { }
        }
        $buildTimer = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $rowCount; $i++) {
            $name = ('File {0:D5}.txt' -f $i)
            $payload = [pscustomobject]@{
                FullPath    = ('C:\bench\' + $name)
                RelativeDir = '.'
                Original    = $name
                NewName     = ('Translated {0:D5}.txt' -f $i)
                Extension   = '.txt'
                IsContainer = $false
                Depth       = 1
                Detected    = 'ja'
                State       = 'Preview'
            }
            $script:PreviewItems.Add((New-PreviewRow $payload))
        }
        $buildTimer.Stop()
        $virtualChecks.Add('rows=' + $rowCount)
        $virtualChecks.Add('buildMs=' + $buildTimer.ElapsedMilliseconds)

        $refreshTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $script:RetrieveCount = 0
        Update-ResultsView
        [System.Windows.Forms.Application]::DoEvents()
        $lvResults.Refresh()
        $refreshTimer.Stop()
        $virtualChecks.Add('refreshMs=' + $refreshTimer.ElapsedMilliseconds)
        $virtualChecks.Add('virtualSize=' + $lvResults.VirtualListSize)
        $virtualChecks.Add('retrieved=' + $script:RetrieveCount)
        $virtualChecks.Add('lazy=' + [bool](($script:RetrieveCount -gt 0) -and ($script:RetrieveCount -lt $rowCount)))

        $lvResults.SelectedIndices.Add(0)
        $lvResults.SelectedIndices.Add(1)
        $lvResults.SelectedIndices.Add(2)
        $virtualChecks.Add('selected=' + @(Get-SelectedRows).Count)

        $txtFilter.Text = 'File 000'
        [System.Windows.Forms.Application]::DoEvents()
        $virtualChecks.Add('filtered=' + $lvResults.VirtualListSize)
        $txtFilter.Text = ''
        [System.Windows.Forms.Application]::DoEvents()
        $virtualChecks.Add('unfiltered=' + $lvResults.VirtualListSize)

        $sortTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $script:SortColumn = 3
        $script:SortOrder = [System.Windows.Forms.SortOrder]::Ascending
        Update-ResultsView
        [System.Windows.Forms.Application]::DoEvents()
        $sortTimer.Stop()
        $virtualChecks.Add('sortMs=' + $sortTimer.ElapsedMilliseconds)
        $virtualChecks.Add('sortedSize=' + $lvResults.VirtualListSize)

        # Where a single-row edit spends its time at this size, then the whole
        # edit itself: the number a user feels on every Enter in the editor.
        $planTimer = [System.Diagnostics.Stopwatch]::StartNew()
        Update-FinalPlan
        [System.Windows.Forms.Application]::DoEvents()
        $planTimer.Stop()
        $virtualChecks.Add('planMs=' + $planTimer.ElapsedMilliseconds)

        $countsTimer = [System.Diagnostics.Stopwatch]::StartNew()
        Update-Counts
        $countsTimer.Stop()
        $virtualChecks.Add('countsMs=' + $countsTimer.ElapsedMilliseconds)

        $editTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $editRow = $script:PreviewItems[0]
        Apply-RowNewName -Row $editRow -Name 'Edited row.txt'
        [System.Windows.Forms.Application]::DoEvents()
        $editTimer.Stop()
        $virtualChecks.Add('editMs=' + $editTimer.ElapsedMilliseconds)
        $virtualChecks.Add('editedTarget=' + [string]$editRow.SubItems[6].Text)
        $virtualChecks.Add('result=PASS')
    } catch {
        $virtualChecks.Add('result=FAIL ' + $_.Exception.Message)
        $virtualChecks.Add('stack=' + $_.ScriptStackTrace)
    }
    [System.IO.File]::WriteAllLines($virtualReport, $virtualChecks.ToArray())
    try { $form.Close() } catch { }
    try { $form.Dispose() } catch { }
    return
}

# Off-screen construction check used by the test suite: build and tear down the
# real window without showing anything, so wiring mistakes fail loudly.
if ($env:TRANSLATENAMES_SMOKE) {
    $form.ShowInTaskbar = $false
    $form.Opacity = 0.01
    $script:SmokeTimer = New-Object System.Windows.Forms.Timer
    $script:SmokeTimer.Interval = 1200
    $script:SmokeTimer.Add_Tick({
        $script:SmokeTimer.Stop()
        $form.Close()
    })
    $script:SmokeTimer.Start()
}

# End-to-end automation: preview -> apply (or undo) -> close, driven through the
# real timers and event handlers. Used to verify the transaction path offline.
if ($env:TRANSLATENAMES_SMOKE_APPLY) {
    $smokeLog = $env:TRANSLATENAMES_SMOKE_REPORT
    $maxSteps = if ($env:TRANSLATENAMES_SMOKE_STEPS) { [int]$env:TRANSLATENAMES_SMOKE_STEPS } else { 2400 }
    $isUndo = [bool]$env:TRANSLATENAMES_SMOKE_UNDO
    try {
        $form.ShowInTaskbar = $false
        $form.Opacity = 0.01
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        # Mode checks need both layouts in one run, without saving either.
        if ($env:TRANSLATENAMES_SMOKE_MODE) { Set-UiMode -Mode ([string]$env:TRANSLATENAMES_SMOKE_MODE) }

        # Layout checks need to look at the window at sizes other than the one it
        # was saved at, in particular its own minimum width.
        if ($env:TRANSLATENAMES_SMOKE_SIZE) {
            $sizeParts = $env:TRANSLATENAMES_SMOKE_SIZE -split 'x'
            if ($sizeParts.Count -eq 2) {
                $form.ClientSize = New-Object System.Drawing.Size([int]$sizeParts[0], [int]$sizeParts[1])
                [System.Windows.Forms.Application]::DoEvents()
            }
        }

        if ($env:TRANSLATENAMES_SMOKE_FOLDER) {
            # A semicolon-separated list exercises the multi-select queue.
            $smokeRoots = @($env:TRANSLATENAMES_SMOKE_FOLDER -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($smokeRoots.Count -gt 1) { Set-ScanRoots -Paths $smokeRoots } else { Set-FolderPath $smokeRoots[0] }
        }

        # List-only automation: fill the rows without sending anything, so the
        # "show me the files first" behaviour can be checked end to end.
        $isList = [bool]$env:TRANSLATENAMES_SMOKE_LIST
        if ($isUndo) {
            Refresh-UndoState
            Start-UndoJob
        } elseif ($isList) {
            Start-Scan -ListOnly
        } else {
            Start-Scan
        }

        $guard = 0
        while ((($script:Context) -or ($script:Job)) -and $guard -lt $maxSteps) {
            $guard++
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 25
        }

        if (-not $isUndo -and -not $isList -and -not $script:Context -and -not $script:Job -and $script:PreviewItems.Count -gt 0) {
            Start-ApplyJob
            while ((($script:Context) -or ($script:Job)) -and $guard -lt ($maxSteps * 2)) {
                $guard++
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 25
            }
        }

        # Editor geometry check: open the inline editor on one row before the
        # shot, so a PNG or the report shows exactly where it landed.
        if ($env:TRANSLATENAMES_SMOKE_EDIT) {
            $wanted = [int]$env:TRANSLATENAMES_SMOKE_EDIT
            $editable = @($script:PreviewItems | Where-Object { $_.Tag.State -ne 'Renamed' })
            if ($editable.Count -gt 0) {
                $pick = $editable[[Math]::Min([Math]::Max(0, $wanted - 1), $editable.Count - 1)]
                Start-CellEdit -Row $pick
            }
        }

        if ($env:TRANSLATENAMES_SMOKE_SHOT) {
            try {
                [System.Windows.Forms.Application]::DoEvents()
                $shot = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
                $form.DrawToBitmap($shot, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                # A native EDIT control does not print itself inside the parent's
                # render, so composite the editor's own render at its bounds.
                # Two real renders, not a mock-up: the shot shows what is on
                # screen, including the inline editor when one is open.
                if ($txtCellEdit.Visible -and $txtCellEdit.Width -gt 0) {
                    $editorShot = New-Object System.Drawing.Bitmap($txtCellEdit.Width, $txtCellEdit.Height)
                    try {
                        $txtCellEdit.DrawToBitmap($editorShot, (New-Object System.Drawing.Rectangle(0, 0, $txtCellEdit.Width, $txtCellEdit.Height)))
                        # The bitmap starts at the window origin, the control
                        # bounds at the client origin: offset by the chrome.
                        $inWindow = $form.RectangleToScreen($txtCellEdit.Bounds)
                        $offsetX = $inWindow.X - $form.Bounds.X
                        $offsetY = $inWindow.Y - $form.Bounds.Y
                        $canvas = [System.Drawing.Graphics]::FromImage($shot)
                        try { $canvas.DrawImageUnscaled($editorShot, $offsetX, $offsetY) }
                        finally { $canvas.Dispose() }
                        $editorShot.Save(($env:TRANSLATENAMES_SMOKE_SHOT -replace '\.png$', '') + '-editor.png', [System.Drawing.Imaging.ImageFormat]::Png)
                    } finally { $editorShot.Dispose() }
                }
                $shot.Save($env:TRANSLATENAMES_SMOKE_SHOT, [System.Drawing.Imaging.ImageFormat]::Png)
                $shot.Dispose()
            } catch {
                if ($smokeLog) {
                    [System.IO.File]::AppendAllText($smokeLog, ('SHOT ERROR: ' + $_.Exception.Message + [Environment]::NewLine))
                }
            }
        }

        # Clear-button check: empties the queue and the rows, touches no files.
        if ($env:TRANSLATENAMES_SMOKE_CLEAR) { Clear-Queue }

        # Include-guard check: uncheck both boxes the way a user would and make
        # sure one comes back, then let the report show the resulting caption.
        if ($env:TRANSLATENAMES_SMOKE_INCLUDE) {
            $probeSaved = @([bool]$chkFiles.Checked, [bool]$chkFolders.Checked)
            $chkFiles.Checked = $false
            $chkFolders.Checked = $false
            Update-IncludeMenu
            $script:IncludeProbe = '{0}/{1} ({2})' -f $chkFiles.Checked, $chkFolders.Checked, $btnInclude.Text
            # Put the real settings back: a probe must never be saved as the
            # user's choice, which is exactly what happened once.
            $chkFiles.Checked = $probeSaved[0]
            $chkFolders.Checked = $probeSaved[1]
            Update-IncludeMenu
        }

        if ($smokeLog) {
            $form.PerformLayout()
            $rowHeights = $root.GetRowHeights()
            $lines = @(
                ('preview=' + $script:PreviewItems.Count)
                ('finalPlan=' + $script:FinalPlan.Count)
                ('status=' + $lblStatus.Text)
                ('warnings=' + ($script:Warnings -join ' | '))
                ('undoCount=' + $script:UndoJournal.Count)
                ('steps=' + $guard)
                ('client=' + $form.ClientSize.Width + 'x' + $form.ClientSize.Height)
                ('rows=' + ($rowHeights -join ','))
                ('pathRow=' + $pathRow.Height + ' options=' + $options.Height + ' actions=' + $actions.Height)
                ('modeRow=' + $modeRow.Width + 'x' + $modeRow.PreferredSize.Width + ' include=' + $btnInclude.Width + ' advRight=' + ($chkAdvanced.Left + $chkAdvanced.Width))
                ('includeFiles=' + $chkFiles.Checked + ' includeFolders=' + $chkFolders.Checked + ' includeText=' + $btnInclude.Text + ' includeProbe=' + [string]$script:IncludeProbe)
                ('statusLabel=' + $lblStatus.Height + '/' + $lblStatus.PreferredHeight)
                ('hintLabel=' + $lblHint.Height + '/' + $lblHint.PreferredHeight)
                ('previewBtn=' + $btnPreview.Height + '/' + $btnPreview.PreferredSize.Height)
                ('browseBtn=' + $btnBrowse.Height + '/' + $btnBrowse.PreferredSize.Height)
                ('fontHeight=' + [Math]::Round($form.Font.GetHeight(), 1))
                ('dpiScale=' + $script:DpiScale + ' lineHeight=' + $script:LineHeight)
                ('minSize=' + $form.MinimumSize.Width + 'x' + $form.MinimumSize.Height)
                ('actionsPreferred=' + $actions.PreferredSize.Width + 'x' + $actions.PreferredSize.Height)
                ('previewWidth=' + $btnPreview.Width + '/' + $btnPreview.PreferredSize.Width)
                ('bottomOfRoot=' + $root.Padding.Top + ($rowHeights | Measure-Object -Sum).Sum)
                ('cellEditVisible=' + [bool]$txtCellEdit.Visible)
                ('cellEditRow=' + [int]$script:ViewRows.IndexOf($script:CellEditRow))
                ('cellEditBox=' + $txtCellEdit.Bounds.ToString())
                ('cellEditCell=' + (Get-CellEditBounds -Row $script:CellEditRow).ToString())
                ('cellEditZ=' + $form.Controls.GetChildIndex($txtCellEdit) + '/' + $form.Controls.GetChildIndex($root) + ' parent=' + $txtCellEdit.Parent.GetType().Name)
                ('cellEditCover=' + $lvResults.RectangleToClient($form.RectangleToScreen($txtCellEdit.Bounds)).ToString() + ' cell=' + (Get-CellEditBounds -Row $script:CellEditRow).ToString())
            )
            [System.IO.File]::WriteAllLines($smokeLog, [string[]]$lines)
        }
    } catch {
        if ($smokeLog) {
            [System.IO.File]::AppendAllText($smokeLog,
                ('ERROR: ' + $_.Exception.Message + [Environment]::NewLine + 'STACK: ' + $_.ScriptStackTrace + [Environment]::NewLine))
        }
    }
    try { $form.Close() } catch { }
    try { $form.Dispose() } catch { }
    return
}

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    try { $form.Dispose() } catch { }
}

#endregion