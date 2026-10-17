# Installed compact WebView2 panel, with ordinary OS catalog data and no model required.
param([string]$InstalledApp = (Join-Path $env:LOCALAPPDATA 'DigUp\DigUp.exe'))
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DigUpPanelProbe {
    public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref Point point);
    [DllImport("user32.dll")] static extern int GetWindowRgn(IntPtr hwnd, IntPtr region);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int left,int top,int right,int bottom);
    [DllImport("gdi32.dll")] static extern bool PtInRegion(IntPtr region,int x,int y);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr region);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left,top,right,bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int x,y; }
    public static bool HasRoundedPanel(uint pid) {
        bool found=false;
        EnumWindows((hwnd,data) => {
            uint owner; GetWindowThreadProcessId(hwnd,out owner);
            if(owner!=pid) return true;
            Rect rect;
            if(!GetWindowRect(hwnd,out rect)) return true;
            Rect client; Point origin=new Point();
            if(!GetClientRect(hwnd,out client) || !ClientToScreen(hwnd,ref origin)) return true;
            int width=client.right-client.left, height=client.bottom-client.top;
            if(width<200 || height<60) return true;
            int left=origin.x-rect.left, top=origin.y-rect.top;
            IntPtr region=CreateRectRgn(0,0,0,0);
            if(region==IntPtr.Zero) return true;
            try {
                if(GetWindowRgn(hwnd,region)>0 && !PtInRegion(region,left,top)
                    && PtInRegion(region,left+width/2,top+height/2)
                    && PtInRegion(region,left+width-1,top+height/2)
                    && (left==0 || !PtInRegion(region,left-1,top+height/2)))
                    found=true;
            } finally { DeleteObject(region); }
            return !found;
        },IntPtr.Zero);
        return found;
    }
}
'@
$fixture = Join-Path $env:RUNNER_TEMP 'DigUp App Launch Fixture.exe'
$fixtureName = '000 DigUp Panel Fixture ' + [Guid]::NewGuid().ToString('N')
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) ($fixtureName + '.lnk')
$work = Join-Path $env:RUNNER_TEMP ('DigUp Panel ' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $work | Out-Null
try {
    $creationArgs = '--create-shortcut "' + $shortcut + '" "' + (Join-Path $work 'unused-launch-record.json') + '" "' + $work + '"'
    $creation = Start-Process -FilePath $fixture -ArgumentList $creationArgs -Wait -PassThru
    if ($creation.ExitCode -ne 0) { throw 'Could not register the disposable panel fixture shortcut' }
    foreach ($material in @('automatic','solid')) {
        $settings = Join-Path $work ($material + '.json')
        $configuration = @{setUp=$true;updateChecksOff=$true;appearance='dark';panelMaterial=$material;
            applications=@{enabled=$true;semanticEnabled=$false};windowsSettings=@{enabled=$true;semanticEnabled=$false};
            acceleration=@{version=2;backend='openvino-npu';discoveryPending=$false}}
        [IO.File]::WriteAllText($settings, ($configuration | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $stdout = Join-Path $work ($material + '-ui.json')
        $stderr = Join-Path $work ($material + '-error.txt')
        $arguments = '--settings "' + $settings + '" --index "' + (Join-Path $work ($material+'-index')) +
            '" --debug-query "apps: ' + $fixtureName + '" --debug-show --debug-quit'
        $process = Start-Process -FilePath $InstalledApp -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            $rounded = $false
            while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                $rounded = $rounded -or [DigUpPanelProbe]::HasRoundedPanel([uint32]$process.Id)
                Start-Sleep -Milliseconds 50
                $process.Refresh()
            }
            if (-not $process.HasExited) { throw 'Installed compact panel did not finish its report' }
            Get-Content $stdout
            Get-Content $stderr
            $reports = @(Get-Content $stdout | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
            $report = $reports | Where-Object { $_.panel -and $_.phase -eq 'applications' } | Select-Object -Last 1
            if (-not $report) { throw 'Installed panel did not render app results' }
            if (-not ($report.applications | Where-Object { $_.name -eq $fixtureName })) { throw 'Installed panel did not discover its real fixture shortcut' }
            if ($report.panel.fieldHeight -ne 62 -or $report.panel.height -le 64 -or $report.panel.height -gt 640) {
                throw 'Installed panel did not use bounded progressive geometry'
            }
            if ($report.panel.listWidth -lt ($report.panel.width-30)) { throw 'Installed panel still uses a split-width list' }
            if ($report.panel.appearance -ne 'dark') { throw 'Native saved appearance was not loaded' }
            if ($material -eq 'solid' -and $report.panel.material -ne 'solid') { throw 'Solid appearance was not respected' }
            if ($report.panel.material -notin @('solid','acrylic')) { throw 'Native material state is missing' }
            if ($report.panel.previewOpen) { throw 'An automatic preview opened' }
            if (-not $rounded) { throw 'The native window did not have a rounded hit region' }
            Write-Output ("PASS: installed compact panel ($material): name results without inference, progressive geometry, saved appearance and rounded native hit region. Applied material: " + $report.panel.material)
        } finally {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue }
            $process.Dispose()
        }
    }
} finally {
    Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
