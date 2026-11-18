#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GameExe,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$AddonPath,
    [Parameter(Mandatory)][string]$RuntimePath,
    [string]$Profile = 'native-quality',
    [string]$Display,
    [string]$OverridesPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach ($file in @($GameExe, $AddonPath, $RuntimePath)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "File not found: $file" }
}
if ([IO.Path]::GetExtension($GameExe) -ine '.exe') { throw 'GameExe must name the actual game executable.' }
if ($Profile -notmatch '^[a-z0-9-]+$') { throw 'Invalid profile name.' }
$profileFile = Join-Path $root "profiles/$Profile.json"
$settings = (Get-Content -LiteralPath $profileFile -Raw | ConvertFrom-Json).settings
$config = Get-Content -LiteralPath (Join-Path $root 'assets/mgpu.ini') -Raw
function Set-Key([string]$text, [string]$key, [string]$value) {
    if ($key -notmatch '^[A-Za-z][A-Za-z0-9_]*$' -or $value -match '[\r\n]') { throw 'Invalid INI override.' }
    $pattern = '(?m)^' + [regex]::Escape($key) + '=[^\r\n]*'
    if ([regex]::IsMatch($text, $pattern)) {
        return [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{param($m) "$key=$value"})
    }
    return $text.TrimEnd() + "`r`n$key=$value`r`n"
}
foreach ($property in $settings.PSObject.Properties) { $config = Set-Key $config $property.Name ([string]$property.Value) }
if ($OverridesPath) {
    $overrides = Get-Content -LiteralPath $OverridesPath -Raw | ConvertFrom-Json
    foreach ($property in $overrides.PSObject.Properties) { $config = Set-Key $config $property.Name ([string]$property.Value) }
}
if ($Display) {
    if ($Display -notmatch '^\\\\\.\\DISPLAY[0-9]+$') { throw 'Display must be a Windows GDI display name, e.g. \\.\DISPLAY1.' }
    $config = Set-Key $config 'Display' $Display
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output already exists; choose a new directory: $output" }
New-Item -ItemType Directory -Path $output | Out-Null
$payload = Join-Path $output 'payload'
New-Item -ItemType Directory -Path "$payload/mgpu", "$payload/reshade-shaders/Shaders" -Force | Out-Null
Copy-Item -LiteralPath $AddonPath -Destination "$payload/nvngx.dll_mgpu_bridge.addon64"
Copy-Item -LiteralPath $RuntimePath -Destination "$payload/mgpu/nvngx_dlssnr.dll"
Copy-Item -LiteralPath "$root/assets/gpu1.ini", "$root/assets/ReShade2.ini" -Destination $payload
Copy-Item -LiteralPath "$root/assets/reshade-shaders/Shaders/mgpu_depth_tap.fx" -Destination "$payload/reshade-shaders/Shaders"
[IO.File]::WriteAllText("$payload/mgpu.ini", $config, [Text.UTF8Encoding]::new($false))
$files = @(Get-ChildItem -LiteralPath $payload -Recurse -File | ForEach-Object {
    [ordered]@{ path = $_.FullName.Substring($payload.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
$manifest = [ordered]@{
    schema = 1; gameExe = (Resolve-Path -LiteralPath $GameExe).Path
    profile = $Profile; files = $files
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$output/manifest.json" -Encoding UTF8
Copy-Item -LiteralPath "$PSScriptRoot/Install-GamePackage.ps1" -Destination $output
Write-Output "Staged: $output"
Write-Output 'No game files changed. Run Install-GamePackage.ps1 -PackageDirectory <this directory> for a read-only plan.'
