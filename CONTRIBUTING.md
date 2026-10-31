# Contributing

Campaign only

## Layout

| Path | What |
|---|---|
| `profile/` | The UEVR game profile: `config.txt`, controller bindings and `scripts/`. UEVR runs a copy of it in `%APPDATA%\UnrealVRMod\GoWEDay-Steam\`. |
| `src/UEVR` | Submodule: UEVR fork, branch `eday`. Its `dependencies/submodules/UESDK` points to the UESDK fork, branch `eday`. |
| `tools/launcher/` | `Launcher.cs` (the player's `GoWEDay_VR.exe`) and `make_build.bat`, which builds it and gathers the release files into `build/`. |
| `tools/gameinput_vr/` | `gameinput_vr.dll`: a virtual GameInput gamepad loaded at game start. The game reads gamepads only through GameInput; UEVR feeds it the VR controllers. |
| `tools/` | Dev tools, see below. |

## Scripts (`profile/scripts`)

| Script | What it does |
|---|---|
| `fp.lua` | First-person camera at the eyes, hides the head; turret and cutscene views. |
| `arms.lua` | The body under the camera, arm IK to the controllers, finger curls. |
| `weapon.lua` | Weapon in the right hand, aiming (`VR_AimOverride`), two-hand grip, collisions with world and enemies. |
| `handles.lua` | Extra left-hand handles on big weapons. |
| `gestures.lua` | Physical reloads (magazines, Longshot bolt, Gnasher shells, pistol slide) and weapon switching. It is at Lua's 200-locals limit: put new constants in the `BA` table. |
| `grenade.lua` | Grenades taken from the belt, pin, throw. |
| `saw.lua` | Lancer chainsaw, melee, blood, impacts, glass. |
| `scope.lua` | Longshot scope (a SceneCapture2D captured each frame). |
| `turret.lua` | Mounted turrets aimed with the controller. |
| `sprint.lua` | Sprint on the left trigger. |
| `menu.lua` | Laser pointers and clicks in menus (drawn by the UEVR patch). |
| `aa_xr.lua` | Controller poses (`eday_pose`): every hold is calibrated on the OpenVR grip pose; use it instead of `vr.get_pose`. |
| `aa_assets.lua` | Loads the mod's assets at the end of a loading screen (`VR_LoadAsset`). |
| `zz_debug.lua` | Dev channel for `tools/dbg.sh`, simulated hands. `DEBUG_TOOLS = false` in releases. |
| `zz_hitch.lua`, `aa_prof.lua` | Dev: hitch logger and callback profiler (profiler off by default). |

## Building

- **UEVR**: build `src/UEVR` as upstream UEVR (CMake, Visual Studio 2022, Release). Put an official UEVR runtime
  in `UEVR/` at the repo root (ignored by git) and replace its `UEVRBackend.dll` with the one you built.
- **gameinput_vr.dll**: compile `tools/gameinput_vr/gameinput_vr.cpp` as a DLL (MSVC, C++20) with `GameInput.h`
  from Microsoft's `Microsoft.GameInput` NuGet package (v3).
- **Launcher and release folder**: run `tools/launcher/make_build.bat`. `build/GoWEDay_VR.exe --selftest` checks it.

## Testing a change

1. Edit the scripts in `%APPDATA%\UnrealVRMod\GoWEDay-Steam\scripts` while the game runs.
2. Reload them: create an empty file named `reload_scripts` in that profile folder (the whole Lua state restarts).
3. Run Lua inside the game and read the result: `tools/dbg.sh 'return 1 + 1'` or `tools/dbg.sh -f file.lua`
   (needs `zz_debug.lua` with `DEBUG_TOOLS = true`). Globals go in `_G`.
4. See the headset view without wearing it: `tools/grab_eye.sh name` saves the left eye to `logs/name.png`
   (`burst.sh` for a series). Needs Python 3 with Pillow.
5. Spawn things to test on: `give_weapon.lua`, `turret_spawn.lua`, `spawn_rows_load.lua` (see the comment at the
   top of each).
6. Copy the changed scripts back into `profile/scripts` and open a pull request saying what you tested.

Never call `ReadRenderTargetPixel` from Lua (it crashes the game).
