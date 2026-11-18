#requires -Version 7.2
[CmdletBinding()]
param([string]$CMakePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $CMakePath) {
    $command = Get-Command cmake -ErrorAction SilentlyContinue
    if ($command) { $CMakePath = $command.Source }
    else {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $vs) { throw 'Visual Studio C++ tools not found.' }
        $CMakePath = Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    }
}
if (-not (Test-Path -LiteralPath $CMakePath)) { throw 'CMake not found. Supply -CMakePath.' }
$workflow = Get-Content -LiteralPath "$root/.github/workflows/build.yml" -Raw
foreach ($dependency in @(
    @{key='RESHADE_SHA';repo='crosire/reshade';folder='reshade';header='reshade.hpp'},
    @{key='NGX_SHA';repo='NVIDIA/DLSS';folder='ngx';header='nvsdk_ngx.h'}
)) {
    $pin = [regex]::Match($workflow, '(?m)^\s*' + $dependency.key + ':\s*([a-f0-9]{40})\s*$').Groups[1].Value
    if (-not $pin) { throw "Missing upstream dependency pin: $($dependency.key)" }
    $destination = "$root/ext/$($dependency.folder)"
    $stamp = "$destination/.mgpu-pin"
    if (Test-Path -LiteralPath $destination) {
        if (-not (Test-Path -LiteralPath $stamp) -or (Get-Content -LiteralPath $stamp -Raw).Trim() -ne $pin) {
            throw "Unverified existing headers: $destination. Move them aside before fetching pinned headers."
        }
    } else {
        New-Item -ItemType Directory -Path "$root/_dl", "$root/ext" -Force | Out-Null
        $archive = "$root/_dl/$($dependency.folder)-$pin.tar.gz"
        Invoke-WebRequest "https://codeload.github.com/$($dependency.repo)/tar.gz/$pin" -OutFile $archive
        $top = (& tar -tzf $archive | Select-Object -First 1).TrimEnd('/')
        if ($LASTEXITCODE -ne 0 -or $top -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Unexpected source archive root.' }
        & tar -xzf $archive -C "$root/_dl" "$top/include"
        if ($LASTEXITCODE -ne 0) { throw 'Header extraction failed.' }
        Move-Item -LiteralPath "$root/_dl/$top/include" -Destination $destination
        Set-Content -LiteralPath $stamp -Value $pin -NoNewline
    }
    if (-not (Test-Path -LiteralPath "$destination/$($dependency.header)")) { throw 'Required header missing.' }
}
if (-not (Select-String -LiteralPath "$root/ext/reshade/reshade.hpp" -Pattern '#define RESHADE_API_VERSION 20' -Quiet)) { throw 'Unexpected ReShade API pin.' }
if (-not (Select-String -LiteralPath "$root/ext/ngx/nvsdk_ngx_defs.h" -Pattern 'NVSDK_NGX_Feature_Reserved18' -Quiet)) { throw 'NR feature missing from NGX headers.' }
& $CMakePath -S $root -B "$root/build" -A x64 -DMGPU_BUILD_TESTS=ON
if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed.' }
& $CMakePath --build "$root/build" --config Release --parallel
if ($LASTEXITCODE -ne 0) { throw 'C++ build failed.' }
$ctest = Join-Path (Split-Path $CMakePath -Parent) 'ctest.exe'
& $ctest --test-dir "$root/build" -C Release --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'CTest failed.' }
& "$root/tests/game_package_test.ps1"
Write-Output "Built: $root/build/mgpu_bridge.addon64"
