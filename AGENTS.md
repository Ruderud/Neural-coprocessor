# Agent guidance

- This fork keeps MGPU Bridge usable across supported DX11/DX12 games. Do not hardcode game names, executable hashes, GPU model names, user paths, or adapter enumeration indices into runtime policy.
- Preserve upstream licenses, GPU synchronization, adapter identity checks, and failure reporting. No anti-cheat bypasses.
- Keep hardware/quality preferences in portable profiles and local game deployment data outside tracked source.
- NVIDIA runtimes/models and ReShade binaries are user-supplied, never committed.
- Before game deployment, back up changed files and detect conflicting add-ons. Do not silently disable existing mods or change game graphics settings.
- Validate C++ changes with a Release build and CTest (`MGPU_BUILD_TESTS=ON`). Validate packaging with `tests/game_package_test.ps1` and review `git diff --check`.
- Report build/package tests separately from actual in-game correctness, image quality, latency and FPS. No universal compatibility or performance claims.
- Use additive commits and normal pushes. Never merge or force-push without the user's explicit approval.
