Gears of War: E-Day VR (UEVR)
=============================

Campaign only.

You need: the game (Steam or Xbox app), SteamVR, a connected headset.
In SteamVR > Settings > OpenXR, SteamVR must be the active OpenXR runtime.

1. Copy this whole folder anywhere (keep its files together).
2. Run GoWEDay_VR.exe.
3. Game folder or game exe: type or paste a path, or press Browse... and either pick the exe,
   or open the game folder and press Open.
   The folder can have any name; the launcher finds the game exe inside it.
   Examples (Steam):
     folder: C:\Program Files (x86)\Steam\steamapps\common\GoWEDay
     exe:    C:\Program Files (x86)\Steam\steamapps\common\GoWEDay\FairlightConcept\Binaries\Win64\GoWEDay-Steam.exe
   Examples (Xbox app, installed in a folder you chose, e.g. D:\Games\gow):
     folder: D:\Games\gow
     exe:    D:\Games\gow\Content\FairlightConcept\Binaries\WinGDK\GoWEDay-WinGDK-Shipping.exe
             (usual Xbox app layout; the exact folder and exe name can differ, any name works)
   Do not pick start_protected_game.exe or gamelaunchhelper.exe: those are launchers, not the game
   (if you do, the launcher searches their folder for the game exe).
4. Tick Windowed to play in a window (the game keeps its own resolution).
   The headset image is the same; a window lets you Alt+Tab.
   Load global UEVR plugins: only if you use plugins from UEVR's global plugins folder (off by default; some can break the start).
   VR runtime: SteamVR (default) or Virtual Desktop (VDXR). For VDXR, pick VDXR as the OpenXR runtime in the Virtual Desktop Streamer settings. VDXR is new and less tested: tell us how it works.
5. Press Start. Folder and options are saved in path.txt; next time just press Start.

Start launches SteamVR if needed, starts the game without Easy Anti-Cheat (offline/campaign only),
loads the virtual gamepad for the VR controllers and injects UEVR on OpenXR.
On the title screen, hold X (left controller) to enter offline mode.
In game: the mod's options are in VR SETTINGS in the pause menu; Insert on the keyboard = UEVR menu (advanced).

What it changes on your PC:
- Steam copy only: creates steam_appid.txt next to the game exe (otherwise the game asks to relaunch via Steam);
- on first start copies the mod profile (profile folder) to %APPDATA%\UnrealVRMod\<game exe name> (asks first);
- sets this folder's UEVR injector to OpenXR.
The game's own graphics settings are not changed: windowed / full screen is only a launch argument.
