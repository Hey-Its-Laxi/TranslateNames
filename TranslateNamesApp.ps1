[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InitialPath
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 12288 -bor 4096 

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

try {
    if ([System.Environment]::OSVersion.Version.Major -ge 10) {
        [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware)
    }
} catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

function Get-IsDarkMode {
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        $useLightTheme = (Get-ItemProperty -Path $regPath -Name "AppsUseLightTheme" -ErrorAction Stop).AppsUseLightTheme
        return ($useLightTheme -eq 0)
    } catch {
        return $false
    }
}

$isDark = Get-IsDarkMode
$Theme = @{
    Background   = if ($isDark) { [System.Drawing.Color]::FromArgb(32, 32, 32) } else { [System.Drawing.Color]::FromArgb(245, 245, 245) }
    Foreground   = if ($isDark) { [System.Drawing.Color]::FromArgb(240, 240, 240) } else { [System.Drawing.Color]::FromArgb(30, 30, 30) }
    ControlBack  = if ($isDark) { [System.Drawing.Color]::FromArgb(60, 60, 60) } else { [System.Drawing.Color]::White }
    ControlFore  = if ($isDark) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Black }
    UnchangedBg  = if ($isDark) { [System.Drawing.Color]::FromArgb(60, 40, 40) } else { [System.Drawing.Color]::MistyRose }
    UnchangedFg  = if ($isDark) { [System.Drawing.Color]::FromArgb(255, 180, 180) } else { [System.Drawing.Color]::DarkRed }
    SuccessBg    = if ($isDark) { [System.Drawing.Color]::FromArgb(40, 60, 40) } else { [System.Drawing.Color]::Honeydew }
    SuccessFg    = if ($isDark) { [System.Drawing.Color]::FromArgb(180, 255, 180) } else { [System.Drawing.Color]::DarkGreen }
}

Add-Type @"
using System;
using System.Collections;
using System.Windows.Forms;

public class FixedWheelNumericUpDown : NumericUpDown
{
    protected override void OnMouseEnter(EventArgs e)
    {
        base.OnMouseEnter(e);
        this.Focus();
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        if (e.Delta > 0) { UpButton(); }
        else if (e.Delta < 0) { DownButton(); }
    }
}

public class ListViewComparer : IComparer
{
    public int Column { get; set; }
    public SortOrder Order { get; set; }

    public ListViewComparer(int columnIndex, SortOrder sortOrder)
    {
        Column = columnIndex;
        Order = sortOrder;
    }

    public int Compare(object x, object y)
    {
        int result = String.Compare(((ListViewItem)x).SubItems[Column].Text, ((ListViewItem)y).SubItems[Column].Text);
        if (Order == SortOrder.Descending) { return -result; }
        return result;
    }
}
"@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

$script:cache = @{}

function Get-TranslatedText {
    param([string]$Text, [string]$From, [string]$To, [int]$DelayMs = 200)

    if ([string]::IsNullOrWhiteSpace($Text)) { 
        return [pscustomobject]@{ TranslatedText = $Text; DetectedLang = $From } 
    }

    $cacheKey = "$From|$To|$Text"
    if ($script:cache.ContainsKey($cacheKey)) { return $script:cache[$cacheKey] }

    $encoded = [uri]::EscapeDataString($Text)
    $url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=$From&tl=$To&dt=t&q=$encoded"

    foreach ($attempt in 1..3) {
        try {
            $resp = Invoke-RestMethod -Uri $url -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -TimeoutSec 15
            $translatedText = ($resp[0] | ForEach-Object { $_[0] }) -join ''
            $detected = if ($From -eq 'auto' -and $resp.Count -ge 3 -and $resp[2]) { $resp[2] } else { $From }
            $result = [pscustomobject]@{ TranslatedText = $translatedText; DetectedLang = $detected }
            
            $script:cache[$cacheKey] = $result
            if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
            return $result
        }
        catch {
            if ($attempt -eq 3) { Write-Warning "Translation failed for '$Text': $_" }
            Start-Sleep -Milliseconds ([int]([math]::Max($DelayMs, 500) * [math]::Pow(2, $attempt)))
        }
    }
    return [pscustomobject]@{ TranslatedText = $Text; DetectedLang = $From } 
}

