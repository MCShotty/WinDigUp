param([string]$InstallRoot=(Join-Path $env:LOCALAPPDATA 'DigUp'),[switch]$PrepareTrust,[string]$CertificatePath)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'This test modifies certificate trust and is restricted to a disposable Actions runner.'}
$source=if($CertificatePath){$CertificatePath}else{Join-Path $PSScriptRoot '../shell/src-tauri/copilot/TEST-ONLY-WinDigUp.cer'}
if($PrepareTrust){
 if(!(Test-Path $source)){throw 'Test signing certificate was not produced.'}
 $cert=Import-Certificate -FilePath $source -CertStoreLocation Cert:\CurrentUser\TrustedPeople
 Write-Output ('Test-only certificate trusted in disposable runner: '+$cert.Thumbprint)
 exit 0
}
$expected='MCShotty.WinDigUp.Launcher'
$package=Get-AppxPackage -Name $expected
if(!$package){throw 'The installed identity package was not registered.'}
$manifest=$package | Get-AppxPackageManifest
$extension=@($manifest.Package.Applications.Application.Extensions.Extension.AppExtension) | Where-Object {$_.Name -eq 'com.microsoft.windows.copilotkeyprovider'}
if(!$extension){throw 'The Copilot-key provider extension is missing.'}
$exe=Join-Path $InstallRoot 'copilot/DigUp.Copilot.exe'
if(!(Test-Path $exe)){throw 'The registered launcher executable is absent.'}
$signature=Get-AuthenticodeSignature $exe
if($signature.Status -ne 'Valid'){throw ('Provider signature invalid: '+$signature.Status)}
Write-Output ('PASS: installed signed identity '+$package.PackageFamilyName+'!Launcher has the Copilot-key extension and provider executable.')
Write-Output 'UNVALIDATED: the physical Copilot key and Windows 11 app-picker interaction require a Windows 11 device.'
