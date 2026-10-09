param(
    [Parameter(Mandatory)][string]$Executable,
    [ValidateSet('creation-failure', 'normal-close', 'hidden-window', 'minimize-to-tray')]
    [string]$Scenario = 'creation-failure',
    [Parameter(Mandatory)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run elevated: the release application replaces a non-elevated parent process.'
}

# Test the actual application in its own portable data directory. Only its PID
# may be closed or killed; existing MaaEnd instances are left untouched.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class StartupProbeWindows {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr arg);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr arg);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool PostThreadMessage(uint thread, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("dbghelp.dll", SetLastError=true)] public static extern bool MiniDumpWriteDump(IntPtr process, uint pid, IntPtr file, uint flags, IntPtr exception, IntPtr stream, IntPtr callback);
    public static uint ThreadForWindow(IntPtr hwnd) { uint pid; return GetWindowThreadProcessId(hwnd, out pid); }
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    public static Dictionary<long, string> ForPid(uint expected) {
        var result = new Dictionary<long, string>();
        EnumWindows((hwnd, arg) => {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if (pid == expected) {
                var name = new StringBuilder(256); GetClassName(hwnd, name, name.Capacity);
                result.Add(hwnd.ToInt64(), name.ToString());
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@

$caseDirectory = Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) "$Scenario-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $caseDirectory -Force
$testExe = Join-Path $caseDirectory 'mxu-startup-test.exe'
Copy-Item -LiteralPath $Executable -Destination $testExe
$null = New-Item -ItemType Directory -Path (Join-Path $caseDirectory 'config')
@{ interface_version = 2; name = 'StartupProbe'; version = '1.0.0'; controller = @(); resource = @(); task = @() } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $caseDirectory 'interface.json') -Encoding utf8
@{ version = '1.0'; instances = @(@{ id = 'startup-probe'; name = 'Startup probe'; controllerName = ''; resourceName = ''; tasks = @() }); settings = @{
    helpImproveSoftware = $false; webServerEnabled = $true; webServerPort = 19470
    minimizeToTray = ($Scenario -eq 'minimize-to-tray')
} } | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $caseDirectory 'config\mxu-StartupProbe.json') -Encoding utf8

$start = [Diagnostics.ProcessStartInfo]::new($testExe)
$start.WorkingDirectory = $caseDirectory
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.Environment['WEBVIEW2_USER_DATA_FOLDER'] = Join-Path $caseDirectory 'webview-data'
if ($Scenario -eq 'creation-failure') {
    $start.Environment['WEBVIEW2_BROWSER_EXECUTABLE_FOLDER'] = Join-Path $caseDirectory 'missing-runtime'
} else {
    $null = $start.Environment.Remove('WEBVIEW2_BROWSER_EXECUTABLE_FOLDER')
}

$process = [Diagnostics.Process]::Start($start)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
$observedTray = $false
$observedMain = $false
$mainHandle = [IntPtr]::Zero
$closed = $false
$hiddenAt = $null
$trayCloseAt = $null
$trayRestored = $false
$errorDialogDismissed = $false
$timer = [Diagnostics.Stopwatch]::StartNew()
$failure = $null
try {
    while (-not $process.WaitForExit(100) -and $timer.Elapsed.TotalSeconds -lt 20) {
        $windows = [StartupProbeWindows]::ForPid($process.Id)
        $observedTray = $observedTray -or ($windows.Values -contains 'tray_icon_app')
        foreach ($entry in $windows.GetEnumerator()) {
            if ($entry.Value -eq 'Tauri Window') {
                $observedMain = $true
                $mainHandle = [IntPtr]::new($entry.Key)
            }
            if ($Scenario -eq 'creation-failure' -and $entry.Value -eq '#32770') {
                # Release Tauri shows a native runtime-missing error dialog.
                # Acknowledge only the dialog belonging to this test's PID.
                $errorDialogDismissed = [StartupProbeWindows]::PostMessage([IntPtr]::new($entry.Key), 0x111, [IntPtr]::new(1), [IntPtr]::Zero)
            }
        }
        if ($Scenario -eq 'normal-close' -and $mainHandle -ne [IntPtr]::Zero -and $observedTray -and -not $closed) {
            $closed = [StartupProbeWindows]::PostMessage($mainHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
        }
        if ($Scenario -eq 'hidden-window' -and $observedMain -and $observedTray -and $null -eq $hiddenAt -and [StartupProbeWindows]::IsWindowVisible($mainHandle)) {
            $null = [StartupProbeWindows]::ShowWindow($mainHandle, 0)
            $hiddenAt = $timer.Elapsed.TotalSeconds
        }
        if ($Scenario -eq 'hidden-window' -and $null -ne $hiddenAt -and -not $closed -and $timer.Elapsed.TotalSeconds -ge ($hiddenAt + 3)) {
            if ([StartupProbeWindows]::IsWindowVisible($mainHandle)) { throw 'The main window did not stay hidden during the observation period.' }
            $closed = [StartupProbeWindows]::PostMessage($mainHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
        }
        if ($Scenario -eq 'minimize-to-tray' -and $observedMain -and $observedTray) {
            if ($null -eq $trayCloseAt -and $timer.Elapsed.TotalSeconds -ge 4 -and [StartupProbeWindows]::IsWindowVisible($mainHandle)) {
                $closed = [StartupProbeWindows]::PostMessage($mainHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
                $trayCloseAt = $timer.Elapsed.TotalSeconds
            } elseif ($null -ne $trayCloseAt -and -not $trayRestored -and $timer.Elapsed.TotalSeconds -ge ($trayCloseAt + 3)) {
                if ([StartupProbeWindows]::IsWindowVisible($mainHandle)) { throw 'Close with minimize-to-tray enabled must hide the main window.' }
                $null = [StartupProbeWindows]::ShowWindow($mainHandle, 5)
                $trayRestored = [StartupProbeWindows]::IsWindowVisible($mainHandle)
                if (-not $trayRestored) { throw 'The hidden main window could not be restored.' }
                # End only this test process through its native event loop.
                $thread = [StartupProbeWindows]::ThreadForWindow($mainHandle)
                $null = [StartupProbeWindows]::PostThreadMessage($thread, 0x12, [IntPtr]::Zero, [IntPtr]::Zero)
            }
        }
    }
    if (-not $process.HasExited) { throw 'Application stayed alive after failed creation or a normal close.' }
    if ($Scenario -eq 'creation-failure') {
        # tauri-runtime-wry 2.9.3 uses ControlFlow::Exit and does not propagate
        # the requested code to the OS. Verify graceful exit with this version.
        if ($process.ExitCode -ne 0) { throw "Startup failure did not exit gracefully; got $($process.ExitCode)." }
        if ($observedTray) { throw 'Failed startup initialized a tray icon.' }
        $nativeLog = Get-ChildItem -LiteralPath (Join-Path $caseDirectory 'debug') -Filter 'mxu-tauri*.log' |
            Get-Content -Raw
        if ($nativeLog -notmatch 'Could not find the webview runtime') { throw 'The intended WebView creation failure was not exercised.' }
        if ($nativeLog -match 'AppConfigState:|Web server listening|MaaFramework loaded') { throw 'Failed startup initialized backend services.' }
    } else {
        if (-not $observedMain -or -not $observedTray) { throw 'Normal startup must create a main window and tray.' }
        if ($Scenario -eq 'hidden-window' -and $null -eq $hiddenAt) { throw 'The hidden-window scenario was not exercised.' }
        if (-not $closed) { throw 'A valid main window exited before the test requested close.' }
        if ($Scenario -eq 'minimize-to-tray' -and -not $trayRestored) { throw 'Minimize-to-tray was not verified.' }
        if ($process.ExitCode -ne 0) { throw "Normal close must exit with code 0; got $($process.ExitCode)." }
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    if (-not $process.HasExited) {
        $dump = [IO.File]::Create((Join-Path $caseDirectory 'timeout.dmp'))
        try { $null = [StartupProbeWindows]::MiniDumpWriteDump($process.Handle, $process.Id, $dump.SafeFileHandle.DangerousGetHandle(), 0x1022, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero) }
        finally { $dump.Dispose() }
        $process.Kill(); $process.WaitForExit()
    }
    $stdout.Result | Set-Content -LiteralPath (Join-Path $caseDirectory 'stdout.log') -Encoding utf8
    $stderr.Result | Set-Content -LiteralPath (Join-Path $caseDirectory 'stderr.log') -Encoding utf8
    $result = [ordered]@{
        scenario = $Scenario; source = [IO.Path]::GetFullPath($Executable)
        sha256 = (Get-FileHash -LiteralPath $testExe -Algorithm SHA256).Hash
        pid = $process.Id; exitCode = $process.ExitCode; elapsedSeconds = $timer.Elapsed.TotalSeconds
        observedMain = $observedMain; observedTray = $observedTray; closed = $closed; trayRestored = $trayRestored; errorDialogDismissed = $errorDialogDismissed
        passed = ($null -eq $failure); failure = $failure; evidenceDirectory = $caseDirectory
    }
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $caseDirectory 'result.json') -Encoding utf8
    $result | ConvertTo-Json -Compress
}
if ($failure) { throw $failure }
