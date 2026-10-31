# Gears of War: E-Day VR (Early Access)

<a href="https://ko-fi.com/rockonthehill"><img src="https://storage.ko-fi.com/cdn/kofi2.png?v=3" height="40" alt="Support me on Ko-fi"></a>

If you enjoy the mod, you can support its development on **[Ko-fi](https://ko-fi.com/rockonthehill)**.

> [!WARNING]
> **WORK IN PROGRESS: NOT A FINAL RELEASE.**
> The mod is still in development. Expect bugs and unfinished features.

A full first-person VR mod for **Gears of War: E-Day** (PC), built on a patched
[UEVR](https://github.com/praydog/UEVR) by praydog.

> **CAMPAIGN ONLY.** The game uses Easy Anti-Cheat; the launcher starts the game
> offline without it, for the single-player campaign. Using a modded game online can get your account banned.

## Requirements

- Gears of War: E-Day on Steam (the Xbox app version is untested). A legal copy.
- A PC VR headset and SteamVR, with SteamVR set as the active OpenXR runtime
  (SteamVR > Settings > OpenXR).

## Install

1. Download the latest zip from [Releases](../../releases) and unzip it anywhere.
2. Run `GoWEDay_VR.exe`, pick the game folder or exe, tick Windowed if you want a window, press **Start**.
3. On the title screen, **hold X** (left controller) to enter offline mode.
4. In game, the mod's options are in **VR SETTINGS** in the pause menu. `Insert` on the keyboard opens the UEVR menu (advanced).

## Runs on OpenXR

The mod renders through **OpenXR**: it uses the OpenXR runtime you set active
(for SteamVR: SteamVR > Settings > OpenXR > Set SteamVR as OpenXR Runtime).

> [!TIP]
> **For more FPS:**
> - turn on **DLSS** or lower the **graphics settings** in the game's own options;
> - try **[OFXR-Bridge](https://github.com/tig3rmast3r/OFXR-Bridge)** (a third-party tool by tig3rmast3r, not part of this mod).

## What it does

The mod turns the campaign into a full first-person VR game:

- You see the world through your character's eyes, with your own hands and body in VR.
- Weapons are held and aimed with the motion controllers, with two-handed grips.
- Physical interactions: reloading by hand, melee, the chainsaw, mounted guns.
- Menus are used with laser pointers from the controllers.
- A **VR SETTINGS** entry in the pause menu: primary hand, smooth or snap turning, button mapping.

It is built on a patched UEVR and runs on OpenXR.

## Current status

The mod is a **work in progress**. Bugs and unfinished parts are expected.

- So far it has been played and tested **only as Marcus** in the campaign. Other playable characters or sections
  may not work correctly yet.
- Left-handed mode is in **beta**.
- Tested on the Steam version only; the Xbox app version is untested.
- A game update can break the mod until it is updated.

What changed in each version is in the [Releases](../../releases) notes.

## Building from source

```
git clone --recursive https://github.com/paultaran00/GoWEDay-VR
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits and licenses

- **UEVR** by [praydog](https://github.com/praydog/UEVR) does all the heavy lifting: injection, stereo rendering,
  the Lua API. This mod uses a fork with a few patches for this game (`src/UEVR`, branch `eday`). UEVR and UESDK
  remain under praydog's own terms; they are **not** covered by this repo's license.
- The mod's own code (Lua scripts, launcher, `gameinput_vr`, tools) is under the **GNU GPL v3.0**, see [LICENSE](LICENSE): you may use and change it, but any version you share must stay open source under the same license.
- Gears of War: E-Day belongs to its owners. This project contains no game files.
