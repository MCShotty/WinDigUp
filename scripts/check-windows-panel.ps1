# Real WebView2 content and native pixels; no neural model is loaded.
param([string]$InstalledApp = (Join-Path $env:LOCALAPPDATA 'DigUp\DigUp.exe'), [string]$Helper = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DigUpPanelProbe {
    public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref Point point);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetWindowRgn(IntPtr hwnd, IntPtr region);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int left,int top,int right,int bottom);
    [DllImport("gdi32.dll")] static extern bool PtInRegion(IntPtr region,int x,int y);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr region);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left,top,right,bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int x,y; }
    public static IntPtr Find(uint pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((hwnd,data) => {
            uint owner; GetWindowThreadProcessId(hwnd,out owner);
            Rect client;
            if(owner==pid && IsWindowVisible(hwnd) && GetClientRect(hwnd,out client)
                && client.right>=200 && client.bottom>=60) { found=hwnd; return false; }
            return true;
        },IntPtr.Zero);
        return found;
    }
    public static Rect Bounds(uint pid) {
        var hwnd=Find(pid); Rect rect;
        if(hwnd==IntPtr.Zero || !GetWindowRect(hwnd,out rect)) throw new Exception("Visible panel is unavailable");
        return rect;
    }
    public static bool HasRoundedPanel(uint pid) {
        var hwnd=Find(pid); Rect rect,client; Point origin=new Point();
        if(hwnd==IntPtr.Zero || !GetWindowRect(hwnd,out rect) || !GetClientRect(hwnd,out client)
            || !ClientToScreen(hwnd,ref origin)) return false;
        int width=client.right-client.left,height=client.bottom-client.top;
        int left=origin.x-rect.left,top=origin.y-rect.top;
        IntPtr region=CreateRectRgn(0,0,0,0);
        if(region==IntPtr.Zero) return false;
        try {
            return GetWindowRgn(hwnd,region)>0 && !PtInRegion(region,left,top)
                && PtInRegion(region,left+width/2,top+height/2)
                && PtInRegion(region,left+width-1,top+height/2);
        } finally { DeleteObject(region); }
    }
    public static bool HasNoFrame(uint pid) {
        var hwnd=Find(pid); Rect outer,client;
        return hwnd!=IntPtr.Zero && GetWindowRect(hwnd,out outer) && GetClientRect(hwnd,out client)
            && outer.right-outer.left==client.right-client.left
            && outer.bottom-outer.top==client.bottom-client.top;
    }
}
'@
$fixture = Join-Path $env:RUNNER_TEMP 'DigUp App Launch Fixture.exe'
$fixtureName = '000 DigUp Panel Fixture ' + [Guid]::NewGuid().ToString('N')
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) ($fixtureName + '.lnk')
$work = Join-Path $env:RUNNER_TEMP ('DigUp Panel ' + [Guid]::NewGuid().ToString('N'))
$evidence = Join-Path $env:RUNNER_TEMP 'native-panel-evidence'
New-Item -ItemType Directory -Force $work,$evidence | Out-Null
$background = [System.Windows.Forms.Form]::new()
$background.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$background.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$background.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$background.ShowInTaskbar = $false
$background.BackColor = [System.Drawing.Color]::FromArgb(47,101,147)
$background.Show()
[System.Windows.Forms.Application]::DoEvents()

