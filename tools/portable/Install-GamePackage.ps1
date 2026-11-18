#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$PackageDirectory = $PSScriptRoot,
    [switch]$Apply,
    [switch]$DisableOtherAddons,
    [string]$RestoreReceipt
)
$ErrorActionPreference = 'Stop'
function Hash([string]$path) { if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }; return $null }
function Child-Path([string]$base, [string]$relative) {
    $parent = [IO.Path]::GetFullPath($base).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $parent $relative))
    if (-not $path.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes target: $relative" }
    return $path
}
function Assert-Stopped([string]$exe) {
    foreach ($process in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exe)) -ErrorAction SilentlyContinue)) {
        # If identity is inaccessible, do not assume it is safe to write.
        if (-not $process.Path -or $process.Path -ieq $exe) { throw "Close the game before deployment: $exe" }
    }
}
if ($RestoreReceipt) {
    $receiptFile = (Resolve-Path -LiteralPath $RestoreReceipt).Path
    $receipt = Get-Content -LiteralPath $receiptFile -Raw | ConvertFrom-Json
    if ($receipt.schema -ne 1) { throw 'Unsupported receipt schema.' }
    Assert-Stopped $receipt.gameExe
    $target = Split-Path $receipt.gameExe -Parent
    $backup = Split-Path $receiptFile -Parent
    # Validate every path and both hashes BEFORE restoring anything.
    foreach ($entry in $receipt.files) {
        $dest = Child-Path $target $entry.path
        if ((Hash $dest) -ne $entry.after) { throw "Changed since installation; refusing restore: $dest" }
        if ($entry.before -and (Hash (Child-Path $backup $entry.path)) -ne $entry.before) { throw "Backup corrupt: $($entry.path)" }
    }
    if (-not $Apply) { Write-Output "Restore plan: $($receipt.files.Count) files. Add -Apply to restore."; return }
    foreach ($entry in $receipt.files) {
        $dest = Child-Path $target $entry.path
        if ($entry.before) { Copy-Item -LiteralPath (Child-Path $backup $entry.path) -Destination $dest -Force }
        elseif (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest }
    }
    Write-Output 'Restored files. Empty directories and backup receipts retained.'
    return
}
$package = (Resolve-Path -LiteralPath $PackageDirectory).Path
$manifest = Get-Content -LiteralPath "$package/manifest.json" -Raw | ConvertFrom-Json
if ($manifest.schema -ne 1 -or -not (Test-Path -LiteralPath $manifest.gameExe -PathType Leaf)) { throw 'Invalid package target/schema.' }
$target = Split-Path $manifest.gameExe -Parent
$payload = Join-Path $package 'payload'
$writes = [ordered]@{}
foreach ($entry in $manifest.files) {
    $source = Child-Path $payload $entry.path
    $null = Child-Path $target $entry.path
    if ((Hash $source) -ne $entry.sha256) { throw "Package hash mismatch: $($entry.path)" }
    $writes[$entry.path] = [IO.File]::ReadAllBytes($source)
}
# ReShade itself is never copied or renamed: the user chooses its supported loader.
$loaderFound = $false
foreach ($name in @('dxgi.dll','d3d12.dll','d3d11.dll')) {
    $candidate = Join-Path $target $name
    if ((Test-Path -LiteralPath $candidate) -and (Get-Item -LiteralPath $candidate).VersionInfo.ProductName -match 'ReShade') { $loaderFound = $true }
}
if (-not $loaderFound) { throw 'Install a compatible add-on-enabled ReShade first. Existing proxy DLLs will not be replaced.' }
$conflicts = @(Get-ChildItem -LiteralPath $target -File | Where-Object { $_.Extension -in @('.addon64','.addon32') -and $_.Name -ne 'nvngx.dll_mgpu_bridge.addon64' })
$rootRuntime = Join-Path $target 'nvngx_dlssnr.dll'
if (Test-Path -LiteralPath $rootRuntime) { $conflicts += Get-Item -LiteralPath $rootRuntime }
if ($conflicts.Count -and -not $DisableOtherAddons) { throw "Conflicting add-ons/root NR runtime: $($conflicts.Name -join ', '). Review them and explicitly pass -DisableOtherAddons to back up and remove them." }
# Preserve the game's existing ReShade configuration; add only a shader search path.
$iniPath = Join-Path $target 'ReShade.ini'
$ini = if (Test-Path -LiteralPath $iniPath) { [IO.File]::ReadAllText($iniPath) } else { '' }
# Remove explicit early-load requests only for disabled or missing add-ons.
# Otherwise ReShade keeps trying to load a mod removed by this deployment.
$ini = [regex]::Replace($ini, '(?m)^LoadFromDllMain=([^\r\n]*)', [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    $kept = @($match.Groups[1].Value -split ',' | Where-Object {
        $name = $_.Trim()
        $name -and $name -notin $conflicts.Name -and ((Test-Path -LiteralPath (Join-Path $target $name)) -or $name -eq 'nvngx.dll_mgpu_bridge.addon64')
    })
    return 'LoadFromDllMain=' + ($kept -join ',')
})
$generalPattern = '(?ms)^\[GENERAL\][^\r\n]*\r?\n(?<body>.*?)(?=^\[|\z)'
$general = [regex]::Match($ini, $generalPattern)
$searchPath = '.\reshade-shaders\Shaders\**'
if ($general.Success) {
    $body = $general.Groups['body'].Value
    $match = [regex]::Match($body, '(?m)^EffectSearchPaths=([^\r\n]*)')
    if ($match.Success) {
        $paths = $match.Groups[1].Value -split ','
        if ($paths -notcontains $searchPath) { $body = $body.Remove($match.Index, $match.Length).Insert($match.Index, $match.Value + ',' + $searchPath) }
    } else { $body = "EffectSearchPaths=$searchPath`r`n" + $body }
    $ini = $ini.Remove($general.Groups['body'].Index, $general.Groups['body'].Length).Insert($general.Groups['body'].Index, $body)
} else { $ini = "[GENERAL]`r`nEffectSearchPaths=$searchPath`r`n" + $ini }
$writes['ReShade.ini'] = [Text.UTF8Encoding]::new($false).GetBytes($ini)
$changes = @($writes.Keys) + @($conflicts | ForEach-Object Name)
Write-Output "Target: $($manifest.gameExe)"
Write-Output "Profile: $($manifest.profile); writes: $($writes.Count); disabled files: $($conflicts.Count)"
if (-not $Apply) { Write-Output 'Plan only. Add -Apply to back up and install. GPU/graphics settings are not changed.'; return }
Assert-Stopped $manifest.gameExe
$backup = Join-Path $target ('mgpu-profile-backups/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$entries = @()
foreach ($relative in $changes) {
    $dest = Child-Path $target $relative
    $before = Hash $dest
    if ($before) {
        $saved = Child-Path $backup $relative
        New-Item -ItemType Directory -Path (Split-Path $saved -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $dest -Destination $saved
        if ((Hash $saved) -ne $before) { throw "Backup verification failed: $relative" }
    }
    $after = if ($writes.Contains($relative)) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$writes[$relative])) } else { $null }
    $entries += [ordered]@{path=$relative;before=$before;after=$after}
}
$receipt = [ordered]@{schema=1;gameExe=$manifest.gameExe;files=$entries}
$receiptPath = Join-Path $backup 'receipt.json'
$receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
try {
    foreach ($relative in $writes.Keys) {
        $dest = Child-Path $target $relative
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        [IO.File]::WriteAllBytes($dest, [byte[]]$writes[$relative])
    }
    foreach ($file in $conflicts) { Remove-Item -LiteralPath $file.FullName }
    foreach ($entry in $entries) { if ((Hash (Child-Path $target $entry.path)) -ne $entry.after) { throw "Write verification failed: $($entry.path)" } }
} catch {
    $failure = $_
    # Roll back this attempt using backups verified before the first write.
    foreach ($entry in $entries) {
        $dest = Child-Path $target $entry.path
        if ($entry.before) { Copy-Item -LiteralPath (Child-Path $backup $entry.path) -Destination $dest -Force }
        elseif (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest }
    }
    throw $failure
}
Write-Output "Installed and verified. Restore receipt: $receiptPath"