function Get-SanitizedName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $clean = $Name
    foreach ($c in $invalid) { $clean = $clean -replace [regex]::Escape($c), '_' }
    return $clean.Trim()
}

$formWidth = 800
$formHeight = 900
$bottomMargin = 5
$statusY = $formHeight - 20 - $bottomMargin
$progBarY = $statusY - 25

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Translate Folder/File Names'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
$form.ClientSize = New-Object System.Drawing.Size($formWidth, $formHeight)
$form.MinimumSize = New-Object System.Drawing.Size(700, 500)
$form.AllowDrop = $true
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Theme.Background
$form.ForeColor = $Theme.Foreground

# Controls
$lblPath = New-Object System.Windows.Forms.Label -Property @{ Text = 'Folder:'; Location = New-Object System.Drawing.Point(10, 15); Size = New-Object System.Drawing.Size(50, 20) }
$txtPath = New-Object System.Windows.Forms.TextBox -Property @{ Location = New-Object System.Drawing.Point(65, 12); Size = New-Object System.Drawing.Size(620, 20); BackColor = $Theme.ControlBack; ForeColor = $Theme.ControlFore; Anchor = 'Top,Left,Right'; BorderStyle = 'FixedSingle' }
$btnBrowse = New-Object System.Windows.Forms.Button -Property @{ Text = 'Browse...'; Location = New-Object System.Drawing.Point(695, 10); Size = New-Object System.Drawing.Size(95, 26); Anchor = 'Top,Right'; FlatStyle = 'Flat'; BackColor = [System.Drawing.Color]::FromArgb(108, 117, 125); ForeColor = [System.Drawing.Color]::White }

# GroupBox Options
$grp = New-Object System.Windows.Forms.GroupBox -Property @{ 
    Text = '' 
    Location = New-Object System.Drawing.Point(10, 45)
    Size = New-Object System.Drawing.Size(780, 145)
    Anchor = 'Top,Left,Right'
    ForeColor = $Theme.Foreground 
}

$lblOptionsCaption = New-Object System.Windows.Forms.Label -Property @{ 
    Text = ' Options ' 
    AutoSize = $true
    BackColor = $Theme.Background 
    ForeColor = $Theme.Foreground
    Location = New-Object System.Drawing.Point(($grp.Location.X + 10), ($grp.Location.Y)) 
}

$LangMap = [ordered]@{
    'Auto-Detect' = 'auto'; 'Arabic' = 'ar'; 'Chinese (Simplified)' = 'zh-CN'; 'Chinese (Traditional)' = 'zh-TW'; 
    'Dutch' = 'nl'; 'English' = 'en'; 'French' = 'fr'; 'German' = 'de'; 'Hindi' = 'hi'; 'Italian' = 'it'; 
    'Japanese' = 'ja'; 'Korean' = 'ko'; 'Polish' = 'pl'; 'Portuguese' = 'pt'; 'Russian' = 'ru'; 
    'Spanish' = 'es'; 'Swedish' = 'sv'; 'Thai' = 'th'; 'Turkish' = 'tr'; 'Vietnamese' = 'vi'
}

$lblSrc = New-Object System.Windows.Forms.Label -Property @{ Text = 'Source language:'; Location = New-Object System.Drawing.Point(10, 28); Size = New-Object System.Drawing.Size(110, 20) }
$cmbSource = New-Object System.Windows.Forms.ComboBox -Property @{ Location = New-Object System.Drawing.Point(120, 25); Size = New-Object System.Drawing.Size(145, 20); DropDownStyle = 'DropDownList'; BackColor = $Theme.ControlBack; ForeColor = $Theme.ControlFore }
[void]$cmbSource.Items.AddRange([object[]]$LangMap.Keys)
$cmbSource.SelectedItem = 'Auto-Detect'

