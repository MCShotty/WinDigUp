param([string]$InstallRoot=(Join-Path $env:LOCALAPPDATA 'DigUp'),[switch]$PrepareTrust,[string]$CertificatePath)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'This test modifies certificate trust and is restricted to a disposable Actions runner.'}
$source=if($CertificatePath){$CertificatePath}else{Join-Path $PSScriptRoot '../shell/src-tauri/copilot/TEST-ONLY-WinDigUp.cer'}
if($PrepareTrust){
 if(!(Test-Path $source)){throw 'Test signing certificate was not produced.'}
 $cert=Import-Certificate -FilePath $source -CertStoreLocation Cert:\LocalMachine\TrustedPeople
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

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DigUpCopilotProbe {
 delegate bool EnumProc(IntPtr h,IntPtr data);
 [StructLayout(LayoutKind.Sequential)] public struct Rect{public int left,top,right,bottom;}
 [DllImport("user32.dll")]static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")]static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]static extern uint GetDpiForWindow(IntPtr h);
 public static bool HasLauncher(uint process){
  bool found=false;
  EnumWindows((h,d)=>{uint pid;Rect r;GetWindowThreadProcessId(h,out pid);
   if(pid==process&&IsWindowVisible(h)&&GetWindowRect(h,out r)){
    double scale=GetDpiForWindow(h)/96.0;
    if(scale>0&&(r.right-r.left)/scale<=722&&(r.bottom-r.top)/scale>=110&&(r.bottom-r.top)/scale<=130)found=true;
   }return true;},IntPtr.Zero);
  return found;
 }
}
'@
$target=[IO.Path]::GetFullPath((Join-Path $InstallRoot 'DigUp.exe'))
function OwnedProcesses { @(Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $target}) }
OwnedProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
try {
 $aumid=$package.PackageFamilyName+'!Launcher'
 Start-Process ('shell:AppsFolder\'+$aumid)
 $deadline=[DateTime]::UtcNow.AddSeconds(45)
 do {$owners=@(OwnedProcesses);$visible=@($owners|Where-Object{[DigUpCopilotProbe]::HasLauncher([uint32]$_.Id)});if($visible.Count){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
 if($owners.Count -ne 1 -or !$visible.Count){throw 'Registered cold activation did not open one compact launcher.'}
 $first=$owners[0].Id
 Start-Process ('shell:AppsFolder\'+$aumid)
 Start-Sleep -Seconds 2
 $owners=@(OwnedProcesses)
 if($owners.Count -ne 1 -or $owners[0].Id -ne $first -or ![DigUpCopilotProbe]::HasLauncher([uint32]$first)){
  throw 'Warm provider activation duplicated or hid the launcher.'
 }
 Write-Output 'PASS: registered provider cold/warm activation shows one compact launcher without model readiness.'
} finally { OwnedProcesses | Stop-Process -Force -ErrorAction SilentlyContinue }
Write-Output ('PASS: installed signed identity '+$package.PackageFamilyName+'!Launcher has the Copilot-key extension and provider executable.')
Write-Output 'UNVALIDATED: the physical Copilot key and Windows 11 app-picker interaction require a Windows 11 device.'
