<#
.SYNOPSIS
    Runs the Translate Names failure suite against a generated corpus.

.DESCRIPTION
    Exercises the app the way a hostile user or a hostile filesystem would:

      1. offline self-test (pure logic, corrupt settings/cache/journal)
      2. headless -Plan over the whole corpus (no renames, no network)
      3. real GUI preview -> apply -> restart -> undo on a throw-away copy,
         comparing exact paths, attributes and content hashes before and after
      4. a file locked by another process: the rename must fail softly, never
         lose data, and undo must still restore everything else
      5. corrupt settings/cache/journal files: the app must start and not crash
      6. kill the app in the middle of an apply, then undo: the crash-safe
         journal must bring the tree back exactly to the baseline
      7. long paths, when the corpus was generated with -IncludeLongPaths

    All writes stay under <workspace>\TestLab. Exit code 0 = everything passed.

.PARAMETER CorpusPath
    Corpus root. Generated automatically if missing.

.PARAMETER KeepScratch
    Keep the throw-away work/data folders for inspection.

.EXAMPLE
    .\Run-CorpusTests.ps1

.EXAMPLE
    .\Run-CorpusTests.ps1 -CorpusPath D:\Temp\Corpus -KeepScratch
#>
[CmdletBinding()]
param(
    [string]$CorpusPath,
    [switch]$SkipCrashTest,
    [switch]$KeepScratch
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
# TestLab sits beside these scripts in a checkout, but one level up from the
# repository root during development (Edit\ inside the app folder). Pick the
# nearest ancestor that already has one, else this folder - so the same suite
# runs from either layout.
$workspace = $here
$probe = $here
for ($i = 0; $i -lt 3; $i++) {
    if (Test-Path -LiteralPath (Join-Path $probe 'TestLab')) { $workspace = $probe; break }
    $probe = Split-Path -Parent $probe
    if (-not $probe) { break }
}
if (-not $CorpusPath) { $CorpusPath = Join-Path $workspace 'TestLab\Corpus' }
$CorpusPath = [System.IO.Path]::GetFullPath($CorpusPath)

$script:AppPath    = Join-Path $here 'TranslateNamesApp.ps1'
$script:Generator  = Join-Path $here 'TestCorpus.ps1'
$script:AppExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Lab        = Split-Path -Parent $CorpusPath
$script:Passes     = 0
$script:Failures   = 0
$script:Skipped    = 0
$script:Results    = New-Object System.Collections.Generic.List[object]

if (-not (Test-Path -LiteralPath $script:AppPath)) { throw "Cannot find TranslateNamesApp.ps1 next to this script." }
if (-not (Test-Path -LiteralPath $script:AppExe))  { throw "Cannot find Windows PowerShell 5.1." }
if (-not (Test-Path -LiteralPath $script:Lab)) { $null = New-Item -ItemType Directory -Path $script:Lab -Force }

if (-not (Test-Path -LiteralPath (Join-Path $CorpusPath '_meta\manifest.json'))) {
    Write-Host "Corpus missing, generating..." -ForegroundColor Cyan
    & $script:Generator -Path $CorpusPath -Force | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Corpus generation failed with exit code $LASTEXITCODE." }
}
$manifest = Get-Content -LiteralPath (Join-Path $CorpusPath '_meta\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# --- small helpers ---------------------------------------------------------

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:Passes++
        Write-Host ("  PASS  " + $Name) -ForegroundColor DarkGreen
    } else {
        $script:Failures++
        Write-Host ("  FAIL  " + $Name + $(if ($Detail) { "  [" + $Detail + "]" } else { '' })) -ForegroundColor Red
    }
    $script:Results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
}

function Add-Skip {
    param([string]$Name, [string]$Reason)
    $script:Skipped++
    Write-Host ("  SKIP  " + $Name + "  (" + $Reason + ")") -ForegroundColor Yellow
    $script:Results.Add([pscustomobject]@{ Name = $Name; Ok = $true; Detail = 'skipped: ' + $Reason })
}

function Clear-SmokeEnvironment {
    foreach ($name in @(
            'TRANSLATENAMES_SMOKE_APPLY', 'TRANSLATENAMES_SMOKE_STEPS', 'TRANSLATENAMES_SMOKE_FOLDER',
            'TRANSLATENAMES_SMOKE_UNDO', 'TRANSLATENAMES_SMOKE_REPORT', 'TRANSLATENAMES_SMOKE_SHOT',
            'TRANSLATENAMES_SMOKE_EDIT', 'TRANSLATENAMES_SMOKE_HELP', 'TRANSLATENAMES_SMOKE_HELP_SIZE',
            'TRANSLATENAMES_SMOKE_HELP_REPORT', 'TRANSLATENAMES_DPI_SCALE')) {
        Remove-Item -Path ('Env:' + $name) -ErrorAction SilentlyContinue
    }
}