$lblTgt = New-Object System.Windows.Forms.Label -Property @{ Text = 'Target language:'; Location = New-Object System.Drawing.Point(275, 28); Size = New-Object System.Drawing.Size(110, 20) }
$cmbTarget = New-Object System.Windows.Forms.ComboBox -Property @{ Location = New-Object System.Drawing.Point(385, 25); Size = New-Object System.Drawing.Size(140, 20); DropDownStyle = 'DropDownList'; BackColor = $Theme.ControlBack; ForeColor = $Theme.ControlFore }
[void]$cmbTarget.Items.AddRange([object[]]$LangMap.Keys)
$cmbTarget.SelectedItem = 'English'

$chkColX = 550
$chkRowH = 22
$chkFiles         = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Include files';      AutoSize = $true; Location = New-Object System.Drawing.Point($chkColX, (26 + 0 * $chkRowH)); Checked = $true }
$chkFolders       = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Include folders';    AutoSize = $true; Location = New-Object System.Drawing.Point($chkColX, (26 + 1 * $chkRowH)); Checked = $true }
$chkRecurse       = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Include subfolders'; AutoSize = $true; Location = New-Object System.Drawing.Point($chkColX, (26 + 2 * $chkRowH)); Checked = $true }
$chkHideUnchanged = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Hide unchanged';     AutoSize = $true; Location = New-Object System.Drawing.Point($chkColX, (26 + 3 * $chkRowH)); Checked = $false }
$chkCsv           = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Write CSV log';      AutoSize = $true; Location = New-Object System.Drawing.Point($chkColX, (26 + 4 * $chkRowH)); Checked = $true }
$lblExclude = New-Object System.Windows.Forms.Label -Property @{ Text = 'Regex:'; Location = New-Object System.Drawing.Point(10, 58); AutoSize = $true }
$txtExclude = New-Object System.Windows.Forms.TextBox -Property @{ Location = New-Object System.Drawing.Point(75, 57); Size = New-Object System.Drawing.Size(455, 20); BackColor = $Theme.ControlBack; ForeColor = $Theme.ControlFore; BorderStyle = 'FixedSingle' }
$lblSkipExt = New-Object System.Windows.Forms.Label -Property @{ Text = 'Skip exts:'; Location = New-Object System.Drawing.Point(10, 85); AutoSize = $true }
$txtSkipExt = New-Object System.Windows.Forms.TextBox -Property @{ Location = New-Object System.Drawing.Point(75, 85); Size = New-Object System.Drawing.Size(455, 20); BackColor = $Theme.ControlBack; ForeColor = $Theme.ControlFore; BorderStyle = 'FixedSingle' }
$lblDelay = New-Object System.Windows.Forms.Label -Property @{ Text = 'Delay:'; Location = New-Object System.Drawing.Point(10, 113); AutoSize = $true }
$numDelay = New-Object FixedWheelNumericUpDown -Property @{ Location = New-Object System.Drawing.Point(75, 113); Size = New-Object System.Drawing.Size(80, 20); Minimum = 0; Maximum = 5000; Value = 200; Increment = 50; BackColor = $Theme.ControlBack; ForeColor = $Theme.ControlFore; BorderStyle = 'FixedSingle' }

[void]$grp.Controls.AddRange(@($lblSrc,$cmbSource,$lblTgt,$cmbTarget,$chkFiles,$chkFolders,$chkRecurse,$chkCsv,$chkHideUnchanged,$lblExclude,$txtExclude,$lblDelay,$numDelay,$lblSkipExt,$txtSkipExt))

# Action Buttons
$btnTop = $grp.Bottom + 15
$btnPreview = New-Object System.Windows.Forms.Button -Property @{ Text = '&Preview translations'; Location = New-Object System.Drawing.Point(10, $btnTop); Size = New-Object System.Drawing.Size(165, 32); FlatStyle = 'Flat'; BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); ForeColor = [System.Drawing.Color]::White }
$btnApply = New-Object System.Windows.Forms.Button -Property @{ Text = '&Apply renames'; Location = New-Object System.Drawing.Point(185, $btnTop); Size = New-Object System.Drawing.Size(165, 32); Enabled = $false; FlatStyle = 'Flat'; BackColor = [System.Drawing.Color]::FromArgb(40, 167, 69); ForeColor = [System.Drawing.Color]::White }
$btnUndo = New-Object System.Windows.Forms.Button -Property @{ Text = '&Undo last apply'; Location = New-Object System.Drawing.Point(360, $btnTop); Size = New-Object System.Drawing.Size(165, 32); Enabled = $false; FlatStyle = 'Flat'; BackColor = [System.Drawing.Color]::FromArgb(220, 53, 69); ForeColor = [System.Drawing.Color]::White }

