<#
.SYNOPSIS
    Builds TranslateNames.exe - the whole app in one file.

.DESCRIPTION
    Compiles a small C# launcher with the .NET Framework compiler that ships
    with Windows, embedding TranslateNamesApp.ps1 as a resource. One exe, no vbs
    and no execution-policy prompt.

    The default build is a GUI-subsystem program: double-clicking it never
    creates a console window at all, so there is no flash. CLI modes
    (-SelfTest, -Plan, -InstallContextMenu, ...) attach to the calling terminal
    and print their output there; from Explorer they allocate their own console.

    Note: because Windows treats a GUI-subsystem process as fire-and-forget, a
    terminal returns to the prompt immediately. Scripts should use
    Start-Process -Wait (or run the .ps1). Build -Console if you want a
    synchronous CLI binary for automation, at the cost of a console flash.

    Each launch extracts the script to %TEMP%\TranslateNames\TranslateNamesApp-<id>.ps1
    so concurrent runs cannot collide, then deletes it when the child exits.
    Create an empty TranslateNames.portable file next to the exe to keep
    settings/cache/journal in TranslateNamesData beside it.

    The exe is unsigned: SmartScreen may warn the first time on a new machine.

.PARAMETER OutDir
    Where TranslateNames.exe is written. Default: .\dist next to this script.

.PARAMETER AppPath
    Script to embed. Default: .\TranslateNamesApp.ps1.

.PARAMETER BuildDir
    Scratch directory for the C# source and embedded copy. Default: %TEMP%.

.PARAMETER Console
    Build a console-subsystem exe instead. It waits for CLI calls like a normal
    command-line tool but flashes a console window on double-click.

.PARAMETER KeepBuild
    Keep the scratch directory.

.EXAMPLE
    .\Build-SingleExe.ps1

.EXAMPLE
    .\Build-SingleExe.ps1 -OutDir ..\..\TestLab\dist

.EXAMPLE
    .\Build-SingleExe.ps1 -Console -OutDir .\dist-cli
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$AppPath,
    [string]$BuildDir,
    [switch]$Console,
    [switch]$KeepBuild
)

$ErrorActionPreference = 'Stop'

if (-not $OutDir)   { $OutDir   = Join-Path $PSScriptRoot 'dist' }
if (-not $AppPath)  { $AppPath  = Join-Path $PSScriptRoot 'TranslateNamesApp.ps1' }
if (-not $BuildDir) { $BuildDir = Join-Path ([System.IO.Path]::GetTempPath()) ('TranslateNames-build-' + [guid]::NewGuid().ToString('N')) }

$OutDir   = [System.IO.Path]::GetFullPath($OutDir)
$AppPath  = [System.IO.Path]::GetFullPath($AppPath)
$BuildDir = [System.IO.Path]::GetFullPath($BuildDir)

if (-not (Test-Path -LiteralPath $AppPath)) { throw "Cannot find script: $AppPath" }
if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }
if (Test-Path -LiteralPath $BuildDir) { Remove-Item -LiteralPath $BuildDir -Recurse -Force }
$null = New-Item -ItemType Directory -Path $BuildDir -Force

$version = '0.0.0'
$versionMatch = [regex]::Match([System.IO.File]::ReadAllText($AppPath), "AppVersion\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'")
if ($versionMatch.Success) { $version = $versionMatch.Groups[1].Value }
$fileVersion = $version + '.0'

$cscCandidates = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ }
$csc = $cscCandidates | Select-Object -First 1
if (-not $csc) {
    $runtimeDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $candidate = Join-Path $runtimeDir 'csc.exe'
    if (Test-Path -LiteralPath $candidate) { $csc = $candidate }
}
if (-not $csc) { throw 'Could not find csc.exe (.NET Framework 4.x compiler).' }

$embedded = Join-Path $BuildDir 'TranslateNamesApp.ps1'
Copy-Item -LiteralPath $AppPath -Destination $embedded -Force

$csPath = Join-Path $BuildDir 'Launcher.cs'
$csTemplate = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: AssemblyTitle("Translate Names")]
[assembly: AssemblyDescription("Bulk-translate file and folder names")]
[assembly: AssemblyProduct("Translate Names")]
[assembly: AssemblyVersion("@@VERSION@@")]
[assembly: AssemblyFileVersion("@@VERSION@@")]

