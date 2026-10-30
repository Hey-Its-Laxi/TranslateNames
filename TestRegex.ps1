<#
.SYNOPSIS
    Generates the exclude-regex fixture used by RegexTest.md.

.DESCRIPTION
    Creates the small tree of files and folders that exercises the app's
    "Exclude regex" field: anchors, case, metacharacters that are legal in
    Windows names, Unicode property classes, nesting, and folders the default
    "Skip folders" already hides.

    The tree is generated rather than committed because two of its entries
    cannot live in git: 06-empty\EmptyFolder is empty, and 05-skipped\.git is a
    literal .git directory. Both matter to the test, so the script creates them.

    Like TestCorpus.ps1, this source is ASCII-only and builds non-ASCII names
    from code points, so it behaves the same in Windows PowerShell 5.1 and
    PowerShell 7.

    The expected row counts for every pattern are in RegexTest.md; they were
    measured against this exact tree with -Plan -NoNetwork.

.PARAMETER Path
    Destination root. Default: RegexTest next to this script.

.PARAMETER Force
    Delete and recreate Path if it already exists.

.EXAMPLE
    .\TestRegex.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Join-Path $PSScriptRoot 'RegexTest' }
$Path = [System.IO.Path]::GetFullPath($Path)

if ((Test-Path -LiteralPath $Path) -and $Force) {
    Remove-Item -LiteralPath $Path -Recurse -Force
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$content = "regex fixture: contents do not matter, only the name`r`n"

function New-Text {
    param([int[]]$CodePoints)
    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

function New-Folder {
    param([string]$Relative)
    $full = Join-Path $Path $Relative
    if (-not (Test-Path -LiteralPath $full)) {
        [void](New-Item -ItemType Directory -Path $full -Force)
    }
}

function New-Fixture {
    param([string]$Relative)
    $full = Join-Path $Path $Relative
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [System.IO.File]::WriteAllText($full, $content, $utf8)
}

$files = @(
    # 01 - anchors, case and repetition
    '01-anchors\IMG_0001.jpg'
    '01-anchors\IMG_0002.jpg'
    '01-anchors\IMG_0003.jpg'
    '01-anchors\report.pdf'
    '01-anchors\report (1).pdf'
    '01-anchors\report (2).pdf'
    '01-anchors\README.MD'
    '01-anchors\ReadMe.txt'
    '01-anchors\notes.txt'

    # 02 - regex metacharacters that are legal in Windows names
    '02-specials\file[1].txt'
    '02-specials\a+b.txt'
    '02-specials\cost$5.txt'
    '02-specials\100% done.txt'
    '02-specials\C++ notes.txt'
    '02-specials\file(2) copy.txt'

    # 03 - Unicode property classes
    ('03-unicode\' + (New-Text @(0x03A3, 0x03B7, 0x03BC, 0x03B5, 0x03B9, 0x03CE, 0x03C3, 0x03B5, 0x03B9, 0x03C2)) + '.txt')
    ('03-unicode\' + (New-Text @(0x062A, 0x0642, 0x0631, 0x064A, 0x0631, 0x0020, 0x0633, 0x0646, 0x0648, 0x064A)) + '.pdf')
    ('03-unicode\' + (New-Text @(0x65E5, 0x672C, 0x8A9E, 0x30E1, 0x30E2)) + '.txt')
    ('03-unicode\' + (New-Text @(0x00C4)) + 'nderungen ' + (New-Text @(0x00FC)) + 'ber.txt')
    ('03-unicode\caf' + (New-Text @(0x00E9)) + ' r' + (New-Text @(0x00E9)) + 'sum' + (New-Text @(0x00E9)) + '.txt')

    # 04 - nesting, for depth vs regex
    '04-depth\level1\shallow.txt'
    '04-depth\level1\level2\level3\level4\deep.txt'

    # 05 - entries the default "Skip folders" already hides
    '05-skipped\node_modules\pkg\index.js'
    '05-skipped\.git\config'
    '05-skipped\bin\Debug\app.pdb'
    '05-skipped\packages\app.nupkg'

    # root-level path fixtures
    'Projects\2024\invoice.pdf'
    'Projects\2024\budget.xlsx'
    'Projects\2025\invoice.pdf'
    'Archive\Projects\2024\invoice.pdf'
    'Archive\notes.txt'
)

foreach ($relative in $files) { New-Fixture $relative }

# Empty on purpose: it proves empty folders are listed and can be renamed.
New-Folder '06-empty\EmptyFolder'

$fileCount = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File).Count
$folderCount = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory).Count
Write-Host ("Created {0} files and {1} folders under {2}" -f $fileCount, $folderCount, $Path)
Write-Host 'See RegexTest.md for the patterns and their expected row counts.'