# List View
$lvTop = $btnPreview.Bottom + 15
$lvResults = New-Object System.Windows.Forms.ListView -Property @{ Location = New-Object System.Drawing.Point(10, $lvTop); Size = New-Object System.Drawing.Size(780, ($progBarY - $lvTop - 10)); View = 'Details'; FullRowSelect = $true; GridLines = $true; Anchor = 'Top,Bottom,Left,Right'; BackColor = $Theme.ControlBack; ForeColor = $Theme.ControlFore }
[void]$lvResults.Columns.Add('Type', 61)
[void]$lvResults.Columns.Add('Detected', 90)
[void]$lvResults.Columns.Add('Original Name', 270)
[void]$lvResults.Columns.Add('New Name', 270)
[void]$lvResults.Columns.Add('Status', 85)

$ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip -Property @{ BackColor = $Theme.ControlBack; ForeColor = $Theme.ControlFore }
$menuRemove = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{ Text = 'Remove from preview'; ForeColor = $Theme.ControlFore }
[void]$ctxMenu.Items.Add($menuRemove)
$lvResults.ContextMenuStrip = $ctxMenu

# Status and Progress
$progBar = New-Object System.Windows.Forms.ProgressBar -Property @{ Location = New-Object System.Drawing.Point(10, $progBarY); Size = New-Object System.Drawing.Size(780, 15); Anchor = 'Bottom,Left,Right'; Style = 'Continuous'; Value = 0 }
$lblStatus = New-Object System.Windows.Forms.Label -Property @{ Text = 'Drag a folder onto this window, or click Browse.'; Location = New-Object System.Drawing.Point(10, $statusY); Size = New-Object System.Drawing.Size(780, 20); Anchor = 'Bottom,Left,Right' }

[void]$form.Controls.AddRange(@($lblPath,$txtPath,$btnBrowse,$grp,$lblOptionsCaption,$btnPreview,$btnApply,$btnUndo,$lvResults,$progBar,$lblStatus))
$lblOptionsCaption.BringToFront()

$script:sortColumn = -1
$script:sortOrder = [System.Windows.Forms.SortOrder]::Ascending
$script:allPreviewItems = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
$script:lastRunLog = New-Object System.Collections.Generic.List[object]

$ResetUndoState = {
    $script:lastRunLog.Clear()
    $btnUndo.Enabled = $false
}

$ResetForNewFolder = {
    $lvResults.Items.Clear()
    $script:allPreviewItems.Clear()
    & $ResetUndoState
    $btnApply.Enabled = $false
    $progBar.Value = 0
    $lblStatus.Text = 'Folder selected. Click "Preview translations" to continue.'
}

$RefreshListView = {
    if (-not $script:allPreviewItems -or $script:allPreviewItems.Count -eq 0) { return }
    $lvResults.BeginUpdate()
    $lvResults.Items.Clear()
    
    if ($chkHideUnchanged.Checked) {
        $visibleItems = $script:allPreviewItems | Where-Object { $_.SubItems[4].Text -ne 'Unchanged' }
        if ($visibleItems) { [void]$lvResults.Items.AddRange([System.Windows.Forms.ListViewItem[]]$visibleItems) }
    } else {
        [void]$lvResults.Items.AddRange($script:allPreviewItems.ToArray())
    }
    $lvResults.EndUpdate()
}

$chkHideUnchanged.Add_CheckedChanged($RefreshListView)

$lvResults.Add_ColumnClick({
    $col = $_.Column
    if ($col -eq $script:sortColumn) {
        $script:sortOrder = if ($script:sortOrder -eq [System.Windows.Forms.SortOrder]::Ascending) { [System.Windows.Forms.SortOrder]::Descending } else { [System.Windows.Forms.SortOrder]::Ascending }
    } else {
        $script:sortColumn = $col
        $script:sortOrder = [System.Windows.Forms.SortOrder]::Ascending
    }
    $lvResults.ListViewItemSorter = New-Object ListViewComparer($script:sortColumn, $script:sortOrder)
    $lvResults.Sort()
})

