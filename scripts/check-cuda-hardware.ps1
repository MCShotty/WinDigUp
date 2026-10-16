#requires -Version 7.0
# Run on a real RTX target after installing the artifact; the CUDA Toolkit is deliberately absent from PATH.
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'DigUp'),
    [Parameter(Mandatory=$true)][string]$Models,
    [Parameter(Mandatory=$true)][string]$Output,
    [string]$GPU = '',
    [string]$Python = 'python',
    [string]$Installer = ''
)
$ErrorActionPreference = 'Stop'
$pythonExe = (Get-Command $Python -ErrorAction Stop).Source
$helperDirectory = Join-Path $InstallDirectory 'helper'
$helper = Join-Path $helperDirectory 'digup.exe'
$reference = Join-Path $PSScriptRoot 'Reference'
$policyTool = Join-Path $PSScriptRoot 'cuda-policy-check.exe'
foreach ($required in @($helper, $policyTool, (Join-Path $reference 'vectors.json'))) {
    if (!(Test-Path $required)) { throw "Missing validation input: $required" }
}
New-Item -ItemType Directory -Force $Output | Out-Null
$Output = (Resolve-Path $Output).Path
$Models = (Resolve-Path $Models).Path
$previous = @{}
foreach ($name in @('PATH','DIGUP_ACCELERATOR','DIGUP_GPU','DIGUP_MODELS','RUNNER_TEMP','CUDA_PATH','CUDA_HOME','CUDAToolkit_ROOT')) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name)
}
$result = @{ passed=$false; capturedAt=[DateTime]::UtcNow.ToString('o'); physicalValidationAttempted=$true; durationsSeconds=@{} }
function Invoke-Helper([string[]]$Arguments, [string]$Name) {
    $start = [Diagnostics.ProcessStartInfo]::new($helper)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($item in $Arguments) { $start.ArgumentList.Add($item) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$start
    $watch=[Diagnostics.Stopwatch]::StartNew()
    [void]$process.Start()
    $outTask=$process.StandardOutput.ReadToEndAsync(); $errorTask=$process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(180000)) { $process.Kill($true); throw "CUDA check timed out: $Name" }
    $watch.Stop(); $result.durationsSeconds[$Name]=$watch.Elapsed.TotalSeconds
    $stdout=$outTask.GetAwaiter().GetResult(); $stderr=$errorTask.GetAwaiter().GetResult()
    $extension=if($Arguments -contains '--json'){'.json'}else{'.txt'}
    [IO.File]::WriteAllText((Join-Path $Output ($Name+$extension)),$stdout)
    [IO.File]::WriteAllText((Join-Path $Output ($Name+'.log')),$stderr)
    if ($process.ExitCode -ne 0) { throw "$Name failed: $stderr $stdout" }
    return $stdout
}
try {
    $env:PATH = $helperDirectory+';'+$env:SystemRoot+'\System32;'+$env:SystemRoot
    foreach ($name in @('CUDA_PATH','CUDA_HOME','CUDAToolkit_ROOT')) { [Environment]::SetEnvironmentVariable($name,$null) }
    $env:DIGUP_ACCELERATOR='nvidia-cuda'; $env:DIGUP_MODELS=$Models; $env:DIGUP_GPU=$GPU
    $result.windows = Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber
    $result.adapters = @(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID)
    $result.nativeRuntime = Get-Content (Join-Path $helperDirectory 'native-runtime.json') -Raw | ConvertFrom-Json
    $result.cudaRuntime = Get-Content (Join-Path $helperDirectory 'cuda-runtime.json') -Raw | ConvertFrom-Json
    if ($Installer) { $result.installerSHA256 = (Get-FileHash $Installer -Algorithm SHA256).Hash }
    $inventory = (Invoke-Helper @('accelerator','--list','--json') 'discovery') | ConvertFrom-Json
    $eligible = @($inventory.devices | Where-Object { $_.backend -eq 'cuda' -and $_.available -and (!$GPU -or $_.id -eq $GPU -or $_.stableID -eq $GPU) })
    if (!$eligible.Count) { throw 'The selected supported CUDA device is unavailable; inspect discovery.json.' }
    $env:DIGUP_GPU=$eligible[0].stableID
    [void](Invoke-Helper @('accelerator','--json') 'device-probe')
    & $policyTool $helperDirectory 2> (Join-Path $Output 'large-activation.log') | Set-Content (Join-Path $Output 'large-activation.json')
    if ($LASTEXITCODE -ne 0) { throw 'CUDA large-activation/normalization check failed.' }
    $result.physicalCUDA=$true
    & $pythonExe (Join-Path $PSScriptRoot 'check-cuda-reference.py') --helper $helper --models $Models --reference $reference --output $Output
    if ($LASTEXITCODE -ne 0) { throw 'Full CUDA reference/profile/purpose acceptance failed.' }
    $files = Join-Path $Output 'files'; $code = Join-Path $Output 'code'; $index = Join-Path $Output 'index'
    New-Item -ItemType Directory -Force $files,$code | Out-Null
    [IO.File]::WriteAllText((Join-Path $files 'GPU acceptance notes.txt'),'The trip itinerary goes from Tokyo to Kamakura. This is the GPU acceptance document.')
    Copy-Item (Join-Path $reference 'photo.jpg'),(Join-Path $reference 'speech.wav') $files
    [IO.File]::WriteAllText((Join-Path $code 'calculator.py'), ((1..30 | ForEach-Object { "def add_$_(a, b):`n    return a + b`n" }) -join "`n"))
    [void](Invoke-Helper @('index',$files,'--index',$index) 'file-index')
    [void](Invoke-Helper @('index',$code,'--code','--index',$index) 'code-index')
    [void](Invoke-Helper @('search','trip itinerary','--index',$index,'--json') 'file-search')
    [void](Invoke-Helper @('search','code: add numbers','--index',$index,'--json') 'code-search')
    $verify = "import sqlite3,sys,json; from pathlib import Path; root=Path(sys.argv[1])/'nvidia-cuda'; counts={name:sqlite3.connect(root/name).execute('SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL').fetchone()[0] for name in ['index.sqlite','code.sqlite']}; print(json.dumps(counts)); assert all(counts.values())"
    & $pythonExe -c $verify $index | Set-Content (Join-Path $Output 'stored-vectors.json')
    if ($LASTEXITCODE -ne 0) { throw 'File/code CUDA vectors were not persisted in the isolated indexes.' }
    # Model-independent Shell activation/lifetime check with the selected CUDA preference.
    $env:RUNNER_TEMP=$Output
    Copy-Item (Join-Path $PSScriptRoot 'DigUp App Launch Fixture.exe') (Join-Path $Output 'DigUp App Launch Fixture.exe')
    & (Join-Path $PSScriptRoot 'check-windows-applications.ps1') -Backend nvidia-cuda -InstalledApp (Join-Path $InstallDirectory 'DigUp.exe') -Models $Models
    $result.passed=$true
} catch {
    $result.error=$_.Exception.Message
    throw
} finally {
    $result | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $Output 'hardware-summary.json')
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name,$previous[$name]) }
}