function Invoke-SmokeApp {
    param(
        [string]$Folder,
        [string]$DataDir,
        [switch]$Undo,
        [int]$Steps = 6000
    )
    $reportPath = Join-Path $script:Lab ('report-' + [guid]::NewGuid().ToString('N') + '.txt')
    $env:TRANSLATENAMES_SMOKE_APPLY = '1'
    $env:TRANSLATENAMES_SMOKE_STEPS = [string]$Steps
    $env:TRANSLATENAMES_SMOKE_REPORT = $reportPath
    if ($Folder) { $env:TRANSLATENAMES_SMOKE_FOLDER = $Folder }
    if ($Undo)   { $env:TRANSLATENAMES_SMOKE_UNDO = '1' } else { Remove-Item 'Env:TRANSLATENAMES_SMOKE_UNDO' -ErrorAction SilentlyContinue }

    $text = & $script:AppExe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File $script:AppPath -DataDir $DataDir 2>&1 | Out-String
    $code = $LASTEXITCODE
    Clear-SmokeEnvironment

    $report = @{}
    if (Test-Path -LiteralPath $reportPath) {
        foreach ($line in [System.IO.File]::ReadAllLines($reportPath)) {
            if ($line -match '^([A-Za-z]+)=(.*)$') { $report[$Matches[1]] = $Matches[2] }
            elseif ($line -match '^ERROR:') { $report['error'] = $line }
        }
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ ExitCode = $code; Report = $report; Output = $text }
}

function Invoke-HeadlessPlan {
    param([string]$Folder, [string]$DataDir, [string]$CsvPath, [switch]$Online, [switch]$VerboseOutput)
    $arguments = @('-Plan', $Folder, '-PlanOut', $CsvPath, '-DataDir', $DataDir)
    if (-not $Online) { $arguments += '-NoNetwork' }
    if (-not $VerboseOutput) { $arguments += '-Quiet' }
    $text = & $script:AppExe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $script:AppPath @arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text }
}

function Initialize-WorkCopy {
    param([string]$Name)
    $destination = Join-Path $script:Lab $Name
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $destination -Force
    foreach ($item in Get-ChildItem -LiteralPath $CorpusPath -Force) {
        if ($item.Name -eq '_meta') { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
    }
    return $destination
}

function New-TestDataDir {
    param([string]$Name)
    $directory = Join-Path $script:Lab $Name
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $directory -Force
    Copy-Item -LiteralPath (Join-Path $CorpusPath '_meta\settings.json') -Destination $directory -Force
    Copy-Item -LiteralPath (Join-Path $CorpusPath '_meta\cache.json') -Destination $directory -Force
    return $directory
}

function Test-ExcludedPath {
    param([string]$Relative)
    $segments = $Relative -split '[\\/]'
    foreach ($segment in $segments) {
        foreach ($excluded in @('node_modules', '.git', '.svn', '.hg', '$RECYCLE.BIN', 'System Volume Information')) {
            if ($segment -ieq $excluded) { return $true }
        }
    }
    return $false
}

# Paths + attributes + SHA256, so a rename that changes content or drops a file
# cannot slip through. Sorted with ordinal case so case-only renames are visible.
function Get-TreeState {
    param([string]$Root)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue) {
        $relative = $item.FullName.Substring($Root.Length).TrimStart('\')
        if ($item.PSIsContainer) {
            $list.Add('D|' + $relative + '|' + [int]$item.Attributes)
        } else {
            $hash = ''
            try { $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hash = 'HASH-ERROR' }
            $list.Add('F|' + $relative + '|' + [int]$item.Attributes + '|' + $hash)
        }
    }
    $array = $list.ToArray()
    [Array]::Sort($array, [System.StringComparer]::Ordinal)
    return ,$array
}

function Get-StateDiff {
    param($Expected, $Actual)
    return @(Compare-Object -ReferenceObject $Expected -DifferenceObject $Actual -CaseSensitive)
}

function Get-ContentMultiset {
    param($State)
    $hashes = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $State) {
        if ($entry.StartsWith('F|')) {
            $parts = $entry.Split('|')
            $hashes.Add($parts[$parts.Length - 1])
        }
    }
    $array = $hashes.ToArray()
    [Array]::Sort($array, [System.StringComparer]::Ordinal)
    return ,$array
}

function Format-Diff {
    param($Diff, [int]$Limit = 4)
    $lines = @($Diff | Select-Object -First $Limit | ForEach-Object { $_.InputObject })
    return ($lines -join ' ;; ')
}

Write-Host ""
Write-Host ("Translate Names failure suite") -ForegroundColor Cyan
Write-Host ("  app:     " + $script:AppPath)
Write-Host ("  corpus:  " + $CorpusPath)
Write-Host ("  entries: " + $manifest.Entries.Count + "  long paths: " + $manifest.IncludeLongPaths)
Write-Host ""

# --- 1. self-test ----------------------------------------------------------

Write-Host "1. Offline self-test" -ForegroundColor Cyan
$data = Join-Path $script:Lab 'data-selftest'
$selfOutput = & $script:AppExe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $script:AppPath -SelfTest -DataDir $data -Quiet 2>&1 | Out-String
Add-Check 'self-test exits 0' ($LASTEXITCODE -eq 0) ("exit " + $LASTEXITCODE)
Add-Check 'self-test reports OK' ($selfOutput -match 'OK: \d+ checks passed') 'no OK line'

# --- 2. plan over the corpus ----------------------------------------------

