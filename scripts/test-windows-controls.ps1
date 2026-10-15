# Run in Windows PowerShell, whose framework includes UI Automation and System.Drawing.
param(
    [Parameter(Mandatory = $true)][long]$WindowHandle,
    [Parameter(Mandatory = $true)][string]$DiagnosticsDirectory
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
$descendants = [System.Windows.Automation.TreeScope]::Descendants
function Find-Control([string]$Name) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    $control = $root.FindFirst($descendants, $condition)
    if (-not $control) { throw "WinUI control was not accessible: $Name" }
    return $control
}
$query = Find-Control 'Search files'
if ($query.Current.IsOffscreen -or -not $query.Current.IsEnabled) { throw 'The search input is not visible and enabled.' }
$quit = Find-Control 'Quit'
$quitAction = $quit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)

# The first-launch settings must be usable without downloading a model or starting an encoder.
$backend = Find-Control 'Run EmbeddingGemma 2 on'
$expansion = $backend.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
$expansion.Expand()
Start-Sleep -Milliseconds 300
$amd = Find-Control "AMD GPU $([char]0xB7) Vulkan"
$selection = $amd.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
$selection.Select()
$expansion.Collapse()
Write-Host 'Verified the visible search input and selected AMD GPU through WinUI UI Automation.'

try {
    $rect = $root.Current.BoundingRectangle
    $bitmap = [System.Drawing.Bitmap]::new([int]$rect.Width, [int]$rect.Height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen([int]$rect.X, [int]$rect.Y, 0, 0, $bitmap.Size) }
        finally { $graphics.Dispose() }
        $bitmap.Save((Join-Path $DiagnosticsDirectory 'main-window.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
} catch { Write-Warning "Screenshot capture unavailable: $_" }

$quitAction.Invoke()
