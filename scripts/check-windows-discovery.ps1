# Installed optional component + real NTFS/USN + standard-user boundary + installed WebView2 launch.
# A disposable VHD is the only scanned drive. No model inference or external application is used.
param([string]$InstalledApp=(Join-Path $env:LOCALAPPDATA 'DigUp\DigUp.exe'),[string]$Component,[switch]$ComponentOnly)
$ErrorActionPreference='Stop'
$component=if($Component){$Component}else{Join-Path (Split-Path $InstalledApp) 'helper\digup-discovery.exe'}
if (!(Test-Path $component)) { throw 'Optional discovery executable is missing from the installed package' }
if (Get-Service DigUpDiscovery -ErrorAction SilentlyContinue) { throw 'Fixture requires a disposable runner with no existing discovery service' }
$work=Join-Path $env:RUNNER_TEMP ('discovery-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$vhd=Join-Path $work 'fixture.vhd'
$letter=@('X','Y','Z','W') | Where-Object { !(Test-Path ($_+':\')) } | Select-Object -First 1
if (!$letter) { throw 'No free fixture drive letter' }
$root=$letter+':\'
$created=$false;$mounted=$false;$user=$null;$launched=$null;$app=$null
function Diskpart([string[]]$Lines) {
 $script=Join-Path $work 'diskpart.txt';[IO.File]::WriteAllLines($script,$Lines,[Text.Encoding]::ASCII)
 $output=& diskpart.exe /s $script 2>&1
 if ($LASTEXITCODE -ne 0) { throw ('Diskpart failed: '+($output -join ' ')) }
}
function Probe([string]$Name,[switch]$Full) {
 $arguments=@('--probe','--volume',$volume,'--expect-name',$Name)
 if ($Full) { $arguments+='--full' }
 $output=& $component @arguments
 if ($LASTEXITCODE -ne 0) { throw ('NTFS probe failed: '+($output -join ' ')) }
 $report=@($output | ForEach-Object {try {$_ | ConvertFrom-Json} catch {}} | Where-Object {$_.kind -eq 'probe'})[0]
 if (!$report.ok -or !$report.foundExpected) { throw 'Expected executable not discovered' }
 Write-Output ($report | ConvertTo-Json -Compress)
 return $report
}
try {
 Diskpart @("create vdisk file=`"$vhd`" maximum=128 type=expandable","select vdisk file=`"$vhd`"","attach vdisk","create partition primary","format fs=ntfs quick label=DigUpFixture","assign letter=$letter","exit")
 $mounted=$true
 if (!(Test-Path $root)) { throw 'Fixture NTFS volume was not mounted' }
 $volume=(& mountvol.exe $root /L | Out-String).Trim()
 if ($volume -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$') { throw 'Could not resolve fixture volume GUID' }
 $journalOutput=& fsutil.exe usn createjournal m=8388608 a=1048576 ($letter+':') 2>&1
 if ($LASTEXITCODE -ne 0) { throw ('Could not create disposable USN journal: '+($journalOutput -join ' ')) }
 $portableFolder=Join-Path $root 'Portable العربية';New-Item -ItemType Directory $portableFolder | Out-Null
 $portable=Join-Path $portableFolder 'DigUp Portable Fixture.exe'
 Copy-Item (Join-Path $env:RUNNER_TEMP 'DigUp App Launch Fixture.exe') $portable
 $public=Join-Path $root 'client';New-Item -ItemType Directory $public | Out-Null
 & icacls.exe $public /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
 $private=Join-Path $root 'private';New-Item -ItemType Directory $private | Out-Null
 Copy-Item $portable (Join-Path $private 'denied.exe')
 & icacls.exe $private /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
 & $component --install
 if ($LASTEXITCODE -ne 0) { throw 'Optional service installation failed' }
 $created=$true
 $initial=@(Probe 'DigUp Portable Fixture.exe' -Full)[-1]
 if (!$initial.expectedId) { throw 'Service did not return a stable launch identity' }
 $renamed=Join-Path $portableFolder 'Renamed العربية.exe'
 Move-Item $portable $renamed
 $rename=@(Probe 'Renamed العربية.exe')[-1]
 if ($rename.expectedId -ne $initial.expectedId) { throw 'Rename changed the launch identity' }
 New-Item -ItemType HardLink -Path $portable -Target $renamed | Out-Null
 $linked=@(Probe 'DigUp Portable Fixture.exe')[-1]
 if ($linked.expectedId -eq $rename.expectedId) { throw 'Distinct hard-link launch names were collapsed' }
 Remove-Item $renamed
 $remaining=@(Probe 'DigUp Portable Fixture.exe')[-1]
 if ($remaining.expectedId -ne $linked.expectedId) { throw 'Deleting another hard link removed or reidentified this app' }
 # Client access is checked using its own token, even when the inventory was built by an administrator.
 $user='DigUpProbe'+[Guid]::NewGuid().ToString('N').Substring(0,8)
 $secret=[Guid]::NewGuid().ToString('N')+'aA!7'
 $password=ConvertTo-SecureString $secret -AsPlainText -Force
 New-LocalUser -Name $user -Password $password -PasswordNeverExpires | Out-Null
 Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user
 $credential=[PSCredential]::new(($env:COMPUTERNAME+'\'+$user),$password)
 Start-Service seclogon
 $clientScript=Join-Path $public 'probe.ps1'
 $protectedComponent=Join-Path $env:ProgramFiles 'DigUpDiscovery\digup-discovery.exe'
 @"
& '$protectedComponent' --probe --volume '$volume' --expect-name 'DigUp Portable Fixture.exe' --expect-absent-name 'denied.exe'
exit `$LASTEXITCODE
"@ | Set-Content -Encoding UTF8 $clientScript
 $clientOutput=Join-Path $public 'standard-user.json';$clientError=Join-Path $public 'standard-user-error.txt'
 $client=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Credential $credential -LoadUserProfile -WorkingDirectory $public -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$clientScript+'"') -RedirectStandardOutput $clientOutput -RedirectStandardError $clientError -PassThru
 if (!$client.WaitForExit(60000)) { Stop-Process -Id $client.Id;throw 'Standard-user discovery exceeded its deadline' }
 if ($client.ExitCode -ne 0) { throw ('Standard-user boundary failed: '+(Get-Content -Raw $clientError)) }
 $access=@(Get-Content $clientOutput | ForEach-Object {try {$_ | ConvertFrom-Json} catch {}} | Where-Object {$_.kind -eq 'probe'})[0]
 if (!$access.foundExpected -or $access.forbiddenFound) { throw 'Service leaked inaccessible executable metadata' }
 # Updating a running shared component must stop cleanly and preserve its protected inventory.
 & $component --install
 if ($LASTEXITCODE -ne 0) { throw 'Service update failed' }
 $afterUpdate=@(Probe 'DigUp Portable Fixture.exe')[-1]
 if ($afterUpdate.expectedId -ne $linked.expectedId) { throw 'Component update discarded stable identities' }
 if (!$ComponentOnly) {
 $settings=Join-Path $work 'settings.json'
 @{setUp=$true;updateChecksOff=$true;applications=@{enabled=$true;semanticEnabled=$false};discovery=@{enabled=$true;volumes=@($volume)};acceleration=@{version=2;backend='openvino-npu'}} |
  ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $settings
 $stdout=Join-Path $work 'ui.json';$stderr=Join-Path $work 'ui-error.txt'
 $arguments='--settings "'+$settings+'" --index "'+(Join-Path $work 'index')+'" --debug-window "apps: DigUp Portable Fixture" --debug-launch --debug-quit'
 $app=Start-Process $InstalledApp -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
 if (!$app.WaitForExit(90000)) { throw 'Installed app did not finish portable discovery and launch' }
 $reports=@(Get-Content $stdout | ForEach-Object {try {$_ | ConvertFrom-Json} catch {}})
 if (!($reports | Where-Object {$_.launchAccepted -eq $true -and $_.name -eq 'DigUp Portable Fixture'})) { throw ('Discovered app was not launched: '+(Get-Content -Raw $stdout)+' '+(Get-Content -Raw $stderr)) }
 $recordPath=Join-Path $portableFolder 'launch record.json';$until=[DateTime]::UtcNow.AddSeconds(10)
 while (!(Test-Path $recordPath) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 100 }
 $record=Get-Content -Raw $recordPath | ConvertFrom-Json;$launched=$record.pid
 if ($record.cwd.TrimEnd('\') -ne $portableFolder.TrimEnd('\') -and $record.cwd -notlike '*Portable العربية') { throw 'Executable working directory was changed' }
 if ($record.args.Count -ne 1) { throw 'Search text was passed as executable arguments' }
 if (!(Get-Process -Id $launched -ErrorAction SilentlyContinue)) { throw 'Portable application was terminated with DigUp workers' }
 }
 Write-Output 'PASS: real installed NTFS service, Unicode records, rename identity, hard links, standard-user permissions, service update, portable app launch and detached lifetime; no model'
} finally {
 if ($app -and !$app.HasExited) { Stop-Process -Id $app.Id -ErrorAction SilentlyContinue }
 if ($launched) { Stop-Process -Id $launched -ErrorAction SilentlyContinue }
 if ($user) { Remove-LocalUser $user -ErrorAction SilentlyContinue }
 if ($created) { & $component --uninstall;Remove-Item (Join-Path $env:ProgramFiles 'DigUpDiscovery') -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item (Join-Path $env:ProgramData 'DigUpDiscovery') -Recurse -Force -ErrorAction SilentlyContinue }
 if ($mounted) { Diskpart @("select vdisk file=`"$vhd`"","detach vdisk","exit") }
 Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