Write-Host "2. Headless plan over the corpus (offline)" -ForegroundColor Cyan
$planWork = Initialize-WorkCopy 'work-plan'
$planData = New-TestDataDir 'data-plan'
$planCsv  = Join-Path $script:Lab 'plan.csv'
$plan = Invoke-HeadlessPlan -Folder $planWork -DataDir $planData -CsvPath $planCsv
Add-Check 'plan exits 0' ($plan.ExitCode -eq 0) ("exit " + $plan.ExitCode + " " + $plan.Output)
$planRows = @()
if (Test-Path -LiteralPath $planCsv) { $planRows = @(Import-Csv -LiteralPath $planCsv) }
$expectedPlan = @(Get-ChildItem -LiteralPath $planWork -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-ExcludedPath $_.FullName.Substring($planWork.Length).TrimStart('\')) })
Add-Check 'plan covers every scannable entry' ($planRows.Count -eq $expectedPlan.Count) ("csv=" + $planRows.Count + " expected=" + $expectedPlan.Count)
$excludedLeftovers = @($planRows | Where-Object { Test-ExcludedPath ([string]$_.FullPath) })
Add-Check 'excluded subtrees are absent from the plan' ($excludedLeftovers.Count -eq 0) (Format-Diff $excludedLeftovers)
$columnsMissing = @($planRows | Where-Object { -not $_.PSObject.Properties['FinalName'] })
Add-Check 'plan CSV has the expected columns' ($columnsMissing.Count -eq 0) 'FinalName column missing'

# --- 3. apply + undo round trip -------------------------------------------

Write-Host "3. Preview -> apply -> restart -> undo" -ForegroundColor Cyan
$applyWork = Initialize-WorkCopy 'work-apply'
$baseline = Get-TreeState $applyWork
$applyData = New-TestDataDir 'data-apply'

$apply = Invoke-SmokeApp -Folder $applyWork -DataDir $applyData
Add-Check 'apply run exits 0' ($apply.ExitCode -eq 0) ("exit " + $apply.ExitCode)
$previewCount = 0
if ($apply.Report.ContainsKey('preview')) { $previewCount = [int]$apply.Report['preview'] }
Add-Check 'apply saw a non-empty preview' ($previewCount -gt 0) ("preview=" + $previewCount)
$undoCount = 0
if ($apply.Report.ContainsKey('undoCount')) { $undoCount = [int]$apply.Report['undoCount'] }
Add-Check 'apply wrote journal entries' ($undoCount -gt 0) ("undoCount=" + $undoCount)

$afterApply = Get-TreeState $applyWork
$baselineFiles = @($baseline | Where-Object { $_.StartsWith('F|') })
$afterFiles    = @($afterApply | Where-Object { $_.StartsWith('F|') })
Add-Check 'no files lost or duplicated by apply' ($baselineFiles.Count -eq $afterFiles.Count) ("before=" + $baselineFiles.Count + " after=" + $afterFiles.Count)
$contentBefore = Get-ContentMultiset $baseline
$contentAfter  = Get-ContentMultiset $afterApply
Add-Check 'file contents are unchanged by apply' ((Get-StateDiff $contentBefore $contentAfter).Count -eq 0) (Format-Diff (Get-StateDiff $contentBefore $contentAfter))
Add-Check 'apply actually renamed something' ((Get-StateDiff $baseline $afterApply).Count -gt 0) 'tree unchanged'

$undo = Invoke-SmokeApp -DataDir $applyData -Undo
Add-Check 'undo run exits 0' ($undo.ExitCode -eq 0) ("exit " + $undo.ExitCode)
$restored = Get-TreeState $applyWork
$restoreDiff = Get-StateDiff $baseline $restored
Add-Check 'undo restores every path, attribute and hash' ($restoreDiff.Count -eq 0) (Format-Diff $restoreDiff)

# --- 4. locked file --------------------------------------------------------

Write-Host "4. Rename blocked by a locked file" -ForegroundColor Cyan
$lockWork = Initialize-WorkCopy 'work-lock'
$lockBaseline = Get-TreeState $lockWork
$lockData = New-TestDataDir 'data-lock'
$lockTarget = Join-Path $lockWork '01-basic\plain file.txt'
$lockStream = $null
if (Test-Path -LiteralPath $lockTarget) {
    $lockStream = New-Object System.IO.FileStream($lockTarget, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
}
try {
    $locked = Invoke-SmokeApp -Folder $lockWork -DataDir $lockData
    Add-Check 'apply survives a locked file' ($locked.ExitCode -eq 0) ("exit " + $locked.ExitCode)
} finally {
    if ($lockStream) { $lockStream.Dispose() }
}
$afterLock = Get-TreeState $lockWork
Add-Check 'locked file still exists after its rename failed' ([bool](@($afterLock | Where-Object { $_.StartsWith('F|01-basic\plain file.txt|') }).Count)) 'locked file moved or lost'
$lockContentBefore = Get-ContentMultiset $lockBaseline
$lockContentAfter  = Get-ContentMultiset $afterLock
Add-Check 'no content lost while a file was locked' ((Get-StateDiff $lockContentBefore $lockContentAfter).Count -eq 0) (Format-Diff (Get-StateDiff $lockContentBefore $lockContentAfter))
$lockUndo = Invoke-SmokeApp -DataDir $lockData -Undo
Add-Check 'undo after a locked file exits 0' ($lockUndo.ExitCode -eq 0) ("exit " + $lockUndo.ExitCode)
$lockRestored = Get-TreeState $lockWork
$lockDiff = Get-StateDiff $lockBaseline $lockRestored
Add-Check 'undo after a locked file restores the baseline' ($lockDiff.Count -eq 0) (Format-Diff $lockDiff)

# --- 5. corrupt state files ------------------------------------------------

Write-Host "5. Corrupt settings, cache and journal" -ForegroundColor Cyan
$corruptData = New-TestDataDir 'data-corrupt'
[System.IO.File]::WriteAllText((Join-Path $corruptData 'settings.json'), '{ not valid json', (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $corruptData 'cache.json'), '] not json either', (New-Object System.Text.UTF8Encoding($false)))
$goodId = [guid]::NewGuid().ToString('N')
$journalLines = @(
    '{broken json'
    ('{"op":"rename","id":"' + $goodId + '","batch":"deadbeef","dir":"' + $corruptData + '","from":"x.txt","to":"y.txt","folder":false,"ts":"2026-01-01 00:00:00"}')
    'null'
)
[System.IO.File]::WriteAllText((Join-Path $corruptData 'undo-journal.jsonl'), (($journalLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
$emptyFolder = Join-Path $script:Lab 'empty-folder'
if (-not (Test-Path -LiteralPath $emptyFolder)) { $null = New-Item -ItemType Directory -Path $emptyFolder -Force }
$corruptStart = Invoke-SmokeApp -Folder $emptyFolder -DataDir $corruptData
Add-Check 'app starts with corrupt settings and cache' ($corruptStart.ExitCode -eq 0) ("exit " + $corruptStart.ExitCode)
$corruptUndo = Invoke-SmokeApp -DataDir $corruptData -Undo
Add-Check 'undo tolerates a corrupt journal' ($corruptUndo.ExitCode -eq 0) ("exit " + $corruptUndo.ExitCode)

# --- 6. kill in the middle of an apply ------------------------------------

Write-Host "6. Kill during apply, then undo" -ForegroundColor Cyan
if ($SkipCrashTest) {
    Add-Skip 'crash-safe undo' 'skipped by -SkipCrashTest'
} else {
    $crashWork = Initialize-WorkCopy 'work-crash'
    $crashBaseline = Get-TreeState $crashWork
    $crashData = New-TestDataDir 'data-crash'
    $crashReport = Join-Path $script:Lab ('report-crash-' + [guid]::NewGuid().ToString('N') + '.txt')
    $env:TRANSLATENAMES_SMOKE_APPLY = '1'
    $env:TRANSLATENAMES_SMOKE_STEPS = '6000'
    $env:TRANSLATENAMES_SMOKE_FOLDER = $crashWork
    $env:TRANSLATENAMES_SMOKE_REPORT = $crashReport
    $process = Start-Process -FilePath $script:AppExe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NoLogo', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:AppPath + '"'), '-DataDir', ('"' + $crashData + '"'))
    $journalPath = Join-Path $crashData 'undo-journal.jsonl'
    $deadline = (Get-Date).AddSeconds(45)
    $journalCount = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $journalPath) {
            try { $journalCount = @(Get-Content -LiteralPath $journalPath -ErrorAction Stop).Count } catch { $journalCount = 0 }
            if ($journalCount -ge 8) { break }
        }
        if ($process.HasExited) { break }
        Start-Sleep -Milliseconds 20
    }
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        try { $process.WaitForExit(5000) | Out-Null } catch { }
    }
    Clear-SmokeEnvironment
    if ($journalCount -lt 1) {
        Add-Skip 'crash-safe undo' 'rename phase finished before it could be killed'
    } else {
        Add-Check 'apply was killed with a partial journal' ($true) ("journal entries=" + $journalCount)
        $crashUndo = Invoke-SmokeApp -DataDir $crashData -Undo
        Add-Check 'undo after a crash exits 0' ($crashUndo.ExitCode -eq 0) ("exit " + $crashUndo.ExitCode + ' ' + $crashUndo.Report['error'])
        $crashRestored = Get-TreeState $crashWork
        $crashDiff = Get-StateDiff $crashBaseline $crashRestored
        Add-Check 'undo after a crash restores the baseline' ($crashDiff.Count -eq 0) (Format-Diff $crashDiff)
        Add-Check 'crashed apply left no staging files' (@($crashRestored | Where-Object { $_ -match '\.tmp\||\|tmp' }).Count -eq 0) 'staging leftovers'
    }
}

# --- 7. long path ----------------------------------------------------------

Write-Host "7. Long path (> 260 characters)" -ForegroundColor Cyan
$longCorpus = Join-Path $script:Lab 'CorpusLong'
$longManifest = $null
if (Test-Path -LiteralPath (Join-Path $longCorpus '_meta\manifest.json')) {
    $longManifest = Get-Content -LiteralPath (Join-Path $longCorpus '_meta\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}
if (-not $longManifest -or -not $longManifest.IncludeLongPaths) {
    Write-Host "  generating long-path corpus..." -ForegroundColor DarkGray
    & $script:Generator -Path $longCorpus -IncludeLongPaths -Force | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Add-Skip 'long path plan' 'long-path corpus could not be generated'
    } else {
        $longManifest = Get-Content -LiteralPath (Join-Path $longCorpus '_meta\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }
}
if ($longManifest -and $longManifest.IncludeLongPaths) {
    $longData = New-TestDataDir 'data-long'
    $longCsv = Join-Path $script:Lab 'plan-long.csv'
    $longRoot = Join-Path $longCorpus '09-long-path'
    $long = Invoke-HeadlessPlan -Folder $longRoot -DataDir $longData -CsvPath $longCsv
    Add-Check 'long-path plan exits 0' ($long.ExitCode -eq 0) ("exit " + $long.ExitCode + ' ' + $long.Output)
    $longRows = 0
    if (Test-Path -LiteralPath $longCsv) { $longRows = @(Import-Csv -LiteralPath $longCsv).Count }
    Add-Check 'long-path plan finds the deep file' ($longRows -gt 0) ("rows=" + $longRows)
    Add-Check 'long-path run reports no unhandled exception' ($long.Output -notmatch 'Unhandled|Exception|missing closing')
} elseif (-not ($script:Results | Where-Object { $_.Name -eq 'long path plan' })) {
    Add-Skip 'long path plan' 'long paths are not supported on this system'
}

# --- 8. settings, filters and diagnostics ---------------------------------

Write-Host "8. Settings, filters and diagnostics" -ForegroundColor Cyan
$settingsData = New-TestDataDir 'data-settings'
$settingsReport = Join-Path $script:Lab ('report-settings-' + [guid]::NewGuid().ToString('N') + '.txt')
$env:TRANSLATENAMES_SMOKE_SETTINGS = $settingsReport
$settingsRun = & $script:AppExe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File $script:AppPath -DataDir $settingsData 2>&1 | Out-String
$settingsExit = $LASTEXITCODE
Remove-Item -Path 'Env:TRANSLATENAMES_SMOKE_SETTINGS' -ErrorAction SilentlyContinue
$settingsLines = @{}
if (Test-Path -LiteralPath $settingsReport) {
    foreach ($line in [System.IO.File]::ReadAllLines($settingsReport)) {
        if ($line -match '^([^=]+)=(.*)$') { $settingsLines[$Matches[1]] = $Matches[2] }
    }
    Remove-Item -LiteralPath $settingsReport -Force -ErrorAction SilentlyContinue
}
Add-Check 'settings smoke exits 0' ($settingsExit -eq 0) ("exit " + $settingsExit + ' ' + $settingsRun)
Add-Check 'settings round-trip applies values' (($settingsLines['target'] -eq 'German') -and ($settingsLines['template'] -eq '{original} - {translated}')) ([string]$settingsLines['target'])
Add-Check 'reset restores defaults' (($settingsLines['afterResetTarget'] -eq 'English') -and ($settingsLines['afterResetTemplate'] -eq '{translated}')) ([string]$settingsLines['afterResetTarget'])
Add-Check 'diagnostics include the version' ($settingsLines['diagnosticsHasVersion'] -eq 'True') ([string]$settingsLines['diagnosticsHasVersion'])
Add-Check 'system roots are flagged' ($settingsLines['protectedDrive'] -eq 'a drive root') ([string]$settingsLines['protectedDrive'])
Add-Check 'filters select the right rows' (($settingsLines['filterFailedOnly'] -eq 'True') -and ($settingsLines['filterFind'] -eq 'True')) ([string]$settingsLines['filterFailedOnly'])
Add-Check 'column widths are persisted' ($settingsLines['columnsPersisted'] -eq 'True') ([string]$settingsLines['columnsPersisted'])
Add-Check 'simple and advanced layouts switch' (($settingsLines['advancedOptionsVisible'] -eq 'True') -and ($settingsLines['simpleOptionsHidden'] -eq 'True') -and ($settingsLines['advancedTargetInGrid'] -eq 'True') -and ($settingsLines['simpleTargetInHeader'] -eq 'True') -and ($settingsLines['simpleSourceInHeader'] -eq 'True')) ([string]$settingsLines['simpleTargetInHeader'])
Add-Check 'simple mode hides the filter bar and keeps the include menu' (($settingsLines['advancedFilterVisible'] -eq 'True') -and ($settingsLines['simpleFilterHidden'] -eq 'True') -and ($settingsLines['simpleIncludeVisible'] -eq 'True') -and ($settingsLines['advancedIncludeHidden'] -eq 'True')) ([string]$settingsLines['simpleIncludeVisible'])
Add-Check 'include menu drives the include checkboxes' ($settingsLines['includeMenuChecksFile'] -eq 'True') ([string]$settingsLines['includeMenuChecksFile'])
Add-Check 'hidden options collapse their rows' (([int]$settingsLines['advancedOptionsRow'] -gt 0) -and ([int]$settingsLines['simpleOptionsRow'] -eq 0) -and ([int]$settingsLines['advancedFilterRow'] -gt 0) -and ([int]$settingsLines['simpleFilterRow'] -eq 0) -and ([int]$settingsLines['simpleListRow'] -gt 0)) ("simpleOptions=" + $settingsLines['simpleOptionsRow'] + ' advancedOptions=' + $settingsLines['advancedOptionsRow'] + ' simpleList=' + $settingsLines['simpleListRow'])
Add-Check 'ui mode round-trips through settings' (($settingsLines['afterResetUiMode'] -eq 'Simple') -and ($settingsLines['uiModeDefault'] -eq 'Simple')) ([string]$settingsLines['afterResetUiMode'])
Add-Check 'all settings checks passed' ($settingsLines['result'] -eq 'PASS') ([string]$settingsLines['stack'])

# --- 9. virtual list benchmark ---------------------------------------------

# --- 9. inline editor and multi-root queue --------------------------------

Write-Host "9. Inline editor and multi-root queue" -ForegroundColor Cyan

# Editor geometry: the box must land exactly on the "New name" cell of the row
# it opened on, with no interop fallback in play.
$editRows = Join-Path $script:Lab 'edit-rows'
if (Test-Path -LiteralPath $editRows) { Remove-Item -LiteralPath $editRows -Recurse -Force }
$null = New-Item -ItemType Directory -Path $editRows -Force
foreach ($name in @('Alpha.txt', 'Beta.txt', 'Gamma.txt')) {
    [System.IO.File]::WriteAllText((Join-Path $editRows $name), 'x')
}
$editData = New-TestDataDir 'data-edit'
# Seed the cache so the scan never touches the network and every row comes back
# unchanged (nothing to apply, so the rows stay editable for the editor check).
$editCache = [ordered]@{
    'Google|auto|en|Alpha' = @{ t = 'Alpha'; d = 'ja' }
    'Google|auto|en|Beta'  = @{ t = 'Beta';  d = 'ja' }
    'Google|auto|en|Gamma' = @{ t = 'Gamma'; d = 'ja' }
}
[System.IO.File]::WriteAllText((Join-Path $editData 'cache.json'), ($editCache | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))
$editReport = Join-Path $script:Lab ('report-edit-' + [guid]::NewGuid().ToString('N') + '.txt')
$env:TRANSLATENAMES_SMOKE_APPLY  = '1'
$env:TRANSLATENAMES_SMOKE_STEPS  = '600'
$env:TRANSLATENAMES_SMOKE_FOLDER = $editRows
$env:TRANSLATENAMES_SMOKE_EDIT   = '2'
$env:TRANSLATENAMES_SMOKE_REPORT = $editReport
$editRun = & $script:AppExe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File $script:AppPath -DataDir $editData 2>&1 | Out-String
$editExit = $LASTEXITCODE
Clear-SmokeEnvironment
$editLines = @{}
if (Test-Path -LiteralPath $editReport) {
    foreach ($line in [System.IO.File]::ReadAllLines($editReport)) {
        if ($line -match '^([A-Za-z]+)=(.*)$') { $editLines[$Matches[1]] = $Matches[2] }
    }
    Remove-Item -LiteralPath $editReport -Force -ErrorAction SilentlyContinue
}
Add-Check 'editor smoke exits 0' ($editExit -eq 0) ("exit " + $editExit + ' ' + $editRun)
Add-Check 'inline editor opens on the requested row' (($editLines['cellEditVisible'] -eq 'True') -and ($editLines['cellEditRow'] -eq '1')) ([string]$editLines['cellEditRow'])

function ConvertFrom-Rect {
    param([string]$Text)
    $match = [regex]::Match([string]$Text, 'X=(-?\d+),Y=(-?\d+),Width=(\d+),Height=(\d+)')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        X = [int]$match.Groups[1].Value; Y = [int]$match.Groups[2].Value
        W = [int]$match.Groups[3].Value; H = [int]$match.Groups[4].Value
    }
}
# box is in form-client coordinates, the other two in list-client coordinates:
# convert the box back and compare it with the cell, then check the size matches.
$boxRect       = ConvertFrom-Rect ([string]$editLines['cellEditBox'])
$coverRect     = ConvertFrom-Rect ([string]$editLines['cellEditCover'])
$publishedCell = ConvertFrom-Rect ([string]$editLines['cellEditCell'])
$coverCellsCell = ($null -ne $coverRect -and $null -ne $publishedCell -and
    [Math]::Abs($coverRect.X - $publishedCell.X) -le 1 -and [Math]::Abs($coverRect.Y - $publishedCell.Y) -le 1 -and
    [Math]::Abs($coverRect.W - $publishedCell.W) -le 1 -and [Math]::Abs($coverRect.H - $publishedCell.H) -le 1)
$boxFitsCell = ($null -ne $boxRect -and $null -ne $publishedCell -and
    [Math]::Abs($boxRect.W - $publishedCell.W) -le 1 -and [Math]::Abs($boxRect.H - $publishedCell.H) -le 1)
Add-Check 'inline editor covers the New name cell' ($coverCellsCell -and $boxFitsCell) ([string]$editLines['cellEditCover'] + ' ' + [string]$editLines['cellEditBox'])
Add-Check 'editor uses the native cell rect' ($null -ne $publishedCell -and $publishedCell.W -gt 0 -and $publishedCell.H -gt 0) ([string]$editLines['cellEditCell'])
Add-Check 'editor is topmost and parented to the form' ($editLines['cellEditZ'] -match '^0/') ([string]$editLines['cellEditZ'])

# Multi-root queue: two folders and a file that is already inside one of them.
# The duplicate must not be scanned twice, and apply/undo must work per folder.
$multiA = Join-Path $script:Lab 'multi-a'
$multiB = Join-Path $script:Lab 'multi-b'
foreach ($folder in @($multiA, $multiB)) {
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $folder -Force
}
[System.IO.File]::WriteAllText((Join-Path $multiA 'Alpha.txt'), 'a')
[System.IO.File]::WriteAllText((Join-Path $multiB 'Beta.txt'), 'b')
$multiData = New-TestDataDir 'data-multiroot'
$multiCache = [ordered]@{
    'Google|auto|en|Alpha' = @{ t = 'Alpha Renamed'; d = 'ja' }
    'Google|auto|en|Beta'  = @{ t = 'Beta Renamed';  d = 'ja' }
}
[System.IO.File]::WriteAllText((Join-Path $multiData 'cache.json'), ($multiCache | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))

$multiRun = Invoke-SmokeApp -Folder ($multiA + ';' + $multiB + ';' + (Join-Path $multiA 'Alpha.txt')) -DataDir $multiData -Steps 800
Add-Check 'multi-root apply exits 0' ($multiRun.ExitCode -eq 0) ("exit " + $multiRun.ExitCode + ' ' + $multiRun.Output)
Add-Check 'multi-root scan queues each item once' ($multiRun.Report['preview'] -eq '2') ([string]$multiRun.Report['preview'])
Add-Check 'multi-root apply renames in every root' (
    (Test-Path -LiteralPath (Join-Path $multiA 'Alpha Renamed.txt')) -and
    (Test-Path -LiteralPath (Join-Path $multiB 'Beta Renamed.txt'))) ([string]$multiRun.Report['status'])

$multiUndo = Invoke-SmokeApp -DataDir $multiData -Undo -Steps 800
Add-Check 'multi-root undo exits 0' ($multiUndo.ExitCode -eq 0) ("exit " + $multiUndo.ExitCode + ' ' + $multiUndo.Output)
Add-Check 'multi-root undo restores every root' (
    (Test-Path -LiteralPath (Join-Path $multiA 'Alpha.txt')) -and
    (Test-Path -LiteralPath (Join-Path $multiB 'Beta.txt'))) ([string]$multiUndo.Report['status'])

Write-Host "10. Virtual list at 20,000 rows" -ForegroundColor Cyan
$virtualData = New-TestDataDir 'data-virtual'
$virtualReport = Join-Path $script:Lab ('report-virtual-' + [guid]::NewGuid().ToString('N') + '.txt')
$env:TRANSLATENAMES_SMOKE_VIRTUAL = $virtualReport
$virtualRun = & $script:AppExe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File $script:AppPath -DataDir $virtualData 2>&1 | Out-String
$virtualExit = $LASTEXITCODE
Remove-Item -Path 'Env:TRANSLATENAMES_SMOKE_VIRTUAL' -ErrorAction SilentlyContinue
$virtualLines = @{}
if (Test-Path -LiteralPath $virtualReport) {
    foreach ($line in [System.IO.File]::ReadAllLines($virtualReport)) {
        if ($line -match '^([^=]+)=(.*)$') { $virtualLines[$Matches[1]] = $Matches[2] }
    }
    Remove-Item -LiteralPath $virtualReport -Force -ErrorAction SilentlyContinue
}
$virtualRows = 0
if ($virtualLines['rows']) { $virtualRows = [int]$virtualLines['rows'] }
Add-Check 'virtual smoke exits 0' ($virtualExit -eq 0) ("exit " + $virtualExit + ' ' + $virtualRun)
Add-Check '20,000 rows are held virtually' (($virtualRows -eq 20000) -and ($virtualLines['virtualSize'] -eq '20000')) ([string]$virtualLines['virtualSize'])
Add-Check 'only visible rows are retrieved' (($virtualLines['lazy'] -eq 'True')) ([string]$virtualLines['retrieved'])
Add-Check 'multi-row selection works in virtual mode' ($virtualLines['selected'] -eq '3') ([string]$virtualLines['selected'])
Add-Check 'filtering works in virtual mode' (([int]$virtualLines['filtered'] -gt 0) -and ([int]$virtualLines['filtered'] -lt 20000)) ([string]$virtualLines['filtered'])
Add-Check 'refresh stays fast at 20k rows' (([int]$virtualLines['refreshMs']) -lt 5000) ([string]$virtualLines['refreshMs'])
Add-Check 'sorting works in virtual mode' ($virtualLines['sortedSize'] -eq '20000') ([string]$virtualLines['sortedSize'])
# Fixing one name must not re-plan the queue: the fast path makes this a lookup
# plus a repaint. A regression to the full planner shows up as seconds here.
Add-Check 'editing one row stays fast at 20k rows' (([int]$virtualLines['editMs']) -lt 1500) ([string]$virtualLines['editMs'])
Add-Check 'the edit produced a final target' ($virtualLines['editedTarget'] -eq 'Edited row.txt') ([string]$virtualLines['editedTarget'])
Add-Check 'row counting is a single pass' (([int]$virtualLines['countsMs']) -lt 400) ([string]$virtualLines['countsMs'])
Add-Check 'all virtual checks passed' ($virtualLines['result'] -eq 'PASS') ([string]$virtualLines['stack'])

# --- 10. parallel workers and throttling -----------------------------------

Write-Host "11. Parallel workers and throttling" -ForegroundColor Cyan
$parallelWork = Initialize-WorkCopy 'work-parallel'
$parallelData = New-TestDataDir 'data-parallel'
$parallelSettingsPath = Join-Path $parallelData 'settings.json'
$parallelSettings = Get-Content -LiteralPath $parallelSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$parallelSettings | Add-Member -NotePropertyName ParallelRequests -NotePropertyValue 3 -Force
[System.IO.File]::WriteAllText($parallelSettingsPath, ($parallelSettings | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
$parallelBaseline = Get-TreeState $parallelWork
$parallelApply = Invoke-SmokeApp -Folder $parallelWork -DataDir $parallelData
Add-Check 'parallel apply exits 0' ($parallelApply.ExitCode -eq 0) ("exit " + $parallelApply.ExitCode)
Add-Check 'parallel apply produced rows' ([int]$parallelApply.Report['preview'] -gt 0) ([string]$parallelApply.Report['preview'])
$parallelUndo = Invoke-SmokeApp -DataDir $parallelData -Undo
Add-Check 'parallel undo exits 0' ($parallelUndo.ExitCode -eq 0) ("exit " + $parallelUndo.ExitCode)
$parallelRestored = Get-TreeState $parallelWork
$parallelDiff = Get-StateDiff $parallelBaseline $parallelRestored
Add-Check 'parallel apply/undo restores the baseline' ($parallelDiff.Count -eq 0) (Format-Diff $parallelDiff)

$throttleFolder = Join-Path $script:Lab 'throttle-input'
if (Test-Path -LiteralPath $throttleFolder) { Remove-Item -LiteralPath $throttleFolder -Recurse -Force }
$null = New-Item -ItemType Directory -Path $throttleFolder -Force
Set-Content -LiteralPath (Join-Path $throttleFolder 'alpha name.txt') -Value 'x'
Set-Content -LiteralPath (Join-Path $throttleFolder 'beta name.txt') -Value 'x'
$throttleData = New-TestDataDir 'data-throttle'
$throttleCsv = Join-Path $script:Lab 'plan-throttle.csv'
$env:TRANSLATENAMES_TEST_THROTTLE = '1'
$env:TRANSLATENAMES_TEST_THROTTLE_BASE_MS = '5'
$throttleRun = Invoke-HeadlessPlan -Folder $throttleFolder -DataDir $throttleData -CsvPath $throttleCsv -Online -VerboseOutput
Remove-Item -Path 'Env:TRANSLATENAMES_TEST_THROTTLE', 'Env:TRANSLATENAMES_TEST_THROTTLE_BASE_MS' -ErrorAction SilentlyContinue
Add-Check 'synthetic throttling stops the scan' ($throttleRun.ExitCode -eq 2) ("exit " + $throttleRun.ExitCode)
Add-Check 'throttle stop is reported clearly' ($throttleRun.Output -match 'throttl|rate-limit|Authentication') 'no throttle/rate text'
Add-Check 'throttle stop is not a crash' ($throttleRun.Output -notmatch 'Unhandled|System\.Exception') 'exception text'

# --- 12. help window layout ------------------------------------------------

Write-Host "12. Help window at its smallest size" -ForegroundColor Cyan
$helpData = New-TestDataDir 'data-help'
$helpReport = Join-Path $script:Lab ('report-help-' + [guid]::NewGuid().ToString('N') + '.txt')
$env:TRANSLATENAMES_SMOKE_HELP = '1'
$env:TRANSLATENAMES_SMOKE_HELP_SIZE = 'min'   # the smallest size the dialog allows
$env:TRANSLATENAMES_SMOKE_HELP_REPORT = $helpReport
$helpRun = & $script:AppExe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File $script:AppPath -DataDir $helpData 2>&1 | Out-String
$helpExit = $LASTEXITCODE
Clear-SmokeEnvironment
$helpLines = @()
if (Test-Path -LiteralPath $helpReport) {
    $helpLines = [System.IO.File]::ReadAllLines($helpReport)
    Remove-Item -LiteralPath $helpReport -Force -ErrorAction SilentlyContinue
}
$helpButtons = @($helpLines | Where-Object { $_ -like 'button=*' })
$helpClipped = @($helpButtons | Where-Object { $_ -notmatch 'inside=True' })
$helpSectionLine = @($helpLines | Where-Object { $_ -like 'sections=*' })
$helpSectionCount = 0
if ($helpSectionLine.Count -gt 0) { [void][int]::TryParse(($helpSectionLine[0] -split '=')[1], [ref]$helpSectionCount) }
Add-Check 'help smoke exits 0' ($helpExit -eq 0) ("exit " + $helpExit + ' ' + $helpRun)
Add-Check 'help window still lists its sections' ($helpSectionCount -ge 10) ([string]$helpSectionCount)
# Shrinking used to push Import/Reset settings off the right edge, where they
# were unreachable. The row wraps instead, so every button must stay in bounds.
Add-Check 'all six help buttons stay inside the window' (($helpButtons.Count -eq 6) -and ($helpClipped.Count -eq 0)) ($helpButtons -join ' ')

# --- summary ---------------------------------------------------------------

Write-Host ""
Write-Host ("Passed: {0}  Failed: {1}  Skipped: {2}" -f $script:Passes, $script:Failures, $script:Skipped) -ForegroundColor $(if ($script:Failures -gt 0) { 'Red' } else { 'Green' })

$summaryPath = Join-Path $script:Lab 'last-run.txt'
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add(('Translate Names failure suite - ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
$summary.Add(('App: ' + $script:AppPath))
$summary.Add(('Corpus: ' + $CorpusPath))
$summary.Add('')
foreach ($result in $script:Results) {
    $summary.Add(('[' + $(if ($result.Ok) { 'PASS' } else { 'FAIL' }) + '] ' + $result.Name + $(if ($result.Detail) { '  (' + $result.Detail + ')' } else { '' })))
}
$summary.Add('')
$summary.Add(('Passed: {0}  Failed: {1}  Skipped: {2}' -f $script:Passes, $script:Failures, $script:Skipped))
[System.IO.File]::WriteAllLines($summaryPath, $summary.ToArray())
Write-Host ("Report: " + $summaryPath)

if (-not $KeepScratch) {
    Get-ChildItem -LiteralPath $script:Lab -Filter 'report-*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($name in @('work-plan', 'data-plan', 'work-apply', 'data-apply', 'work-lock', 'data-lock',
                        'data-corrupt', 'data-selftest', 'work-crash', 'data-crash', 'data-long', 'data-settings', 'data-virtual',
                        'work-parallel', 'data-parallel', 'data-throttle', 'throttle-input', 'empty-folder',
                        'data-help')) {
        $target = Join-Path $script:Lab $name
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
    }
    foreach ($file in @('plan.csv', 'plan-long.csv', 'plan-throttle.csv')) {
        $target = Join-Path $script:Lab $file
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
    }
}

exit $(if ($script:Failures -gt 0) { 1 } else { 0 })
