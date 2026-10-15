param(
    [Parameter(Mandatory = $true)][string]$PackageDirectory,
    [string]$DiagnosticsDirectory = (Join-Path $env:RUNNER_TEMP 'WinDigUp-launch')
)
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path $PackageDirectory).Path
foreach ($file in @('App.xbf', 'MainWindow.xbf', 'Microsoft.UI.Xaml/Themes/themeresources.xbf')) {
    if (-not (Test-Path (Join-Path $package $file))) { throw "Published WinUI application is missing $file." }
}
New-Item $DiagnosticsDirectory -ItemType Directory -Force | Out-Null
$diagnostics = (Resolve-Path $DiagnosticsDirectory).Path
$started = Get-Date
$previousPath = $env:Path
$process = $null
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinDigUpWindowProbe {
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam,
        IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
}
'@
try {
    # Explorer does not inherit the developer toolchain. Also launch from a different directory
    # so accidental working-directory dependencies cannot pass this check.
    $env:Path = "$env:SystemRoot/System32;$env:SystemRoot"
    $process = Start-Process (Join-Path $package 'WinDigUp.exe') -WorkingDirectory $diagnostics -PassThru `
        -RedirectStandardOutput (Join-Path $diagnostics 'stdout.txt') `
        -RedirectStandardError (Join-Path $diagnostics 'stderr.txt')
    $deadline = (Get-Date).AddSeconds(40)
    $visibleSince = $null
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if ($process.HasExited) { throw "WinDigUp exited before launch completed: $($process.ExitCode)." }
        $window = $process.MainWindowHandle
        if ($window -ne [IntPtr]::Zero -and $process.MainWindowTitle -eq 'WinDigUp' -and [WinDigUpWindowProbe]::IsWindowVisible($window)) {
            if (-not $visibleSince) { $visibleSince = Get-Date }
            # Keep pumping for several frames: creating a native window alone is not enough.
            if (((Get-Date) - $visibleSince).TotalSeconds -ge 5) {
                [UIntPtr]$reply = [UIntPtr]::Zero
                if ([WinDigUpWindowProbe]::SendMessageTimeout($window, 0, [UIntPtr]::Zero, [IntPtr]::Zero, 2, 5000, [ref]$reply) -eq [IntPtr]::Zero) {
                    throw 'WinDigUp opened a window but its UI thread is unresponsive.'
                }
                # Windows PowerShell provides UI Automation without installing a test framework
                # or sharing a .NET/WinUI runtime with the application under test.
                & "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -NonInteractive `
                    -File (Join-Path $PSScriptRoot 'test-windows-controls.ps1') `
                    -WindowHandle $window.ToInt64() -DiagnosticsDirectory $diagnostics
                if ($LASTEXITCODE -ne 0) { throw 'The launched WinUI controls did not pass UI Automation checks.' }
                if (-not $process.WaitForExit(15000)) { throw 'WinDigUp did not exit after invoking Quit.' }
                if ($process.ExitCode -ne 0) { throw "WinDigUp failed while quitting: $($process.ExitCode)." }
                Write-Host 'Verified WinDigUp.exe opens a visible, responsive WinUI window and quits cleanly using the distributed runtime.'
                return
            }
        } else { $visibleSince = $null }
    } while ((Get-Date) -lt $deadline)
    throw 'WinDigUp did not open its main window within 40 seconds.'
} catch {
    foreach ($file in @('stdout.txt', 'stderr.txt')) {
        $path = Join-Path $diagnostics $file
        if (Test-Path $path) { Get-Content $path | Write-Host }
    }
    $startupLog = Join-Path $env:LOCALAPPDATA 'WinDigUp/startup.log'
    if (Test-Path $startupLog) {
        Copy-Item $startupLog $diagnostics
        Get-Content $startupLog | Write-Host
    }
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $started } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -in @('.NET Runtime', 'Application Error', 'Windows Error Reporting') } |
        Select-Object TimeCreated, ProviderName, Message | Format-List | Out-String | Tee-Object (Join-Path $diagnostics 'events.txt') | Write-Host
    throw
} finally {
    if ($process -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    if ($process) { $process.Dispose() }
    $env:Path = $previousPath
}
