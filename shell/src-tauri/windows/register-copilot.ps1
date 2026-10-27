param([Parameter(Mandatory=$true)][string]$InstallRoot,[switch]$Uninstall)
$ErrorActionPreference='Stop'
if([Environment]::Is64BitOperatingSystem -and ![Environment]::Is64BitProcess){throw 'Copilot-key registration requires 64-bit Windows PowerShell.'}
$name='MCShotty.WinDigUp.Launcher'
$folder=Join-Path $InstallRoot 'copilot'
$metadata=Get-Content -Raw (Join-Path $folder 'identity.json') | ConvertFrom-Json
$old=@(Get-AppxPackage -Name $name | Where-Object {$_.Publisher -eq $metadata.publisher})
if($Uninstall){
 foreach($package in $old){Remove-AppxPackage -Package $package.PackageFullName}
 exit 0
}
if(!$metadata.enabled){
 foreach($package in $old){Remove-AppxPackage -Package $package.PackageFullName}
 Remove-Item (Join-Path $folder 'WinDigUp.Identity.msix'),(Join-Path $folder 'DigUp.Copilot.exe') -Force -ErrorAction SilentlyContinue
 Write-Output 'This build has no signed Copilot-key identity. Normal search remains available.'
 exit 0
}
$packagePath=Join-Path $folder 'WinDigUp.Identity.msix'
if(!(Test-Path $packagePath)){Write-Output 'Copilot-key identity is not included in this build.';exit 0}
try {
 $stamp=Join-Path $folder 'registration.json'
 # NSIS can launch Windows PowerShell with a reduced module search path.
 $stream=[IO.File]::OpenRead($packagePath);$algorithm=[Security.Cryptography.SHA256]::Create()
 try{$hash=[BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','')}
 finally{$algorithm.Dispose();$stream.Dispose()}
 if($old.Count){
  $previous=if(Test-Path $stamp){Get-Content -Raw $stamp | ConvertFrom-Json}else{$null}
  if($old[0].Version -eq [Version]$metadata.version -and $previous.hash -eq $hash -and $previous.root -eq [IO.Path]::GetFullPath($InstallRoot)){
   Write-Output 'Copilot-key identity is already registered.';exit 0
  }
  if($old[0].Version -ge [Version]$metadata.version){throw 'The identity package version must increase for a changed or moved installation. The existing registration was retained.'}
 }
 Add-AppxPackage -Path $packagePath -ExternalLocation $InstallRoot -ForceApplicationShutdown
 @{hash=$hash;root=[IO.Path]::GetFullPath($InstallRoot)} | ConvertTo-Json | Set-Content -Encoding UTF8 $stamp
 Write-Output 'WinDigUp Copilot-key provider registered. Choose it in Windows Settings.'
} catch {
 Write-Output ('Copilot-key registration unavailable: '+$_.Exception.Message)
 exit 1
}
