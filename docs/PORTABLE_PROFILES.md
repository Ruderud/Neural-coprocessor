# Portable game profiles

This fork adds reusable configuration and reversible deployment around upstream MGPU Bridge. It does not contain the private hybrid application from the community screenshots, import NR Nexus code, or claim every game works. Runtime GPU selection, synchronization and rendering remain upstream code.

## Hardware and scope

Use a supported NVIDIA neural GPU and a separate render GPU. Two identical RTX 5090s are supported by the same adapter-identity policy as other pairs; model names and GPU enumeration indices are not hardcoded. For upstream single-display mode, connect the monitor to the neural GPU and keep the game-rendering GPU headless. Verify actual roles in ReShade.log. Windows graphics preferences can be ignored by Unreal games; upstream documents `-graphicsadapter=N`, where N comes from that game's adapter enumeration. An NVIDIA-SMI index is not necessarily the same index.

This is a DX11/DX12 path, not universal Vulkan support. The game's own depth/motion-vector contract and ReShade compatibility still matter. No anti-cheat is disabled or bypassed. A game blocking add-ons remains unsupported by this workflow.

## Profiles

Both profiles inherit `assets/mgpu.ini` and override only the listed keys:

- `native-quality`: full-output-resolution NR, Full-FP8 model, one pass, intensity 1.0. Game-side DLSS/DLAA and graphics settings remain unchanged.
- `native-two-pass`: Light-FP8 then Full-FP8, two native-resolution passes. Experimental, more work, no promise of better visuals. Requires a compatible model runtime.

Frame generation stays off during initial validation. Start in gameplay, then press Ctrl+Alt+F10 to arm manually. Auto-arming and upstream's automatic quality preset are disabled so they cannot hide startup failures or replace your selected pass settings. HDR follows upstream `ChainColorSpace=auto`, which is experimental; this is not a verified RenoDX HDR integration.

Neither 4K nor a monitor refresh rate is forced into the game. Keep the desired game resolution and quality in the game itself; this preserves use on other displays. There is no power-limit or overclock adjustment.

## Stage a game package (PowerShell 7.2 or newer)

Run `./tools/portable/Build.ps1` with Visual Studio C++/CMake and Windows SDK installed. It fetches public headers using the pins from upstream's `.github/workflows/build.yml`, builds Release and runs CTest plus packaging tests. An explicit `-CMakePath` is supported. The output is `build/mgpu_bridge.addon64`. Supply your own compatible NVIDIA runtime; it is never downloaded by these tools.

```powershell
./tools/portable/New-GamePackage.ps1 `
  -GameExe 'D:\Games\Example\Game.exe' `
  -AddonPath './build/mgpu_bridge.addon64' `
  -RuntimePath 'D:\MyRuntimes\nvngx_dlssnr.dll' `
  -Profile native-quality `
  -OutputDirectory './build/packages/example'
```

Optional `-Display '\\.\DISPLAY1'` uses upstream's display-to-adapter binding. Check the active GDI display name first; do not guess from GPU numbering. Optional `-OverridesPath '<local.json>'` accepts an object of INI key/value overrides. These are advanced upstream settings, not a capability validator. Staging never changes game files and refuses to overwrite an existing package directory.

Packages contain the supplied runtime and an absolute local target path: keep them local and out of git. The generator stores exact payload hashes. It does not prove NVIDIA provenance, model support, or game compatibility.

## Plan, install and restore

Install compatible full-add-on ReShade separately. The tool recognizes its version metadata on dxgi/d3d11/d3d12 proxy DLLs; that is only a presence check, not proof of API support. Existing proxy DLLs are never overwritten. Configure any custom add-on search directories yourself; the tool inspects conflicting add-ons in the executable directory only.

```powershell
# No game changes; checks payload hashes and reports the target.
./tools/portable/Install-GamePackage.ps1 -PackageDirectory './build/packages/example'

# If existing add-ons/root NR DLL are reported, review them first.
# Explicitly disable them only when moving NR ownership to the bridge.
./tools/portable/Install-GamePackage.ps1 -PackageDirectory './build/packages/example' `
  -DisableOtherAddons -Apply

# The installer prints the actual receipt path. Preview restoration first.
./tools/portable/Install-GamePackage.ps1 -RestoreReceipt '<printed receipt.json>'
./tools/portable/Install-GamePackage.ps1 -RestoreReceipt '<printed receipt.json>' -Apply
```

Application refuses a running target, verifies backups, retains ReShade settings and merges the depth-tap shader search path into `[GENERAL]`. Conflicting executable-directory add-ons/root NR DLL are backed up before removal. Existing bridge configuration/presets are backed up before replacement. The tool does not edit Engine.ini, game DLLs in engine plugin folders, game graphics settings, drivers or anti-cheat. Restore validates all deployed hashes and backups before writing and refuses changed files. Keep the receipt/backups; manual edits require manual reconciliation. Concurrent installers or game updaters must not run during deployment.

## Acceptance per game

1. Record same-scene FPS/frametimes with NR off; keep graphics settings fixed.
2. Verify game/render adapter and neural adapter differ in ReShade.log; a visible overlay is not evidence of NR execution.
3. Enable NR at one pass. Verify actual NR evaluation, valid motion/depth, output, menus, input, Alt+Tab and shutdown.
4. Compare flicker, trailing, HUD, HDR and latency while moving. Only then test two passes or upstream frame generation, one change at a time.
5. Keep base rendered FPS separate from generated/display FPS. Do not claim hardware input-to-photon latency from software queue timings.

Game-specific paths and overrides belong to individual local packages. Adding another game does not require changing C++ or matching an executable hash.
