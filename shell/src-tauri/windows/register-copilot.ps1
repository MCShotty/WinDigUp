param([Parameter(Mandatory=$true)][string]$InstallRoot,[switch]$Uninstall)
$ErrorActionPreference='Stop'
$name='MCShotty.WinDigUp.Launcher'
$folder=Join-Path $InstallRoot 'copilot'
$metadata=Get-Content -Raw (Join-Path $folder 'identity.json') | ConvertFrom-Json
$old=@(Get-AppxPackage -Name $name | Where-Object {$_.Publisher -eq $metadata.publisher})
if($Uninstall){
 foreach($package in $old){Remove-AppxPackage -Package $package.PackageFullName}
 exit 0
}
$packagePath=Join-Path $folder 'WinDigUp.Identity.msix'
if(!(Test-Path $packagePath)){Write-Output 'Copilot-key identity is not included in this build.';exit 0}
try {
 Add-AppxPackage -Path $packagePath -ExternalLocation $InstallRoot -ForceApplicationShutdown
 Write-Output 'WinDigUp Copilot-key provider registered. Choose it in Windows Settings.'
} catch {
 Write-Output ('Copilot-key registration unavailable: '+$_.Exception.Message)
 exit 1
}
