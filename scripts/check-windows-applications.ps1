# Installed WebView2 -> catalog -> native Shell launch, with no model or accelerator required.
$ErrorActionPreference = 'Stop'
$fixture = Join-Path $env:RUNNER_TEMP 'DigUp App Launch Fixture.exe'
$work = Join-Path $env:RUNNER_TEMP ('DigUp Apps ' + [Guid]::NewGuid().ToString('N'))
$name = 'DigUp Launch Fixture ' + [Guid]::NewGuid().ToString('N')
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) ($name + '.lnk')
$recordPath = Join-Path $work 'launch record.json'
$app = $null
$record = $null
try {
    New-Item -ItemType Directory -Force $work | Out-Null
    $cwd = Join-Path $work 'Working folder العربية'
    New-Item -ItemType Directory $cwd | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $fixture
    $shortcut.Arguments = '--record "' + $recordPath + '" --token "spaces العربية"'
    $shortcut.WorkingDirectory = $cwd
    $shortcut.Description = 'Disposable application launch integration fixture'
    $shortcut.Save()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    $settings = Join-Path $work 'settings.json'
    [IO.File]::WriteAllText($settings, '{"setUp":true,"updateChecksOff":true,"applications":{"enabled":true,"semanticEnabled":false},"acceleration":{"backend":"openvino-npu"}}', [Text.UTF8Encoding]::new($false))
    $stdout = Join-Path $work 'ui.json'
    $stderr = Join-Path $work 'ui-error.txt'
    $installed = Join-Path $env:LOCALAPPDATA 'DigUp\DigUp.exe'
    $arguments = '--settings "' + $settings + '" --index "' + (Join-Path $work 'index') + '" --debug-window "apps: ' + $name + '" --debug-launch --debug-quit'
    $app = Start-Process -FilePath $installed -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    if (-not $app.WaitForExit(60000)) { throw 'Installed app did not finish the catalog/launch check' }
    Get-Content $stdout
    Get-Content $stderr
    $reports = @(Get-Content $stdout | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
    if (-not ($reports | Where-Object { $_.launchAccepted -eq $true -and $_.name -eq $name })) { throw 'Installed application did not accept the catalog launch' }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path $recordPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $record = Get-Content -Raw $recordPath | ConvertFrom-Json
    if ($record.cwd -ne $cwd -or $record.args[-1] -ne 'spaces العربية') { throw 'Shortcut arguments or working directory were changed' }
    if (-not (Get-Process -Id $record.pid -ErrorAction SilentlyContinue)) { throw 'Launched application ended with DigUp' }
    Write-Output 'PASS: installed app discovers and launches a real shortcut; Unicode arguments/cwd preserved; application survives DigUp exit'
} finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -ErrorAction SilentlyContinue }
    if ($record) { Stop-Process -Id $record.pid -ErrorAction SilentlyContinue }
    # If marker writing failed, only this workflow's exact fixture executable is eligible for cleanup.
    Get-Process | Where-Object { $_.Path -eq $fixture } | Stop-Process -ErrorAction SilentlyContinue
    Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $work)) { break }
        Start-Sleep -Milliseconds 250
    }
}
