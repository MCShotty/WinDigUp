param(
    [Parameter(Mandatory = $true)][string]$PackageDirectory,
    [ValidateSet('cpu', 'vulkan')][string]$Backend = 'cpu'
)
$ErrorActionPreference = 'Stop'
$previousPath = $env:Path
try {
    $package = (Resolve-Path $PackageDirectory).Path
    $helper = Join-Path $package 'helper'
    $env:Path = "$env:SystemRoot/System32;$env:SystemRoot"
    & (Join-Path $helper 'digup.exe') --help
    if ($LASTEXITCODE -ne 0) { throw 'Packaged helper could not start with its bundled libraries.' }
    if ($Backend -eq 'vulkan') {
        foreach ($library in @('ggml-vulkan.dll', 'vulkan-1.dll')) {
            if (-not (Test-Path (Join-Path $helper $library))) { throw "AMD package is missing $library." }
        }
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinDigUpPackageProbe {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
}
'@
        # Search beside this module and in Windows' default DLL directories, without the SDK or PATH.
        $module = [WinDigUpPackageProbe]::LoadLibraryEx((Join-Path $helper 'ggml-vulkan.dll'), [IntPtr]::Zero, 0x1100)
        if ($module -eq [IntPtr]::Zero) {
            throw "Packaged Vulkan backend could not load; Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
        }
        try {
            if ([WinDigUpPackageProbe]::GetProcAddress($module, 'ggml_backend_init') -eq [IntPtr]::Zero) {
                throw 'Packaged Vulkan library does not expose the ggml backend entry point.'
            }
            Write-Host 'Verified packaged Vulkan backend and loader without the development SDK. GPU inference requires an AMD device.'
        } finally { [void][WinDigUpPackageProbe]::FreeLibrary($module) }
    }
} finally { $env:Path = $previousPath }