$menuRemove.Add_Click({
    if ($lvResults.SelectedItems.Count -gt 0) {
        $lvResults.BeginUpdate()
        foreach ($item in $lvResults.SelectedItems) {
            [void]$script:allPreviewItems.Remove($item)
            $lvResults.Items.Remove($item)
        }
        $lvResults.EndUpdate()
        
        $lblStatus.Text = "Item(s) removed. $($script:allPreviewItems.Count) item(s) remaining in queue."
        $btnApply.Enabled = ($script:allPreviewItems.Count -gt 0)
    }
})

$form.Add_DragEnter({
    $_.Effect = if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        [System.Windows.Forms.DragDropEffects]::Copy
    } else {
        [System.Windows.Forms.DragDropEffects]::None
    }
})

$form.Add_DragDrop({
    $paths = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($paths -and $paths.Count -gt 0) {
        $p = $paths[0]
        $txtPath.Text = if (Test-Path -LiteralPath $p -PathType Container) { $p } else { Split-Path -Path $p -Parent }
        & $ResetForNewFolder
    }
})

$btnBrowse.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog -Property @{
        Title = 'Select a folder'; ValidateNames = $false; CheckFileExists = $false; CheckPathExists = $true; FileName = 'Select this folder'; Filter = "Folders|`n"
    }
    if ($ofd.ShowDialog() -eq 'OK') {
        $txtPath.Text = Split-Path -Path $ofd.FileName -Parent
        & $ResetForNewFolder
    }
})

$lvResults.Add_DoubleClick({
    if ($lvResults.SelectedItems.Count -eq 1) {
        $item = $lvResults.SelectedItems[0]
        $tag = $item.Tag
        $currentNewName = $tag.NewName
        $promptResult = [Microsoft.VisualBasic.Interaction]::InputBox("Edit the proposed new name for:`n$($item.SubItems[2].Text)", "Edit Name", $currentNewName)
        
        if (-not [string]::IsNullOrWhiteSpace($promptResult) -and $promptResult -ne $currentNewName) {
            $tag.NewName = $promptResult
            $item.SubItems[3].Text = $promptResult
            $item.SubItems[4].Text = 'Edited'
            $item.BackColor = $Theme.ControlBack
            $item.ForeColor = $Theme.ControlFore
        }
    }
})