function Test-PaintedCorners([uint32]$ProcessId, [string]$Name) {
    $rect = [DigUpPanelProbe]::Bounds($ProcessId)
    $width = $rect.right-$rect.left
    $height = $rect.bottom-$rect.top
    $bitmap = [System.Drawing.Bitmap]::new($width+32,$height+32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.left-16,$rect.top-16,0,0,$bitmap.Size)
        $backgroundColor = $background.BackColor
        $reference = $bitmap.GetPixel(0,0)
        $available = [Math]::Abs($reference.R-$backgroundColor.R) -le 3 -and
            [Math]::Abs($reference.G-$backgroundColor.G) -le 3 -and
            [Math]::Abs($reference.B-$backgroundColor.B) -le 3
        $path = Join-Path $evidence ($Name+'.png')
        $bitmap.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
        if (-not $available) {
            Write-Output "UNVALIDATED: desktop pixel capture is unavailable in this session ($Name). Native geometry checks still run."
            return
        }
        foreach ($point in @(@(18,18),@(($width+13),18),@(18,($height+13)),@(($width+13),($height+13)),@(13,48),@(($width+18),48))) {
            $pixel = $bitmap.GetPixel($point[0],$point[1])
            if ([Math]::Abs($pixel.R-$backgroundColor.R) -gt 3 -or
                [Math]::Abs($pixel.G-$backgroundColor.G) -gt 3 -or
                [Math]::Abs($pixel.B-$backgroundColor.B) -gt 3) {
                throw "A native backdrop is painted outside the capsule ($Name, pixel $($point[0]),$($point[1])). Screenshot: $path"
            }
        }
        $center=$bitmap.GetPixel([int]($width/2)+16,48)
        if ([Math]::Abs($center.R-$backgroundColor.R) -le 3 -and
            [Math]::Abs($center.G-$backgroundColor.G) -le 3 -and
            [Math]::Abs($center.B-$backgroundColor.B) -le 3) {
            throw "Pixel capture did not show painted WebView2 content ($Name)"
        }
        Write-Output "PASS: painted native capsule corners and surrounding desktop ($Name)."
        if ($env:DIGUP_PANEL_SCREENSHOT_LOG -eq '1' -and $Name -eq 'dark-solid-empty') {
            Write-Output ('NATIVE_PANEL_SCREENSHOT_BASE64 '+[Convert]::ToBase64String([IO.File]::ReadAllBytes($path)))
        }
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

try {
    $creationArgs = '--create-shortcut "' + $shortcut + '" "' + (Join-Path $work 'unused-launch-record.json') + '" "' + $work + '"'
    $creation = Start-Process -FilePath $fixture -ArgumentList $creationArgs -Wait -PassThru
    if ($creation.ExitCode -ne 0) { throw 'Could not register the disposable panel fixture shortcut' }
    foreach ($theme in @('system','light','dark')) {
        foreach ($material in @('automatic','solid')) {
            foreach ($shape in @('empty','results')) {
                $name = "$theme-$material-$shape"
                $settings = Join-Path $work ($name+'.json')
                $configuration = @{setUp=$true;updateChecksOff=$true;appearance=$theme;panelMaterial=$material;
                    applications=@{enabled=$true;semanticEnabled=$false};windowsSettings=@{enabled=$true;semanticEnabled=$false};
                    acceleration=@{version=2;backend='openvino-npu';discoveryPending=$false}}
                [IO.File]::WriteAllText($settings,($configuration|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
                $stdout = Join-Path $work ($name+'-ui.json')
                $stderr = Join-Path $work ($name+'-error.txt')
                $query = if ($shape -eq 'empty') { ' ' } else { 'apps: '+$fixtureName }
                $arguments = '--settings "'+$settings+'" --index "'+(Join-Path $work ($name+'-index'))+
                    '" --debug-query "'+$query+'" --debug-show'
                if ($Helper) { $arguments += ' --helper "'+$Helper+'"' }
                $process = Start-Process -FilePath $InstalledApp -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
                try {
                    $deadline = [DateTime]::UtcNow.AddSeconds(60)
                    $report = $null
                    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                        if (Test-Path $stdout) {
                            $reports = @(Get-Content $stdout -ErrorAction SilentlyContinue | ForEach-Object { try { $_|ConvertFrom-Json } catch {} })
                            $report = $reports | Where-Object { $_.panel } | Select-Object -Last 1
                        }
                        if ($report) { break }
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Sleep -Milliseconds 50
                        $process.Refresh()
                    }
                    if (-not $report) { Get-Content $stderr; throw "Installed panel did not render its report ($name)" }
                    $report | ConvertTo-Json -Depth 8
                    if ($report.panel.fieldHeight -ne 62 -or $report.panel.height -gt 640) { throw 'Panel geometry is invalid' }
                    if ($report.panel.appearance -ne $theme) { throw 'Saved theme was not loaded' }
                    if ($material -eq 'solid' -and $report.panel.material -ne 'solid') { throw 'Solid preference was not respected' }
                    if ($report.panel.material -notin @('solid','acrylic')) { throw 'Native material status is missing' }
                    if ($shape -eq 'empty') {
                        if ($report.phase -ne 'empty' -or $report.panel.height -ne 64) { throw 'Empty capsule expanded' }
                    } else {
                        if (-not ($report.applications | Where-Object { $_.name -eq $fixtureName })) { throw 'Real shortcut result is missing' }
                        if ($report.panel.height -le 64 -or $report.panel.listWidth -lt ($report.panel.width-30)) { throw 'Results geometry is invalid' }
                    }
                    if ($report.panel.previewOpen) { throw 'An automatic preview opened' }
                    if (-not [DigUpPanelProbe]::HasRoundedPanel([uint32]$process.Id)) { throw 'Native region is not rounded' }
                    if (-not [DigUpPanelProbe]::HasNoFrame([uint32]$process.Id)) { throw 'A non-client frame surrounds the capsule' }
                    Test-PaintedCorners ([uint32]$process.Id) $name
                    Write-Output "PASS: real WebView2 panel ($name), applied material $($report.panel.material)."
                } finally {
                    if (-not $process.HasExited) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue }
                    $process.WaitForExit(5000) | Out-Null
                    $process.Dispose()
                }
            }
        }
    }
} finally {
    $background.Close(); $background.Dispose()
    Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
