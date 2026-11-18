#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('mgpu-package-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$scratch/game", "$scratch/input" -Force | Out-Null
function Check($condition, $message) { if (-not $condition) { throw $message } }
function Must-Fail([scriptblock]$action, [string]$message) {
    $failed = $false
    try { & $action | Out-Null } catch { $failed = $true }
    Check $failed $message
}
try {
    $game = "$scratch/game/Example.exe"
    Set-Content -LiteralPath $game -Value 'test executable placeholder'
    Set-Content -LiteralPath "$scratch/input/bridge.addon64" -Value 'test bridge'
    Set-Content -LiteralPath "$scratch/input/nvngx_dlssnr.dll" -Value 'test runtime'
    # Mock only loader version metadata; never load a real graphics DLL in tests.
    Set-Content -LiteralPath "$scratch/game/dxgi.dll" -Value 'test loader'
    function Get-Item {
        [CmdletBinding()] param([string]$LiteralPath)
        if ([IO.Path]::GetFullPath($LiteralPath) -eq [IO.Path]::GetFullPath("$scratch/game/dxgi.dll")) { return [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductName='ReShade'}} }
        Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
    }
    $originalIni = "[ADDON]`r`nSomeSetting=keep`r`n[GENERAL]`r`nEffectSearchPaths=.\custom\**`r`nPresetPath=.\MyPreset.ini`r`n"
    [IO.File]::WriteAllText("$scratch/game/ReShade.ini", $originalIni)
    Set-Content -LiteralPath "$scratch/game/other.addon64" -Value 'existing mod'
    Set-Content -LiteralPath "$scratch/game/nvngx_dlssnr.dll" -Value 'existing root runtime'
    $package = "$scratch/package"
    & "$root/tools/portable/New-GamePackage.ps1" -GameExe $game -OutputDirectory $package -AddonPath "$scratch/input/bridge.addon64" -RuntimePath "$scratch/input/nvngx_dlssnr.dll" -Profile native-two-pass -Display '\\.\DISPLAY1'
    $ini = Get-Content -LiteralPath "$package/payload/mgpu.ini" -Raw
    Check ($ini -match '(?m)^Passes=2\r?$') 'two-pass profile missing'
    Check ($ini -match '(?m)^BestQuality=0\r?$') 'upstream auto-preset overrides custom settings'
    Check ($ini -match '(?m)^Pass2=full\r?$' -and $ini -match '(?m)^Intensity2=1.0\r?$') 'second-pass configuration invalid'
    Check (([regex]::Matches($ini, '(?m)^Passes=')).Count -eq 1) 'duplicate INI keys'
    Check ((Get-Content -LiteralPath "$scratch/game/ReShade.ini" -Raw) -eq $originalIni) 'staging modified game'
    $installer = "$root/tools/portable/Install-GamePackage.ps1"
    Must-Fail { & $installer -PackageDirectory $package -Apply } 'conflicting add-ons were not rejected'
    & $installer -PackageDirectory $package -DisableOtherAddons
    Check (Test-Path -LiteralPath "$scratch/game/other.addon64") 'plan modified game'
    & $installer -PackageDirectory $package -DisableOtherAddons -Apply
    Check (-not (Test-Path -LiteralPath "$scratch/game/other.addon64")) 'conflict not disabled'
    Check (-not (Test-Path -LiteralPath "$scratch/game/nvngx_dlssnr.dll")) 'root runtime not removed'
    Check (Test-Path -LiteralPath "$scratch/game/mgpu/nvngx_dlssnr.dll") 'runtime missing'
    $installedIni = Get-Content -LiteralPath "$scratch/game/ReShade.ini" -Raw
    Check ($installedIni.Contains('SomeSetting=keep') -and $installedIni.Contains('PresetPath=.\MyPreset.ini')) 'existing ReShade settings lost'
    Check ($installedIni.Contains('EffectSearchPaths=.\custom\**,.\reshade-shaders\Shaders\**')) 'shader path not merged'
    $receipt = (Get-ChildItem -LiteralPath "$scratch/game/mgpu-profile-backups" -Recurse -Filter receipt.json).FullName
    $installedHash = (Get-FileHash -LiteralPath "$scratch/game/mgpu.ini").Hash
    Add-Content -LiteralPath "$scratch/game/mgpu.ini" -Value '; player edit'
    Must-Fail { & $installer -RestoreReceipt $receipt -Apply } 'restore overwrote player edit'
    Copy-Item -LiteralPath "$package/payload/mgpu.ini" -Destination "$scratch/game/mgpu.ini" -Force
    Check ((Get-FileHash -LiteralPath "$scratch/game/mgpu.ini").Hash -eq $installedHash) 'fixture not restored'
    & $installer -RestoreReceipt $receipt -Apply
    Check ((Get-Content -LiteralPath "$scratch/game/ReShade.ini" -Raw) -eq $originalIni) 'original INI not restored exactly'
    Check ((Get-Content -LiteralPath "$scratch/game/other.addon64" -Raw).Trim() -eq 'existing mod') 'original mod not restored'
    Check (-not (Test-Path -LiteralPath "$scratch/game/nvngx.dll_mgpu_bridge.addon64")) 'new add-on not removed'
    Add-Content -LiteralPath "$package/payload/mgpu.ini" -Value '; tamper'
    Must-Fail { & $installer -PackageDirectory $package -DisableOtherAddons -Apply } 'package tampering accepted'
    $manifestFile = "$package/manifest.json"
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    $manifest.files[0].path = '..\..\escape.dll'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestFile
    Must-Fail { & $installer -PackageDirectory $package -DisableOtherAddons -Apply } 'path traversal accepted'
    Write-Output 'PASS: staging, profiles, conflicts, plan, deployment, setting preservation, restore, player edits, integrity and traversal.'
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if ([IO.Path]::GetDirectoryName($resolved) -ne $expectedParent -or [IO.Path]::GetFileName($resolved) -notmatch '^mgpu-package-test-[a-f0-9]{32}$') { throw 'Unexpected cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
