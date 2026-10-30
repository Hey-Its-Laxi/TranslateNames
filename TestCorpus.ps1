<#
.SYNOPSIS
    Generates a hostile-but-valid test corpus for Translate Names.

.DESCRIPTION
    Creates files, folders and names designed to break a bulk renamer: many
    languages, RTL text, emoji/ZWJ sequences, combining marks, symbols, quotes,
    reserved-looking names, tiny/empty/long names, every common file type,
    duplicate and colliding translations, hidden/read-only files, excluded
    folders (node_modules, .git, $RECYCLE.BIN) and a parent/child rename pair.

    Also writes _meta\settings.json and _meta\cache.json so the offline
    apply/undo tests can run without any network access: each translatable base
    name is pre-mapped to a deliberately dull "TR-nnn" target, with a handful of
    hostile targets (CON, invalid characters, 400 characters, empty, controls)
    thrown in.

    The script source is ASCII-only and builds non-ASCII names from code points,
    so it behaves the same in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Path
    Destination root. Default: <workspace>\TestLab\Corpus.

.PARAMETER IncludeLongPaths
    Also create a subtree longer than 260 characters (created through \\?\;
    some tools cannot enumerate it - that is exactly what it tests).

.PARAMETER Force
    Delete and recreate Path if it already exists.

.EXAMPLE
    .\TestCorpus.ps1 -Path D:\Temp\TranslateCorpus -Force
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$IncludeLongPaths,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    # Same rule as Run-CorpusTests.ps1: nearest ancestor that has a TestLab,
    # else the folder these scripts live in.
    $workspace = $PSScriptRoot
    $probe = $PSScriptRoot
    for ($i = 0; $i -lt 3; $i++) {
        if (Test-Path -LiteralPath (Join-Path $probe 'TestLab')) { $workspace = $probe; break }
        $probe = Split-Path -Parent $probe
        if (-not $probe) { break }
    }
    $Path = Join-Path $workspace 'TestLab\Corpus'
}
$Path = [System.IO.Path]::GetFullPath($Path)

if ((Test-Path -LiteralPath $Path) -and $Force) {
    Remove-Item -LiteralPath $Path -Recurse -Force
}
if (-not (Test-Path -LiteralPath $Path)) {
    $null = New-Item -ItemType Directory -Path $Path -Force
}

# --- helpers ---------------------------------------------------------------

