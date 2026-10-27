param([string]$InstallRoot=(Join-Path $env:LOCALAPPDATA 'DigUp'))
$ErrorActionPreference='Stop'
$worker=Join-Path $InstallRoot 'helper/openvino'
$python=Join-Path $worker 'python/python.exe'
$helper=Join-Path $InstallRoot 'helper/digup.exe'
if(!(Test-Path $python)){throw 'Installed Intel Python runtime is missing'}
$temporary=Join-Path $env:TEMP ('DigUp Intel fixture-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temporary|Out-Null
$oldPath=$env:PATH
$names=@('PYTHONHOME','PYTHONPATH','DIGUP_ACCELERATOR','DIGUP_GPU','DIGUP_OPENVINO_PYTHON','DIGUP_OPENVINO_MODELS','DIGUP_ACCELERATOR_DISCOVERY_PENDING','DIGUP_ACCELERATOR_ERROR')
$old=@{};foreach($name in $names){$old[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null)}
Push-Location $temporary
try {
 $env:PATH=Join-Path $env:WINDIR 'System32'
 & $python -I -c 'import sys,openvino,torch,transformers,numpy,PIL,soundfile; assert sys.version_info[:3]==(3,12,10); assert torch.version.cuda is None; print("PASS: relocated Intel runtime and preparation dependencies import with developer paths removed")'
 if($LASTEXITCODE){throw 'Installed Intel runtime is not relocatable'}
 foreach($backend in @('openvino-npu','openvino-gpu')){
  $output=& $python -I (Join-Path $worker 'setup_probe.py') --backend $backend
  if($LASTEXITCODE){throw "Installed Intel metadata probe failed: $backend"}
  $probe=($output|Select-Object -Last 1)|ConvertFrom-Json
  if($probe.schemaVersion -ne 1 -or !$probe.probeOnly -or !$probe.runtimeReady){throw 'Invalid installed Intel discovery contract'}
  foreach($device in $probe.devices){
   if($device.backend -ne $backend -or $device.id -notmatch '^(GPU|NPU)(\.\d+)?$'){throw 'Intel metadata offered an unapproved execution device'}
  }
  $env:DIGUP_ACCELERATOR=$backend
  $reply=& $helper accelerator --list --json --index (Join-Path $temporary 'index')
  if($LASTEXITCODE){throw "Installed helper cannot discover Intel hardware without model weights: $backend"}
  $value=($reply|Select-Object -Last 1)|ConvertFrom-Json
  if($value.schemaVersion -ne 1 -or !$value.probeOnly -or !$value.runtimeReady){throw 'Installed helper did not route Intel discovery through OpenVINO'}
  Write-Output "PASS: $backend discovery uses bundled Python without model weights or CPU inference"
 }
 Write-Output 'UNVALIDATED: physical Intel integrated GPU/NPU full-model compilation, numerical parity and performance.'
} finally {
 Pop-Location
 $env:PATH=$oldPath
 foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$old[$name])}
 Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