$btnPreview.Add_Click({
    if (-not (Test-Path -LiteralPath $txtPath.Text -PathType Container)) {
        [void][System.Windows.Forms.MessageBox]::Show('Please select a valid folder first.', 'No folder selected', 'OK', 'Warning')
        return
    }

    $lvResults.Items.Clear()
    $script:allPreviewItems.Clear()
    & $ResetUndoState
    $btnPreview.Enabled = $false
    $btnApply.Enabled = $false
    $progBar.Value = 0
    $lblStatus.Text = 'Scanning...'
    [System.Windows.Forms.Application]::DoEvents()

    $gciParams = @{ LiteralPath = $txtPath.Text; Force = $true }
    if ($chkRecurse.Checked) { $gciParams['Recurse'] = $true }
    
    if ($chkFiles.Checked -and -not $chkFolders.Checked) { $gciParams['File'] = $true }
    if ($chkFolders.Checked -and -not $chkFiles.Checked) { $gciParams['Directory'] = $true }
    if (-not $chkFiles.Checked -and -not $chkFolders.Checked) {
        $btnPreview.Enabled = $true
        return
    }

    $items = Get-ChildItem @gciParams | Sort-Object { ($_.FullName -split '\\').Count } -Descending

    $srcCode = $LangMap[$cmbSource.SelectedItem]
    $tgtCode = $LangMap[$cmbTarget.SelectedItem]
    $excludePattern = $txtExclude.Text

    if ($excludePattern) {
        try { [void][regex]::new($excludePattern) }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show("Invalid regular expression pattern.", 'Invalid pattern', 'OK', 'Warning')
            $btnPreview.Enabled = $true
            return
        }
    }

    $delay = [int]$numDelay.Value
    $skipExts = @($txtSkipExt.Text -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().TrimStart('.').ToLower() })
    $total = @($items).Count
    $i = 0

    foreach ($item in $items) {
        $i++
        $lblStatus.Text = "Translating $i / $total..."
        $progBar.Value = [math]::Min(100, [int](($i / $total) * 100))
        [System.Windows.Forms.Application]::DoEvents()

        $baseName = if ($item.PSIsContainer) { $item.Name } else { [System.IO.Path]::GetFileNameWithoutExtension($item.Name) }
        $ext = if ($item.PSIsContainer) { '' } else { $item.Extension }

        if (-not $item.PSIsContainer -and $skipExts.Count -gt 0 -and $skipExts -contains $ext.TrimStart('.').ToLower()) { continue }
        if ($excludePattern -and ($baseName -match $excludePattern)) { continue }
        if ([string]::IsNullOrWhiteSpace($baseName)) { continue }

        $translationResult = Get-TranslatedText -Text $baseName -From $srcCode -To $tgtCode -DelayMs $delay
        $translatedBase = Get-SanitizedName $translationResult.TranslatedText
        $detectedLang = $translationResult.DetectedLang

        $isUnchanged = ($translatedBase -eq $baseName) -or ($detectedLang -eq $tgtCode -and $tgtCode -ne 'auto')
        $newName = if ($isUnchanged) { "$baseName$ext" } else { "$translatedBase$ext" }

        $lvItem = New-Object System.Windows.Forms.ListViewItem -ArgumentList $(if ($item.PSIsContainer) { 'Folder' } else { 'File' })
        [void]$lvItem.SubItems.Add($detectedLang)
        [void]$lvItem.SubItems.Add($item.Name)
        [void]$lvItem.SubItems.Add($newName)
        
        if ($isUnchanged) {
            [void]$lvItem.SubItems.Add('Unchanged')
            $lvItem.BackColor = $Theme.UnchangedBg
            $lvItem.ForeColor = $Theme.UnchangedFg
        } else {
            [void]$lvItem.SubItems.Add('Preview')
        }
        
        $lvItem.Tag = [pscustomobject]@{ OriginalFullPath = $item.FullName; NewName = $newName; IsContainer = $item.PSIsContainer }
        $script:allPreviewItems.Add($lvItem)
    }

    & $RefreshListView
    $lblStatus.Text = "Preview complete: $($script:allPreviewItems.Count) item(s) processed."
    $progBar.Value = 100
    $btnPreview.Enabled = $true
    $btnApply.Enabled = ($script:allPreviewItems.Count -gt 0)
})