static class Program
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AllocConsole();
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    private const uint ATTACH_PARENT_PROCESS = 0xFFFFFFFF;
    private const string ScriptResource = "TranslateNamesApp.ps1";

    private static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value)) return "\"\"";
        var builder = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { backslashes++; builder.Append(c); }
            else if (c == '"') { builder.Append('\\', backslashes + 1); builder.Append('"'); backslashes = 0; }
            else { builder.Append(c); backslashes = 0; }
        }
        builder.Append('\\', backslashes);
        builder.Append('"');
        return builder.ToString();
    }

    private static bool IsConsoleMode(string[] args)
    {
        foreach (string argument in args)
        {
            string lower = argument.ToLowerInvariant();
            if (lower == "-selftest" || lower == "-plan" ||
                lower == "-installcontextmenu" || lower == "-uninstallcontextmenu" ||
                lower == "-?" || lower == "--help" || lower == "-h" || lower == "/?")
            {
                return true;
            }
        }
        return false;
    }

    // A GUI-subsystem program has no console. For CLI switches, borrow the
    // terminal that launched us, or create one if started from Explorer.
    private static void PrepareConsole()
    {
        try
        {
            if (GetConsoleWindow() == IntPtr.Zero) { AttachConsole(ATTACH_PARENT_PROCESS); }
            if (GetConsoleWindow() == IntPtr.Zero && !Console.IsOutputRedirected) { AllocConsole(); }
            var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
            Console.SetOut(output);
            var error = new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true };
            Console.SetError(error);
        }
        catch { }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            bool consoleMode = IsConsoleMode(args);
            if (consoleMode) { PrepareConsole(); }

            string exePath = Assembly.GetExecutingAssembly().Location;
            string tempDir = Path.Combine(Path.GetTempPath(), "TranslateNames");
            Directory.CreateDirectory(tempDir);
            string scriptPath = Path.Combine(tempDir, "TranslateNamesApp-" + Guid.NewGuid().ToString("N") + ".ps1");

            try
            {
                using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(ScriptResource))
                {
                    if (resource == null) { Fail("The embedded script is missing from this build."); return 3; }
                    using (var reader = new StreamReader(resource, Encoding.UTF8, true))
                    {
                        File.WriteAllText(scriptPath, reader.ReadToEnd(), new UTF8Encoding(true));
                    }
                }

                string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                string powershell = Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
                if (!File.Exists(powershell)) { Fail("Windows PowerShell 5.1 was not found."); return 4; }

                var arguments = new StringBuilder();
                arguments.Append("-NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File ");
                arguments.Append(Quote(scriptPath));
                foreach (string argument in args) { arguments.Append(' ').Append(Quote(argument)); }

                var startInfo = new ProcessStartInfo(powershell, arguments.ToString());
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                startInfo.WorkingDirectory = Environment.CurrentDirectory;
                startInfo.EnvironmentVariables["TRANSLATENAMES_HOST_EXE"] = exePath;

                if (consoleMode)
                {
                    startInfo.RedirectStandardOutput = true;
                    startInfo.RedirectStandardError = true;
                }

                using (Process child = Process.Start(startInfo))
                {
                    if (consoleMode)
                    {
                        var errorTask = child.StandardError.ReadToEndAsync();
                        Console.Out.Write(child.StandardOutput.ReadToEnd());
                        child.WaitForExit();
                        Console.Error.Write(errorTask.Result);
                    }
                    else
                    {
                        child.WaitForExit();
                    }
                    return child.ExitCode;
                }
            }
            finally
            {
                try { if (File.Exists(scriptPath)) { File.Delete(scriptPath); } } catch { }
            }
        }
        catch (Exception exception)
        {
            Fail(exception.ToString());
            return 1;
        }
    }

    private static void Fail(string message)
    {
        try
        {
            if (GetConsoleWindow() == IntPtr.Zero && !Console.IsOutputRedirected) { AllocConsole(); }
            Console.Error.WriteLine("Translate Names: " + message);
        }
        catch { }
        try
        {
            System.Windows.Forms.MessageBox.Show(message, "Translate Names",
                System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
        }
        catch { }
    }
}
'@
$csSource = $csTemplate.Replace('@@VERSION@@', $fileVersion)
[System.IO.File]::WriteAllText($csPath, $csSource, (New-Object System.Text.UTF8Encoding($false)))

$outPath = Join-Path $OutDir 'TranslateNames.exe'
if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }

# Response file avoids shell-level quoting problems when paths contain spaces.
$responsePath = Join-Path $BuildDir 'build.rsp'
$target = if ($Console) { '/target:exe' } else { '/target:winexe' }
$responseLines = @(
    $target
    '/platform:anycpu'
    '/optimize+'
    '/nologo'
    '/r:System.Windows.Forms.dll'
    '/r:System.Drawing.dll'
    ('/resource:"{0}",TranslateNamesApp.ps1' -f $embedded)
    ('/out:"{0}"' -f $outPath)
    ('"{0}"' -f $csPath)
)
[System.IO.File]::WriteAllLines($responsePath, [string[]]$responseLines, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("Compiling Translate Names {0} ({1}) ..." -f $version, $(if ($Console) { 'console build' } else { 'windowless GUI build' })) -ForegroundColor Cyan
$compilerOutput = & $csc ('@' + $responsePath) 2>&1 | Out-String
$compilerExit = $LASTEXITCODE
if ($compilerExit -ne 0) {
    Write-Host $compilerOutput -ForegroundColor Red
    throw ("csc.exe failed with exit code {0}." -f $compilerExit)
}
if (-not (Test-Path -LiteralPath $outPath)) { throw 'Compiler produced no output.' }

# 2 = Windows GUI subsystem (no console is created), 3 = console subsystem.
$fileStream = [System.IO.File]::OpenRead($outPath)
try {
    $reader = New-Object System.IO.BinaryReader($fileStream)
    $fileStream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    $fileStream.Position = $peOffset + 4 + 20 + 68
    $subsystem = $reader.ReadUInt16()
} finally {
    $fileStream.Dispose()
}

$file = Get-Item -LiteralPath $outPath
Write-Host ("Built: {0}" -f $file.FullName) -ForegroundColor Green
Write-Host ("   size: {0:N0} bytes  version: {1}  subsystem: {2}" -f $file.Length, $version, $(if ($subsystem -eq 2) { 'GUI (no console window)' } else { 'console' }))
Write-Host '   single file: copy TranslateNames.exe anywhere and run it.'
Write-Host '   portable data: create an empty TranslateNames.portable file next to the exe.'
Write-Host '   scripted CLI: Start-Process -Wait (GUI-subsystem apps are fire-and-forget).'

if (-not $KeepBuild) {
    Remove-Item -LiteralPath $BuildDir -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
