param([string]$Destination=(Join-Path $PSScriptRoot '../shell/src-tauri/copilot'))
$ErrorActionPreference='Stop'
$Destination=[IO.Path]::GetFullPath($Destination)
Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Destination | Out-Null
$publisher=if($env:DIGUP_MSIX_PUBLISHER){$env:DIGUP_MSIX_PUBLISHER}else{'CN=WinDigUp'}
$name='MCShotty.WinDigUp.Launcher'
@{publisher=$publisher;name=$name;enabled=[bool]($env:DIGUP_MSIX_PFX_BASE64 -or $env:DIGUP_MSIX_TEST_SIGN -eq '1');version=$(if($env:DIGUP_MSIX_VERSION){$env:DIGUP_MSIX_VERSION}else{'0.7.0.0'});testSigned=($env:DIGUP_MSIX_TEST_SIGN -eq '1')} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Destination 'identity.json')
Copy-Item "$PSScriptRoot/../shell/src-tauri/windows/register-copilot.ps1" (Join-Path $Destination 'register.ps1')
if(!$env:DIGUP_MSIX_PFX_BASE64 -and $env:DIGUP_MSIX_TEST_SIGN -ne '1'){
 Write-Output 'No Windows signing certificate configured; regular installer will remain available without Copilot-key registration.'
 exit 0
}
$work=Join-Path $env:TEMP ('digup-identity-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$certificate=$null
try {
 $version=if($env:DIGUP_MSIX_VERSION){$env:DIGUP_MSIX_VERSION}else{'0.7.0.0'}
 if($version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or @($version.Split('.') | Where-Object {[int64]$_ -gt 65535}).Count){throw 'DIGUP_MSIX_VERSION must contain four numeric components from 0 through 65535.'}
 if($env:DIGUP_MSIX_TEST_SIGN -ne '1' -and !$env:DIGUP_MSIX_VERSION){throw 'Production signing requires a monotonic DIGUP_MSIX_VERSION.'}
 $pfx=Join-Path $work 'signing.pfx'
 $password=$env:DIGUP_MSIX_PFX_PASSWORD
 if($env:DIGUP_MSIX_TEST_SIGN -eq '1'){
  if($env:GITHUB_ACTIONS -ne 'true'){throw 'Automatic test signing is restricted to disposable GitHub Actions runners.'}
  $password=[Guid]::NewGuid().ToString('N')
  $certificate=New-SelfSignedCertificate -Type Custom -Subject $publisher -KeyUsage DigitalSignature -CertStoreLocation Cert:\CurrentUser\My -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3','2.5.29.19={text}')
  Export-PfxCertificate -Cert $certificate -FilePath $pfx -Password (ConvertTo-SecureString $password -AsPlainText -Force) | Out-Null
  Export-Certificate -Cert $certificate -FilePath (Join-Path $Destination 'TEST-ONLY-WinDigUp.cer') | Out-Null
 } else {
  [IO.File]::WriteAllBytes($pfx,[Convert]::FromBase64String($env:DIGUP_MSIX_PFX_BASE64))
 }
 $xmlPublisher=[Security.SecurityElement]::Escape($publisher)
 $manifest=@"
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
 <assemblyIdentity version="1.0.0.0" name="WinDigUp.Copilot" type="win32"/>
 <msix xmlns="urn:schemas-microsoft-com:msix.v1" publisher="$xmlPublisher" packageName="$name" applicationId="Launcher"/>
</assembly>
"@
 $manifest | Set-Content -Encoding UTF8 (Join-Path $work 'provider.manifest')
 & cl.exe /nologo /EHsc /std:c++17 /MT "$PSScriptRoot/../shell/src-tauri/windows/copilot-key-provider.cpp" "/Fe:$Destination/DigUp.Copilot.exe" "/Fo:$work/provider.obj" /link /SUBSYSTEM:WINDOWS shell32.lib ole32.lib user32.lib
 if($LASTEXITCODE){throw 'Copilot provider compilation failed.'}
 & mt.exe -nologo -manifest (Join-Path $work 'provider.manifest') "-outputresource:$Destination/DigUp.Copilot.exe;#1"
 if($LASTEXITCODE){throw 'Provider identity embedding failed.'}
 $layout=Join-Path $work 'layout'
 New-Item -ItemType Directory -Force (Join-Path $layout 'Public'),(Join-Path $layout 'copilot/Assets'),(Join-Path $Destination 'Assets') | Out-Null
 Add-Type -AssemblyName System.Drawing
 $original=[Drawing.Image]::FromFile("$PSScriptRoot/../shell/src-tauri/icons/128x128.png")
 try {foreach($size in @(44,50,150)){
  $bitmap=[Drawing.Bitmap]::new($size,$size);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  try{$graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic;$graphics.DrawImage($original,0,0,$size,$size);$bitmap.Save((Join-Path $layout "copilot/Assets/Logo$size.png"),[Drawing.Imaging.ImageFormat]::Png)}
  finally{$graphics.Dispose();$bitmap.Dispose()}
  Copy-Item (Join-Path $layout "copilot/Assets/Logo$size.png") (Join-Path $Destination "Assets/Logo$size.png")
 }}finally{$original.Dispose()}
 'WinDigUp' | Set-Content (Join-Path $layout 'Public/provider.txt')
 $packageManifest=@"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:uap3="http://schemas.microsoft.com/appx/manifest/uap/windows10/3" xmlns:uap10="http://schemas.microsoft.com/appx/manifest/uap/windows10/10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities" IgnorableNamespaces="uap uap3 uap10 rescap">
 <Identity Name="$name" Publisher="$xmlPublisher" Version="$version" ProcessorArchitecture="x64"/>
 <Properties><DisplayName>WinDigUp</DisplayName><PublisherDisplayName>WinDigUp</PublisherDisplayName><Logo>copilot/Assets/Logo50.png</Logo><uap10:AllowExternalContent>true</uap10:AllowExternalContent></Properties>
 <Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0"/></Dependencies>
 <Resources><Resource Language="en-us"/></Resources>
 <Applications><Application Id="Launcher" Executable="copilot\DigUp.Copilot.exe" uap10:RuntimeBehavior="win32App" uap10:TrustLevel="mediumIL">
  <uap:VisualElements DisplayName="WinDigUp" Description="Search apps, files and Windows settings" BackgroundColor="transparent" Square150x150Logo="copilot/Assets/Logo150.png" Square44x44Logo="copilot/Assets/Logo44.png" AppListEntry="none"/>
  <Extensions><uap3:Extension Category="windows.appExtension"><uap3:AppExtension Name="com.microsoft.windows.copilotkeyprovider" Id="WinDigUpLauncher" DisplayName="WinDigUp" Description="Open WinDigUp quick search" PublicFolder="Public"/></uap3:Extension></Extensions>
 </Application></Applications>
 <Capabilities><rescap:Capability Name="runFullTrust"/><rescap:Capability Name="unvirtualizedResources"/></Capabilities>
</Package>
"@
 $packageManifest | Set-Content -Encoding UTF8 (Join-Path $layout 'AppxManifest.xml')
 Copy-Item (Join-Path $layout 'AppxManifest.xml') (Join-Path $Destination 'AppxManifest.xml')
 $msix=Join-Path $Destination 'WinDigUp.Identity.msix'
 # External-location packages require /nv because their executable is installed by NSIS.
 & makeappx.exe pack /o /d $layout /nv /p $msix
 if($LASTEXITCODE){throw 'Identity package validation failed.'}
 $sign=@('sign','/fd','SHA256','/f',$pfx,'/p',$password)
 if($env:DIGUP_MSIX_TEST_SIGN -ne '1'){
  if(!$env:DIGUP_MSIX_TIMESTAMP_URL){throw 'Production signing requires DIGUP_MSIX_TIMESTAMP_URL.'}
  $sign+=@('/tr',$env:DIGUP_MSIX_TIMESTAMP_URL,'/td','SHA256')
 }
 & signtool.exe @sign (Join-Path $Destination 'DigUp.Copilot.exe')
 if($LASTEXITCODE){throw 'Provider executable signing failed.'}
 & signtool.exe @sign $msix
 if($LASTEXITCODE){throw 'Identity package signing failed.'}
 Write-Output 'Signed external-location identity package built.'
} finally {
 if($certificate){Remove-Item $certificate.PSPath -Force -ErrorAction SilentlyContinue}
 Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
