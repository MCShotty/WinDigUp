param(
    [ValidateSet('auto', 'cpu', 'cuda', 'vulkan', 'cuda,vulkan')][string]$GpuBackends = 'auto',
    [string]$SwiftRuntimeDirectory = '',
    [switch]$SkipApp,
    [switch]$Test
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$previousLocation = Get-Location
$previousBackends = $env:DIGUP_GPU_BACKENDS
$previousPath = $env:Path
function Invoke-Checked([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Build command failed with exit code $LASTEXITCODE" }
}
try {
    Set-Location $root
    foreach ($tool in @('swift', 'cmake', 'git', 'python')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is missing from PATH. See windows/README.md." }
    }
    if (-not (Get-Command cl -ErrorAction SilentlyContinue)) { throw 'Run this in an x64 Visual Studio Developer PowerShell.' }
    $bash = Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
    if (-not (Test-Path $bash)) { throw 'Install Git for Windows (its bash is used by the vendor scripts).' }
    $env:DIGUP_GPU_BACKENDS = $GpuBackends
    Invoke-Checked { & $bash --noprofile --norc scripts/fetch-vendor.sh }
    Invoke-Checked { & $bash --noprofile --norc scripts/build-llama.sh }
    # Windows has no rpath: Swift's test runner also needs the native dependencies before the
    # final packaging step copies them beside digup.exe.
    $env:Path = "$root/Vendor/llama/lib;$root/Vendor/pdfium/bin;$env:Path"
    Invoke-Checked { swift build -c release }
    if ($Test) { Invoke-Checked { swift test } }
    $bin = (swift build -c release --show-bin-path | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not locate the Swift binary.' }
    $artifact = Join-Path $root 'windows/artifacts/WinDigUp'
    $helper = Join-Path $artifact 'helper'
    if (Test-Path $artifact) { Remove-Item $artifact -Recurse -Force }
    New-Item $helper -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $bin 'digup.exe') $helper
    Copy-Item 'Vendor/llama/lib/*.dll' $helper
    Copy-Item 'Vendor/pdfium/bin/*.dll' $helper

    # Swift's installer puts its shared runtime outside the toolchain. Look only in known runtime
    # paths and their bin folders; a supplied path is useful for custom toolchain layouts.
    $target = swiftc -print-target-info | ConvertFrom-Json
    $runtimeCandidates = @($SwiftRuntimeDirectory)
    $runtimeCandidates += @($target.paths.runtimeLibraryPaths)
    $runtimeCandidates += @((Split-Path (Get-Command swift).Source -Parent))
    $runtimeCandidates += @($env:Path -split ';' | Where-Object { $_ -match 'Swift.*(Runtime|usr)' })
    foreach ($candidate in @($runtimeCandidates)) {
        if (-not $candidate) { continue }
        $parent = $candidate
        for ($level = 0; $level -lt 5 -and $parent; $level++) {
            $runtimeCandidates += (Join-Path $parent 'bin')
            $parent = Split-Path $parent -Parent
        }
    }
    foreach ($candidate in ($runtimeCandidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path $candidate)) {
            Get-ChildItem $candidate -Filter '*.dll' -File | ForEach-Object { Copy-Item $_.FullName $helper -Force }
        }
    }
    if (-not (Test-Path (Join-Path $helper 'swiftCore.dll'))) {
        throw 'Swift runtime DLLs were not found. Pass -SwiftRuntimeDirectory with the installed runtime usr/bin folder.'
    }
    if ($env:CUDA_PATH -and $GpuBackends -ne 'cpu' -and $GpuBackends -ne 'vulkan') {
        foreach ($pattern in @('cudart64*.dll', 'cublas64*.dll', 'cublasLt64*.dll')) {
            Get-ChildItem (Join-Path $env:CUDA_PATH 'bin') -Filter $pattern -File | ForEach-Object { Copy-Item $_.FullName $helper -Force }
        }
    }
    New-Item (Join-Path $artifact 'worker') -ItemType Directory -Force | Out-Null
    Copy-Item 'worker/windows/openvino_worker.py' (Join-Path $artifact 'worker')
    Copy-Item 'Resources/Acknowledgements.txt', 'LICENSE' $artifact
    if (-not $SkipApp) {
        Invoke-Checked { dotnet run --project windows/WinDigUp.Core.Tests -c Release }
        Invoke-Checked { dotnet publish windows/WinDigUp/WinDigUp.csproj -c Release -p:Platform=x64 --self-contained true -o $artifact }
    }
    Write-Host "Built into $artifact"
} finally {
    $env:DIGUP_GPU_BACKENDS = $previousBackends
    $env:Path = $previousPath
    Set-Location $previousLocation
}