function New-UnicodeText {
    param([int[]]$CodePoints)
    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

function New-Emoji {
    param([int]$CodePoint)
    return [char]::ConvertFromUtf32($CodePoint)
}

$script:Manifest = New-Object System.Collections.Generic.List[object]
$script:Cache    = @{}
$script:Targets  = @{}
$script:Counter  = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Add-CorpusEntry {
    param(
        [string]$Relative,
        [string]$Kind = 'File',
        [string]$Expected = 'scan',
        [string]$Note = '',
        [string]$Content = $null
    )
    $script:Manifest.Add([pscustomobject]@{
        Path     = $Relative
        Kind     = $Kind
        Expected = $Expected
        Note     = $Note
        Content  = $Content
    })
}

function New-CorpusDirectory {
    param([string]$Relative, [string]$Expected = 'scan', [string]$Note = '')
    $full = Join-Path $Path $Relative
    try {
        $null = New-Item -ItemType Directory -Path $full -Force
        Add-CorpusEntry -Relative $Relative -Kind 'Directory' -Expected $Expected -Note $Note
        Register-Translation -Relative $Relative -IsContainer $true
    } catch {
        $script:Failures.Add("dir '$Relative': $($_.Exception.Message)")
    }
}

function Register-Translation {
    param([string]$Relative, [bool]$IsContainer, [string]$TargetOverride)
    $leaf = Split-Path -Leaf $Relative
    $base = if ($IsContainer) {
        $leaf
    } else {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        if ([string]::IsNullOrEmpty($stem)) { $leaf } else { $stem }
    }
    if ([string]::IsNullOrEmpty($base)) { return }

    $key = 'Google|auto|en|' + $base
    if ($script:Cache.ContainsKey($key)) { return }

    $script:Counter++
    if ($TargetOverride) {
        $target = $TargetOverride
    } else {
        $target = 'TR {0:D3}' -f $script:Counter
    }
    $script:Cache[$key] = @{ t = $target; d = 'ja' }
    $script:Targets[$base] = $target
}

function New-CorpusFile {
    param(
        [string]$Relative,
        [string]$Expected = 'scan',
        [string]$Note = '',
        [string]$TargetOverride,
        [switch]$ReadOnly,
        [switch]$Hidden
    )
    $full = Join-Path $Path $Relative
    $parent = Split-Path -Parent $full
    try {
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        $content = 'content:' + $Relative
        [System.IO.File]::WriteAllText($full, $content, (New-Object System.Text.UTF8Encoding($false)))
        $item = Get-Item -LiteralPath $full -Force
        if ($ReadOnly) { $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::ReadOnly }
        if ($Hidden)   { $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden }
        Add-CorpusEntry -Relative $Relative -Kind 'File' -Expected $Expected -Note $Note -Content $content
        Register-Translation -Relative $Relative -IsContainer $false -TargetOverride $TargetOverride
    } catch {
        $script:Failures.Add("file '$Relative': $($_.Exception.Message)")
    }
}

function New-CorpusExtFile {
    param([string]$Extension, [string]$Note = '')
    $name = 'sample{0}' -f $Extension
    New-CorpusFile -Relative ('11-filetypes\' + $name) -Note ("file type " + $Note)
}

# --- 01 basic --------------------------------------------------------------

$null = New-Item -ItemType Directory -Path (Join-Path $Path '01-basic') -Force
Add-CorpusEntry -Relative '01-basic' -Kind 'Directory'
New-CorpusFile '01-basic\plain file.txt' -Note 'plain space'
New-CorpusFile '01-basic\UPPER CASE.TXT' -Note 'upper case'
New-CorpusFile '01-basic\mixed.Case.Name.mkv' -Note 'mixed dots'
New-CorpusFile '01-basic\no-extension' -Note 'no extension'
New-CorpusFile '01-basic\.gitignore' -Note 'dotfile'
New-CorpusFile '01-basic\.mp4' -Note 'extension-only dotfile'
New-CorpusFile '01-basic\archive.tar.gz' -Note 'double extension'
New-CorpusFile '01-basic\double  spaces.txt' -Note 'double spaces'
New-CorpusFile '01-basic\ leading space.txt' -Note 'leading space'
New-CorpusFile '01-basic\12345.txt' -Note 'digits only'
New-CorpusFile '01-basic\2024-01-15.log' -Note 'date-like'
New-CorpusFile '01-basic\a---b___c.txt' -Note 'separator runs'

# --- 02 languages ----------------------------------------------------------

$null = New-Item -ItemType Directory -Path (Join-Path $Path '02-languages') -Force
Add-CorpusEntry -Relative '02-languages' -Kind 'Directory'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x541B, 0x306E, 0x540D, 0x306F, 0x3002)) + '.mkv') -Note 'Japanese'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x5343, 0x3068, 0x5343, 0x5C0B, 0x306E, 0x795E, 0x96A0, 0x3057)) + '.mkv') -Note 'Japanese long'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x4F60, 0x7684, 0x540D, 0x5B57)) + '.mkv') -Note 'Chinese simplified'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x5929, 0x6C23, 0x4E4B, 0x5B50)) + '.mkv') -Note 'Chinese traditional'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0xD55C, 0xAD6D, 0xC5B4, 0x0020, 0xC81C, 0xBAA9)) + '.mkv') -Note 'Korean'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x0627, 0x0633, 0x0645, 0x0020, 0x0645, 0x0644, 0x0641)) + '.txt') -Note 'Arabic RTL'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x05E9, 0x05DD, 0x0020, 0x05D1, 0x05E2, 0x05D1, 0x05E8, 0x05D9, 0x05EA)) + '.txt') -Note 'Hebrew RTL'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x0418, 0x043C, 0x044F, 0x0020, 0x0444, 0x0430, 0x0439, 0x043B, 0x0430)) + '.txt') -Note 'Russian'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x0395, 0x03BB, 0x03BB, 0x03B7, 0x03BD, 0x03B9, 0x03BA, 0x03CC)) + '.txt') -Note 'Greek'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x0E0A, 0x0E37, 0x0E48, 0x0E2D, 0x0E44, 0x0E1F, 0x0E25, 0x0E4C)) + '.txt') -Note 'Thai'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x092B, 0x093E, 0x0907, 0x0932, 0x0020, 0x0915, 0x093E, 0x0020, 0x0928, 0x093E, 0x092E)) + '.txt') -Note 'Hindi'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x0054, 0x00EA, 0x006E, 0x0020, 0x0074, 0x1EC7, 0x0070, 0x0020, 0x0063, 0x00F3, 0x0020, 0x0064, 0x1EA5, 0x0075)) + '.txt') -Note 'Vietnamese precomposed'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x0130, 0x0073, 0x0074, 0x0061, 0x006E, 0x0062, 0x0075, 0x006C, 0x0020, 0x0131, 0x011F, 0x00FC, 0x015F, 0x00F6, 0x00E7)) + '.txt') -Note 'Turkish'
New-CorpusFile ('02-languages\Japanese Title 2024.mkv') -Note 'mixed script'
New-CorpusFile ('02-languages\cafe' + (New-UnicodeText @(0x0301)) + '.txt') -Note 'combining accent (NFD)'
$null = New-Item -ItemType Directory -Path (Join-Path $Path '02-languages\nfc') -Force
Add-CorpusEntry -Relative '02-languages\nfc' -Kind 'Directory'
New-CorpusFile ('02-languages\nfc\caf' + (New-UnicodeText @(0x00E9)) + '.txt') -Note 'precomposed accent (NFC)'
New-CorpusFile ('02-languages\' + (New-UnicodeText @(0x200F)) + 'rtl-mark-prefix.txt') -Note 'RTL mark prefix'

# --- 03 symbols ------------------------------------------------------------

$null = New-Item -ItemType Directory -Path (Join-Path $Path '03-symbols') -Force
Add-CorpusEntry -Relative '03-symbols' -Kind 'Directory'
New-CorpusFile '03-symbols\a&b #1 @home $100 %done !bang +plus =eq ~tilde ^caret.txt' -Note 'shell/percent symbols'
New-CorpusFile '03-symbols\quotes ''single'' and `backtick`.txt' -Note 'quote and backtick'
New-CorpusFile '03-symbols\brackets [S01E02] (1080p) {tag}.mkv' -Note 'all bracket styles'
New-CorpusFile '03-symbols\semicolon;comma,name.txt' -Note 'semicolon comma'
New-CorpusFile '03-symbols\percent %1 %V %PATH%.txt' -Note 'context-menu tokens'
New-CorpusFile ('03-symbols\copyright ' + (New-UnicodeText @(0x00A9)) + '.txt') -Note 'copyright sign'
New-CorpusFile ('03-symbols\' + (New-UnicodeText @(0x00A9, 0x00AE, 0x2122, 0x20AC, 0x00A3, 0x00A5, 0x00A7, 0x00B6, 0x2022)) + '.txt') -Note 'unicode symbols'
New-CorpusFile ('03-symbols\zero' + (New-UnicodeText @(0x200B)) + 'width.txt') -Note 'zero-width space'
New-CorpusFile ('03-symbols\leading' + (New-UnicodeText @(0xFEFF)) + 'bom.txt') -Note 'BOM character in name'

# --- 04 emoji --------------------------------------------------------------

$null = New-Item -ItemType Directory -Path (Join-Path $Path '04-emoji') -Force
Add-CorpusEntry -Relative '04-emoji' -Kind 'Directory'
New-CorpusFile ('04-emoji\' + (New-Emoji 0x1F600) + '.txt') -Note 'single emoji'
New-CorpusFile ('04-emoji\' + (New-Emoji 0x1F468) + (New-UnicodeText @(0x200D)) + (New-Emoji 0x1F469) + (New-UnicodeText @(0x200D)) + (New-Emoji 0x1F467) + (New-UnicodeText @(0x200D)) + (New-Emoji 0x1F466) + ' family.mkv') -Note 'ZWJ family'
New-CorpusFile ('04-emoji\' + (New-Emoji 0x1F1EF) + (New-Emoji 0x1F1F5) + ' flag.txt') -Note 'flag (regional indicators)'
New-CorpusFile ('04-emoji\' + (New-Emoji 0x1F44D) + (New-Emoji 0x1F3FD) + ' skin tone.txt') -Note 'skin tone modifier'
New-CorpusFile ('04-emoji\' + (New-Emoji 0x1F3AC) + ' Movie ' + (New-Emoji 0x1F37F) + '.mkv') -Note 'emoji with text'
New-CorpusFile ('04-emoji\' + (New-Emoji 0x2764) + (New-UnicodeText @(0xFE0F)) + ' heart.txt') -Note 'variation selector'

# --- 05 edge names ---------------------------------------------------------

$null = New-Item -ItemType Directory -Path (Join-Path $Path '05-edge-names') -Force
Add-CorpusEntry -Relative '05-edge-names' -Kind 'Directory'
New-CorpusFile '05-edge-names\name.with.dots....txt' -Note 'dots before extension'
New-CorpusFile '05-edge-names\CONSOLE.txt' -Note 'reserved-looking, valid'
New-CorpusFile '05-edge-names\auxiliary.txt' -Note 'reserved-looking prefix'
New-CorpusFile '05-edge-names\readonly.txt' -ReadOnly -Note 'read-only attribute'
New-CorpusFile '05-edge-names\hidden-file.txt' -Hidden -Note 'hidden attribute'
New-CorpusFile '05-edge-names\~$lock.docx' -Note 'Office lock-file pattern'
New-CorpusFile '05-edge-names\reserved-target.txt' -TargetOverride 'CON' -Note 'translation would be a reserved device name'
New-CorpusFile '05-edge-names\invalid-target.txt' -TargetOverride 'bad:name*?<>|' -Note 'translation contains invalid characters'
New-CorpusFile '05-edge-names\long-target.txt' -TargetOverride ('Long' + ('x' * 400)) -Note 'translation longer than the name limit'
New-CorpusFile '05-edge-names\empty-target.txt' -TargetOverride '   ' -Note 'translation is whitespace only'
New-CorpusFile '05-edge-names\control-target.txt' -TargetOverride ("Tab`tSep`r`nLine") -Note 'translation contains control characters'
New-CorpusFile '05-edge-names\emoji-target.txt' -TargetOverride ((New-Emoji 0x1F600) + ' Emoji') -Note 'translation contains emoji'
New-CorpusFile '05-edge-names\dot-lead.name.txt' -Note 'dot inside name'
New-CorpusFile ('05-edge-names\' + ('x' * 240) + '.txt') -Note '240-char component'

# --- 06 media tags ---------------------------------------------------------

$null = New-Item -ItemType Directory -Path (Join-Path $Path '06-media-tags') -Force
Add-CorpusEntry -Relative '06-media-tags' -Kind 'Directory'
New-CorpusFile '06-media-tags\[SubsPlease] Show Name - S01E02 [1080p][x265][AAC].mkv' -Note 'release tags'
New-CorpusFile '06-media-tags\Show.Name.S02E05.2160p.WEB-DL.DDP5.1.HDR.mkv' -Note 'dotted release tags'
New-CorpusFile ('06-media-tags\' + (New-UnicodeText @(0x7B2C, 0x0033, 0x8A71)) + ' title.mkv') -Note 'CJK episode counter'
New-CorpusFile '06-media-tags\(2023) Movie Name [BDRip 1080p].mkv' -Note 'year and bracket'
New-CorpusFile '06-media-tags\Title - Part 2 (English).mkv' -Note 'part and language'
New-CorpusFile '06-media-tags\EP12 - Name.mkv' -Note 'EP tag'
New-CorpusFile '06-media-tags\Show.S01E02.1080p.srt' -Note 'subtitle sidecar'

# --- 07 structure ----------------------------------------------------------

New-CorpusDirectory '07-structure'
New-CorpusDirectory '07-structure\level1'
New-CorpusDirectory '07-structure\level1\level2'
New-CorpusDirectory '07-structure\level1\level2\level3'
New-CorpusDirectory '07-structure\level1\level2\level3\level4'
New-CorpusFile '07-structure\level1\deep file.txt'
New-CorpusFile '07-structure\level1\level2\level3\level4\deep file 4.txt'
New-CorpusDirectory '07-structure\empty-folder'
New-CorpusDirectory '07-structure\parent folder'
New-CorpusFile '07-structure\parent folder\child file.txt'
New-CorpusDirectory '07-structure\folder S01E02'
New-CorpusFile '07-structure\folder S01E02\episode title.txt'

New-CorpusDirectory '07-structure\node_modules' -Expected 'excluded' -Note 'default folder exclusion'
New-CorpusDirectory '07-structure\node_modules\package-name' -Expected 'excluded'
New-CorpusFile '07-structure\node_modules\package-name\index.js' -Expected 'excluded'
New-CorpusDirectory '07-structure\.git' -Expected 'excluded' -Note 'hidden VCS folder'
New-CorpusFile '07-structure\.git\config' -Expected 'excluded'
New-CorpusDirectory ('07-structure\' + '$RECYCLE.BIN') -Expected 'excluded' -Note 'recycle bin folder'
New-CorpusFile ('07-structure\' + '$RECYCLE.BIN' + '\deleted file.txt') -Expected 'excluded'
New-CorpusDirectory '07-structure\System Volume Information' -Expected 'excluded'
New-CorpusFile '07-structure\System Volume Information\tracking.log' -Expected 'excluded'

# --- 08 collisions ---------------------------------------------------------

New-CorpusDirectory '08-collisions'
New-CorpusFile '08-collisions\a-first.txt' -TargetOverride 'Same Name' -Note 'batch collision partner 1'
New-CorpusFile '08-collisions\b-second.txt' -TargetOverride 'Same Name' -Note 'batch collision partner 2'
New-CorpusFile '08-collisions\already-target.txt' -Note 'existing name; another file will translate to it'
New-CorpusFile '08-collisions\source-to-existing.txt' -TargetOverride 'already-target' -Note 'on-disk collision'
New-CorpusFile '08-collisions\case-only.txt' -TargetOverride 'CASE-ONLY' -Note 'case-only rename target'

# --- 10 encoding names (NFC/NFD in separate folders) -----------------------

New-CorpusDirectory '10-encoding-names'
New-CorpusDirectory '10-encoding-names\nfc'
New-CorpusDirectory '10-encoding-names\nfd'
New-CorpusFile ('10-encoding-names\nfc\caf' + (New-UnicodeText @(0x00E9)) + '.txt') -Note 'NFC folder'
New-CorpusFile ('10-encoding-names\nfd\cafe' + (New-UnicodeText @(0x0301)) + '.txt') -Note 'NFD folder'

# --- 11 filetypes ----------------------------------------------------------

New-CorpusDirectory '11-filetypes'
$extensions = @(
    '.mkv', '.mp4', '.avi', '.srt', '.ass', '.nfo', '.jpg', '.png', '.gif', '.pdf',
    '.docx', '.xlsx', '.pptx', '.zip', '.rar', '.7z', '.iso', '.torrent', '.flac',
    '.mp3', '.m4a', '.wav', '.opus', '.epub', '.cbz', '.cbr', '.json', '.csv',
    '.html', '.md', '.ps1', '.bat', '.vbs', '.ini', '.cfg', '.yml', '.sqlite', '.db'
)
foreach ($extension in $extensions) { New-CorpusExtFile -Extension $extension }

# --- 09 long path (optional) ----------------------------------------------

$longPathCreated = $false
if ($IncludeLongPaths) {
    try {
        $segments = @(('L' * 45), ('O' * 45), ('N' * 45), ('G' * 45), ('P' * 45))
        $relative = '09-long-path\' + ($segments -join '\') + '\long path file.txt'
        $full = Join-Path $Path $relative
        $extended = if ($full.StartsWith('\\')) { '\\?\UNC\' + $full.Substring(2) } else { '\\?\' + $full }
        $parent = [System.IO.Path]::GetDirectoryName($extended)
        $null = [System.IO.Directory]::CreateDirectory($parent)
        [System.IO.File]::WriteAllText($extended, 'content:long', (New-Object System.Text.UTF8Encoding($false)))
        Add-CorpusEntry -Relative '09-long-path' -Kind 'Directory' -Note 'long-path root'
        Add-CorpusEntry -Relative $relative -Kind 'File' -Note 'path longer than 260 characters'
        Register-Translation -Relative $relative -IsContainer $false -TargetOverride 'Long path target'
        $longPathCreated = $true
    } catch {
        $script:Failures.Add("long path: $($_.Exception.Message)")
    }
}

# --- metadata for the test runner -----------------------------------------

$metaDir = Join-Path $Path '_meta'
$null = New-Item -ItemType Directory -Path $metaDir -Force

$settings = [ordered]@{
    SettingsVersion   = 2
    ProtectTags       = $false
    SkipIfTargetLang  = $false
    IncludeHidden     = $true
    Recurse           = $true
    IncludeFiles      = $true
    IncludeFolders    = $true
    AutoSuffix        = $true
    DelayMs           = 0
    MaxDepth          = 0
    MaxNameLength     = 120
    Provider          = 'Google'
    Transliteration   = 'Off'
    CaseMode          = 'As returned'
    Template          = '{translated}'
    ExcludePattern    = ''
    ExcludeFolders    = 'node_modules;.git;.svn;.hg;$RECYCLE.BIN;System Volume Information'
    SkipExtensions    = ''
    WriteCsvLog       = $false
    HideUnchanged     = $false
    LastFolder        = ''
    WindowWidth       = 860
    WindowHeight      = 900
}
[System.IO.File]::WriteAllText((Join-Path $metaDir 'settings.json'), ($settings | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $metaDir 'cache.json'), ($script:Cache | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))

$manifestData = [ordered]@{
    GeneratedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    CorpusPath    = $Path
    IncludeLongPaths = $longPathCreated
    Entries       = $script:Manifest.ToArray()
    CacheEntries  = $script:Cache.Count
    Failures      = $script:Failures.ToArray()
}
[System.IO.File]::WriteAllText((Join-Path $metaDir 'manifest.json'), ($manifestData | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

$readme = @(
    'Translate Names - test corpus'
    ''
    'Generated by TestCorpus.ps1. Names here are deliberately hostile but legal'
    'on Windows. Do not run the renamer over this folder expecting pretty names;'
    'the point is to break it.'
    ''
    '_meta\settings.json and _meta\cache.json let Run-CorpusTests.ps1 run a real'
    'preview/apply/undo pass with no network access.'
    ''
    ('Entries: ' + $script:Manifest.Count)
    ('Cached translations: ' + $script:Cache.Count)
    ('Creation failures: ' + $script:Failures.Count)
)
[System.IO.File]::WriteAllLines((Join-Path $Path 'README.txt'), [string[]]$readme)

Write-Host ("Corpus: {0}" -f $Path)
Write-Host ("  entries: {0}  translations: {1}  failures: {2}  long path: {3}" -f $script:Manifest.Count, $script:Cache.Count, $script:Failures.Count, $longPathCreated)
foreach ($failure in $script:Failures) { Write-Host ("  FAILED TO CREATE: " + $failure) -ForegroundColor Yellow }
if ($script:Failures.Count -gt 0) { exit 2 }
exit 0
