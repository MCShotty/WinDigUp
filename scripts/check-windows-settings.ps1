# Installed UI route and allowlisted ms-settings activation; no model or file index.
param([string]$InstalledApp=(Join-Path $env:LOCALAPPDATA 'DigUp\DigUp.exe'))
$ErrorActionPreference='Stop'
$work=Join-Path $env:RUNNER_TEMP ('digup-settings-page-'+[Guid]::NewGuid().ToString('N'));$app=$null
New-Item -ItemType Directory $work | Out-Null
try{
 $settings=Join-Path $work 'settings.json'
 @{setUp=$true;updateChecksOff=$true;applications=@{enabled=$false;semanticEnabled=$false};windowsSettings=@{enabled=$true;semanticEnabled=$false};acceleration=@{version=2;backend='openvino-npu'}} |
  ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $settings
 $stdout=Join-Path $work 'report.json';$stderr=Join-Path $work 'errors.txt'
 $arguments='--settings "'+$settings+'" --index "'+(Join-Path $work 'index')+'" --debug-window "settings: display" --debug-selected setting:display --debug-launch --debug-quit'
 $app=Start-Process $InstalledApp -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
 if (!$app.WaitForExit(60000)){throw 'Installed settings result did not render and dispatch'}
 $reports=@(Get-Content $stdout | ForEach-Object{try{$_ | ConvertFrom-Json}catch{}})
 if (!($reports | Where-Object{$_.launchAccepted -eq $true -and $_.applicationId -eq 'setting:display'})){
  throw ('Windows settings dispatch failed: '+(Get-Content -Raw $stdout)+' '+(Get-Content -Raw $stderr))
 }
 $classicOut=Join-Path $work 'classic.json'
 $classicArgs='--settings "'+$settings+'" --index "'+(Join-Path $work 'index')+'" --debug-window "settings: classic Sound" --debug-launch --debug-quit'
 $app=Start-Process $InstalledApp -ArgumentList $classicArgs -RedirectStandardOutput $classicOut -RedirectStandardError $stderr -PassThru
 if(!$app.WaitForExit(60000)){throw 'Classic Control Panel search did not render and dispatch'}
 $classicReports=@(Get-Content $classicOut | ForEach-Object{try{$_|ConvertFrom-Json}catch{}})
 if(!($classicReports|Where-Object{$_.launchAccepted -eq $true -and $_.applicationId -like 'setting:control-panel-*'})){
  throw ('Classic Control Panel dispatch failed: '+(Get-Content -Raw $classicOut)+' '+(Get-Content -Raw $stderr))
 }
 Write-Output 'PASS: installed classic Sound search and native Shell activation without inference'
 Write-Output 'PASS: installed Settings-only search renders and Windows accepts allowlisted page activation without app discovery, file indexing or model inference; page contents require physical Windows validation'
}finally{
 if($app -and !$app.HasExited){Stop-Process -Id $app.Id -ErrorAction SilentlyContinue}
 Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
