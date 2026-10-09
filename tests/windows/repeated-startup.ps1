param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateRange(1, 100)][int]$Pairs = 6
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run elevated: the release application replaces a non-elevated parent process.'
}
$Executable = [IO.Path]::GetFullPath($Executable)
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
$null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class RepeatedStartupWindows {
    public class Window { public long Handle; public string Class; public bool Visible; }
    delegate bool EnumProc(IntPtr hwnd, IntPtr arg);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr arg);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    public static List<Window> ForPid(uint expected) {
        var result = new List<Window>();
        EnumWindows((hwnd, arg) => {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if(pid == expected) {
                var name = new StringBuilder(256); GetClassName(hwnd, name, name.Capacity);
                result.Add(new Window { Handle=hwnd.ToInt64(), Class=name.ToString(), Visible=IsWindowVisible(hwnd) });
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@
$results = [Collections.Generic.List[object]]::new()
for ($pair = 1; $pair -le $Pairs; $pair++) {
    $directory = Join-Path $EvidenceDirectory ("pair-$pair-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $directory 'config') -Force
    $binary = Join-Path $directory 'MaaEnd.exe'
    Copy-Item -LiteralPath $Executable -Destination $binary
    @{ interface_version=2; name='StartupProbe'; version='1.0.0'; controller=@(); resource=@(); task=@() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'interface.json') -Encoding utf8
    @{ version='1.0'; instances=@(@{ id='startup-probe'; name='Startup probe'; controllerName=''; resourceName=''; tasks=@() }); settings=@{ helpImproveSoftware=$false; minimizeToTray=$false; webServerEnabled=$false } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'config\mxu-StartupProbe.json') -Encoding utf8
    $observations = @()
    try {
        foreach ($number in @(1, 2)) {
            # Both instances must use the same literal executable/cache path.
            if ($number -eq 2 -and ($pair % 2) -eq 0) { Start-Sleep -Milliseconds 350 }
            $start = [Diagnostics.ProcessStartInfo]::new($binary)
            $start.WorkingDirectory = $directory; $start.UseShellExecute = $false
            $null = $start.Environment.Remove('WEBVIEW2_BROWSER_EXECUTABLE_FOLDER')
            $process = [Diagnostics.Process]::Start($start)
            $observations += [pscustomobject]@{ Process=$process; Timer=[Diagnostics.Stopwatch]::StartNew(); Main=$false; Visible=$false; Tray=$false; Closed=$false; Timeout=$false }
        }
        do {
            foreach ($observation in $observations) {
                if ($observation.Process.HasExited) { continue }
                $windows = @([RepeatedStartupWindows]::ForPid($observation.Process.Id))
                $main = $windows | Where-Object Class -eq 'Tauri Window' | Select-Object -First 1
                $observation.Main = $observation.Main -or ($null -ne $main)
                $observation.Visible = $observation.Visible -or ($main -and $main.Visible)
                $observation.Tray = $observation.Tray -or (@($windows | Where-Object Class -eq 'tray_icon_app').Count -gt 0)
                if ($main -and $main.Visible -and $observation.Tray -and -not $observation.Closed -and $observation.Timer.Elapsed.TotalSeconds -ge 2) {
                    $observation.Closed = [RepeatedStartupWindows]::PostMessage([IntPtr]::new($main.Handle),0x10,[IntPtr]::Zero,[IntPtr]::Zero)
                }
                if ($observation.Timer.Elapsed.TotalSeconds -gt 15) {
                    $observation.Timeout = $true
                    $observation.Process.Kill(); $observation.Process.WaitForExit()
                }
            }
            Start-Sleep -Milliseconds 25
        } while (@($observations | Where-Object { -not $_.Process.HasExited }).Count -gt 0)
    } finally {
        foreach ($observation in $observations) {
            if (-not $observation.Process.HasExited) { $observation.Process.Kill(); $observation.Process.WaitForExit() }
            $result = [pscustomobject]@{ pair=$pair; pid=$observation.Process.Id; sha256=(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash; main=$observation.Main; visible=$observation.Visible; tray=$observation.Tray; closed=$observation.Closed; timeout=$observation.Timeout; exitCode=$observation.Process.ExitCode; directory=$directory }
            $results.Add($result)
            $result | ConvertTo-Json -Compress
        }
        $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'results.json') -Encoding utf8
    }
}
$failed = @($results | Where-Object { -not $_.main -or -not $_.visible -or -not $_.tray -or -not $_.closed -or $_.timeout -or $_.exitCode -ne 0 })
if ($failed.Count -gt 0) { throw "$($failed.Count)/$($results.Count) starts failed to create a visible, normally closable WebView window." }
"PASS: $($results.Count) starts created visible windows and exited after normal close."