$btnApply.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("Rename eligible item(s) now? Unchanged items will be skipped.", 'Confirm renames', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    $btnApply.Enabled = $false
    $btnPreview.Enabled = $false
    & $ResetUndoState
    $progBar.Value = 0
    $log = New-Object System.Collections.Generic.List[object]
    $renamedCount = 0
    $total = $lvResults.Items.Count
    $i = 0

    foreach ($lvItem in $lvResults.Items) {
        $i++
        $tag = $lvItem.Tag
        $lblStatus.Text = "Processing $i / $total..."
        $progBar.Value = [math]::Min(100, [int](($i / $total) * 100))
        [System.Windows.Forms.Application]::DoEvents()

        if ($lvItem.SubItems[4].Text -eq 'Unchanged') { continue }
        if (-not (Test-Path -LiteralPath $tag.OriginalFullPath)) {
            $lvItem.SubItems[4].Text = 'Missing'
            continue
        }

        $dir = Split-Path -Path $tag.OriginalFullPath -Parent
        $newName = $tag.NewName
        $newPath = Join-Path $dir $newName
        $suffix = 1
        
        while (Test-Path -LiteralPath $newPath) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($newName)
            $ext  = [System.IO.Path]::GetExtension($newName)
            $newPath = Join-Path $dir "$base ($suffix)$ext"
            $suffix++
        }
        $finalName = Split-Path $newPath -Leaf

        try {
            $renamedItem = Rename-Item -LiteralPath $tag.OriginalFullPath -NewName $finalName -ErrorAction Stop -PassThru
            $lvItem.SubItems[3].Text = $renamedItem.Name
            $lvItem.SubItems[4].Text = 'Renamed'
            $lvItem.BackColor = $Theme.SuccessBg
            $lvItem.ForeColor = $Theme.SuccessFg
            $renamedCount++

            # Record enough to reverse this exact rename. Undo replays these
            # in reverse order so a renamed parent folder is restored before
            # the children that were renamed while it still had its old name.
            $script:lastRunLog.Add([pscustomobject]@{
                LvItem       = $lvItem
                Tag          = $tag
                OriginalDir  = $dir
                OriginalLeaf = (Split-Path -Path $tag.OriginalFullPath -Leaf)
                NewLeaf      = $finalName
            })
        }
        catch {
            $lvItem.SubItems[4].Text = 'Failed'
            $lvItem.BackColor = [System.Drawing.Color]::LightCoral
        }

        $log.Add([pscustomobject]@{ OriginalPath = $tag.OriginalFullPath; NewName = $finalName; Type = if ($tag.IsContainer) { 'Folder' } else { 'File' }; Status = $lvItem.SubItems[4].Text })
    }

    if ($chkCsv.Checked -and $log.Count -gt 0) {
        $logPath = Join-Path $txtPath.Text 'translate-names-log.csv'
        $log | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8
    }

    $lblStatus.Text = "Done. $renamedCount item(s) renamed."
    $progBar.Value = 100
    $btnPreview.Enabled = $true
    $btnUndo.Enabled = ($script:lastRunLog.Count -gt 0)
})

$btnUndo.Add_Click({
    if ($script:lastRunLog.Count -eq 0) { return }

    $confirm = [System.Windows.Forms.MessageBox]::Show("Undo the last $($script:lastRunLog.Count) rename(s)?", 'Confirm undo', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    $btnUndo.Enabled = $false
    $btnApply.Enabled = $false
    $btnPreview.Enabled = $false
    $progBar.Value = 0

    $total = $script:lastRunLog.Count
    $undoneCount = 0
    $i = 0

    # Reverse order (LIFO): the last thing renamed (e.g. a parent folder) is
    # restored first, so nested items can still be found by their original
    # parent path + the name they were given during Apply.
    for ($idx = $script:lastRunLog.Count - 1; $idx -ge 0; $idx--) {
        $i++
        $entry = $script:lastRunLog[$idx]
        $lblStatus.Text = "Undoing $i / $total..."
        $progBar.Value = [math]::Min(100, [int](($i / $total) * 100))
        [System.Windows.Forms.Application]::DoEvents()

        $currentPath = Join-Path $entry.OriginalDir $entry.NewLeaf

        if (-not (Test-Path -LiteralPath $currentPath)) {
            $entry.LvItem.SubItems[4].Text = 'Undo failed (missing)'
            $entry.LvItem.BackColor = [System.Drawing.Color]::LightCoral
            continue
        }

        try {
            [void](Rename-Item -LiteralPath $currentPath -NewName $entry.OriginalLeaf -ErrorAction Stop)
            $restoredPath = Join-Path $entry.OriginalDir $entry.OriginalLeaf
            $entry.Tag.OriginalFullPath = $restoredPath
            $entry.LvItem.SubItems[3].Text = $entry.Tag.NewName
            $entry.LvItem.SubItems[4].Text = 'Preview'
            $entry.LvItem.BackColor = $Theme.ControlBack
            $entry.LvItem.ForeColor = $Theme.ControlFore
            $undoneCount++
        }
        catch {
            $entry.LvItem.SubItems[4].Text = 'Undo failed'
            $entry.LvItem.BackColor = [System.Drawing.Color]::LightCoral
        }
    }

    $lblStatus.Text = "Undo complete: $undoneCount of $total rename(s) reverted."
    $progBar.Value = 100
    & $ResetUndoState
    $btnPreview.Enabled = $true
    $btnApply.Enabled = ($script:allPreviewItems.Count -gt 0)
})

if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
    $txtPath.Text = $InitialPath
    $lblStatus.Text = 'Folder loaded. Click "Preview translations" to continue.'
}

[void]$form.ShowDialog()