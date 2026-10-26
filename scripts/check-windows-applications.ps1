# Installed WebView2 -> catalog -> native Shell launch, with no model or accelerator required.
param([string]$ProviderHarness, [string]$Backend = 'openvino-npu',
      [string]$InstalledApp = (Join-Path $env:LOCALAPPDATA 'DigUp\DigUp.exe'), [string]$Models = '')
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
    $compiledFixture = $fixture
    $fixture = Join-Path $work 'Fixture العربية.exe'
    Copy-Item $compiledFixture $fixture
    $creationArgs = '--create-shortcut "' + $shortcutPath + '" "' + $recordPath + '" "' + $cwd + '"'
    $creation = Start-Process -FilePath $fixture -ArgumentList $creationArgs -PassThru -Wait
    if ($creation.ExitCode -ne 0) { throw 'Could not create the Unicode fixture shortcut' }
    $settings = Join-Path $work 'settings.json'
    $configuration = @{setUp=$true;updateChecksOff=$true;applications=@{enabled=$true;semanticEnabled=$false};
        acceleration=@{version=2;backend=$Backend;gpu=if($Backend -eq 'nvidia-cuda'){$env:DIGUP_GPU}else{''}}}
    [IO.File]::WriteAllText($settings, ($configuration | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $stdout = Join-Path $work 'ui.json'
    $stderr = Join-Path $work 'ui-error.txt'
    $installed = $InstalledApp
    $arguments = '--settings "' + $settings + '" --index "' + (Join-Path $work 'index') + '" --debug-window "apps: ' + $name + '" --debug-launch --debug-quit'
    if ($Models) { $arguments += ' --models "' + $Models + '"' }
    if ($ProviderHarness) {
        $installed = $ProviderHarness
        $arguments = '"' + (Join-Path $work 'index') + '" "' + $name + '"'
    }
    $app = Start-Process -FilePath $installed -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    if (-not $app.WaitForExit(60000)) { throw 'Installed app did not finish the catalog/launch check' }
    Get-Content $stdout
    Get-Content $stderr
    $reports = @(Get-Content $stdout | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
    if (-not ($reports | Where-Object { $_.launchAccepted -eq $true -and $_.name -eq $name })) { throw 'Installed application did not accept the catalog launch' }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path $recordPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $record = Get-Content -Raw $recordPath | ConvertFrom-Json
    Write-Output ($record | ConvertTo-Json -Depth 4 -Compress)
    Write-Output ('Expected working directory: ' + $cwd)
    if ($record.cwd -ne $cwd -or $record.args[0] -ne $fixture -or $record.args[-1] -ne 'spaces العربية') { throw 'Shortcut target, arguments or working directory were changed' }
    if (-not (Get-Process -Id $record.pid -ErrorAction SilentlyContinue)) { throw 'Launched application ended with DigUp' }
    $mode = if ($ProviderHarness) { 'Native provider harness' } else { 'Installed WebView2 app' }
    Write-Output ($mode + ': PASS: discovers and launches a real shortcut; Unicode arguments/cwd preserved; fixture survives parent exit')
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
