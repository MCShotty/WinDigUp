param([string]$InstalledApp=(Join-Path $env:LOCALAPPDATA 'DigUp/DigUp.exe'))
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Disposable Control Panel registration is restricted to Actions runners.'}
$work=Join-Path $env:RUNNER_TEMP ('control-panel-fixture-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$guid='{'+[Guid]::NewGuid().ToString().ToUpperInvariant()+'}'
$taskGuid='{'+[Guid]::NewGuid().ToString().ToUpperInvariant()+'}'
$class='HKLM:\SOFTWARE\Classes\CLSID\'+$guid
$namespace='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel\NameSpace\'+$guid
$name='WinDigUp Control Fixture '+[Guid]::NewGuid().ToString('N')
$taskName='WinDigUp Task Fixture '+[Guid]::NewGuid().ToString('N')
$fixture=Join-Path $work 'Fixture العربية.exe'
Copy-Item (Join-Path $env:RUNNER_TEMP 'DigUp App Launch Fixture.exe') $fixture
$records=@()
try {
 $appletRecord=Join-Path $work 'applet.json';$taskRecord=Join-Path $work 'task.json'
 $command='"'+$fixture+'" --record "'+$appletRecord+'" --token "applet العربية"'
 $taskCommand=[Security.SecurityElement]::Escape('"'+$fixture+'" --record "'+$taskRecord+'" --token "task العربية"')
 $tasks=Join-Path $work 'tasks.xml'
 @"
<?xml version="1.0" encoding="utf-8"?>
<applications xmlns="http://schemas.microsoft.com/windows/cpltasks/v1" xmlns:sh="http://schemas.microsoft.com/windows/tasks/v1">
<application id="$guid"><sh:task id="$taskGuid"><sh:name>$taskName</sh:name><sh:keywords>windigup fixture task</sh:keywords><sh:command>$taskCommand</sh:command></sh:task><category id="0"><sh:task idref="$taskGuid"/></category></application>
</applications>
"@ | Set-Content -Encoding UTF8 $tasks
 New-Item -Force $class,$namespace,($class+'\shell\open\command'),($class+'\DefaultIcon') | Out-Null
 Set-Item $class -Value $name;Set-Item $namespace -Value $name
 New-ItemProperty $class -Name 'LocalizedString' -Value $name -PropertyType String -Force | Out-Null
 New-ItemProperty $class -Name 'InfoTip' -Value 'Disposable WinDigUp Control Panel integration fixture' -PropertyType String -Force | Out-Null
 Set-Item ($class+'\shell\open\command') -Value $command
 Set-Item ($class+'\DefaultIcon') -Value ($fixture+',0')
 New-ItemProperty $class -Name 'System.ApplicationName' -Value ('WinDigUp.Fixture.'+$guid.Trim('{}')) -PropertyType String -Force | Out-Null
 New-ItemProperty $class -Name 'System.ControlPanel.Category' -Value '0' -PropertyType String -Force | Out-Null
 New-ItemProperty $class -Name 'System.Software.TasksFileUrl' -Value $tasks -PropertyType String -Force | Out-Null
 Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DigUpControlNotify{
 [DllImport("shell32.dll")]public static extern void SHChangeNotify(uint e,uint f,IntPtr a,IntPtr b);
}
'@
 [DigUpControlNotify]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
 $settings=Join-Path $work 'settings.json'
 @{setUp=$true;updateChecksOff=$true;applications=@{enabled=$false;semanticEnabled=$false};windowsSettings=@{enabled=$true;semanticEnabled=$false};acceleration=@{version=2;backend='openvino-npu';discoveryPending=$false}} |
  ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $settings
 foreach($case in @(@{name=$name;record=$appletRecord},@{name=$taskName;record=$taskRecord})){
  $output=Join-Path $work ([Guid]::NewGuid().ToString('N')+'.json');$errors=$output+'.err'
  $args='--settings "'+$settings+'" --index "'+(Join-Path $work 'index')+'" --debug-window "settings: '+$case.name+'" --debug-launch --debug-quit'
  $app=Start-Process $InstalledApp -ArgumentList $args -RedirectStandardOutput $output -RedirectStandardError $errors -PassThru
  try {
   if(!$app.WaitForExit(60000)){throw 'Control Panel fixture search timed out'}
   $reports=@(Get-Content $output|ForEach-Object{try{$_|ConvertFrom-Json}catch{}})
   if(!($reports|Where-Object{$_.launchAccepted -eq $true -and $_.name -eq $case.name})){throw ('Native fixture dispatch failed: '+(Get-Content -Raw $output)+' '+(Get-Content -Raw $errors))}
   $deadline=[DateTime]::UtcNow.AddSeconds(10)
   while(!(Test-Path $case.record) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
   $record=Get-Content -Raw $case.record|ConvertFrom-Json;$records+=$record
   if(!(Get-Process -Id $record.pid -ErrorAction SilentlyContinue)){throw 'The Control Panel task ended with WinDigUp'}
   Write-Output ('PASS: registered Control Panel item/task '+$case.name+' launches through discovered Shell identity and survives WinDigUp exit.')
  }finally{if(!$app.HasExited){Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue}}
 }
}finally{
 foreach($record in $records){Stop-Process -Id $record.pid -Force -ErrorAction SilentlyContinue}
 Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.Path -eq $fixture}|Stop-Process -Force -ErrorAction SilentlyContinue
 Remove-Item $namespace,$class -Recurse -Force -ErrorAction SilentlyContinue
 Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
