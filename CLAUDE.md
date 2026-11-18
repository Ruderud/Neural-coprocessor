# Project overview

Windows C++17 ReShade add-on: one GPU renders a game, another runs DLSS Neural Rendering and presents the result. This is an upstream-preserving, game-independent customization fork.

## Layout
- `src/`: adapter selection, transport, neural processing, presentation and diagnostics.
- `assets/`: upstream runtime configuration and depth-tap shader.
- `profiles/`: portable settings layered over upstream defaults.
- `tools/portable/`: staging and reversible deployment, no game-name dispatch.
- `tests/`: upstream CPU tests and portable deployment tests.

## Build and validation
Use Visual Studio 2022 C++ Build Tools, Windows SDK and CMake. Fetch headers at the pins in `.github/workflows/build.yml`; no proprietary binaries belong in git.

`cmake -S . -B build -A x64 -DMGPU_BUILD_TESTS=ON`

`cmake --build build --config Release`

`ctest --test-dir build -C Release --output-on-failure`

`pwsh -NoProfile -File tests/game_package_test.ps1`

Portable staging takes an explicit game executable, locally built add-on and user-supplied NR DLL. Keep game-specific overrides outside runtime code. GPU selection remains based on the game's real adapter and display topology, not the RTX model name.
