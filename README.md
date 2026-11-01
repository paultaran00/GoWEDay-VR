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
2. Run `GoWEDay_VR.exe`, pick the game folder or exe, tick Windowed if you want a window, pick the VR runtime (SteamVR, or Virtual Desktop's VDXR), press **Start**.
3. On the title screen, **hold X** (left controller) to enter offline mode.
4. In game, the mod's options are in **VR SETTINGS** in the pause menu. `Insert` on the keyboard opens the UEVR menu (advanced).

## How to play

Buttons below are named by where they are on the controller: **lower / upper face button** and **stick press**. In VR SETTINGS > BUTTON MAPPING they show as LEFT X / LEFT Y / RIGHT A / RIGHT B (left lower / left upper / right lower / right upper).
Everything here is for right-handed play. With **PRIMARY HAND: LEFT** in VR SETTINGS everything is mirrored.

### Moving
- **Walk:** left stick. You walk where your head looks.
- **Turn:** right stick (smooth, or snap in VR SETTINGS).
- **Sprint:** hold the left trigger while walking.
- **Dash / roadie run:** press the left stick.
- **Jump / mantle / climb:** left upper button.
- **Crouch:** crouch for real. Marcus goes down with you, and enemies can't see you behind low cover.
- **Game cover:** off by default (in VR you take cover with your body). You can put **COVER (GAME)** on any button in BUTTON MAPPING.
- **Interact** (doors, pickups, mounted guns): left lower button, hold it when the game asks.
- **Pause menu:** right upper button.
- **Tac-com and map:** not on a button by default. Put **TAC-COM (HOLD)** and **MAP** on any button in BUTTON MAPPING. The map only opens in missions that have one.

### Weapons
- The weapon is in your right hand, the right trigger fires. Aim with the barrel; there is no crosshair.
- **Two hands:** grab the front of the weapon with the left grip. It's steadier and more accurate (shotgun pellets spread half as much).
- **Pistol with two hands:** cup the bottom of the grip with your left palm and squeeze the left grip.
- **Switch to the pistol:** right grip at your right hip.
- **Rifle / shotgun from your back:** right grip over your **left** shoulder. With two long weapons on your back, the first grab gives one, grab again for the other.
- **Put the weapon away** (free right hand): right grip over your **right** shoulder. Do it again to take it back.
- **Laser:** right stick press, or touch the laser switch on the side of the weapon with your left index finger and squeeze the left grip.
- **Melee:** swing the weapon into an enemy, or punch with your left fist (left grip held, empty hand).

### Reloading
Spare magazines and shells come from your **chest**: reach a little below your chin with the left hand and squeeze the left grip.
- **Magazine weapons:**
  1. Grab the magazine with the left grip and pull it out, or press the right lower button to drop it.
  2. Take a new one from your chest.
  3. Push it into the magazine well.
  4. If you fired the weapon empty, pull the charging handle (pistol: the slide) back.
  Letting go of a magazine at your chest puts it back; dropping it anywhere else loses it.
- **Shotguns and launchers** load one shell at a time: take a shell from your chest and push it into the loading port.
- **Gnasher:** after each shot, pull the pump under the barrel forward. If you'd rather not, set **SHOTGUN PUMP: AUTO** in VR SETTINGS.
- **Longshot:**
  1. Lift the bolt, pull it back.
  2. Put a round from your chest into the chamber.
  3. Push the bolt forward and down.
  To aim, put your eye to the scope.
- **Breechshot:** after each shot, pull the handle on the right side back.
- Heavy weapons reload by themselves.
- Handles, slides and pumps don't need a full pull: once it's far enough, the controller gives a short buzz.
- Pulling the handle with a round still in the chamber ejects that round (one round less). After a fresh magazine in an empty gun, pull it once to chamber the first round.

### Chainsaw (Chainsaw Lancer)
Grab the folded lever on the left side of the weapon with the left grip, it stands up. Pull it back to start the saw, pull again to stop. Push the running blade into an enemy.

### Grenades
- **Take it:** a grenade hangs on the right of your belt. Grab it with the left grip.
- **Arm it:** the trigger of the hand holding it pulls the pin. You have 4 seconds.
- **Throw it:** swing and let go of the grip. It flies as hard as you throw.
- **Put it back:** let go before pulling the pin.

### Mounted guns
- **Get on:** hold the interact button next to the gun.
- **Aim and fire:** aim with the right controller, fire with the right trigger.
- **Get off:** hold the right upper button.
- **Tear it off and carry it:** hold both grips and yank both hands up.

### Menus
Point with the lasers from your controllers and click with a trigger. The right stick scrolls.
On the title screen, hold the left lower button.

**VR SETTINGS** (pause menu, above SETTINGS):
- **PRIMARY HAND:** right or left (left is in beta).
- **TURNING:** smooth or snap, plus the snap angle.
- **SHOTGUN PUMP:** manual, or auto (the Gnasher rechambers by itself).
- **HUD SIZE:** small (default), medium or large. Small keeps the whole HUD, objectives included, in view; large makes the text bigger.
- **AMMO COUNTER:** on (default) shows the game's ammo panel (magazine and total), off hides it.
- **BUTTON MAPPING:** click an action, it shows WAITING FOR INPUT, then press the button you want. If that button was already used, the two actions swap. Press SPACE on the keyboard to set an action to NONE. RESET TO DEFAULTS brings the original layout back.

### If something looks off
- **View behind your head, or too high or low:** stand straight and recenter your headset. In UEVR's menu (Insert key) there's also **Set Standing Height**.
- **UEVR menu:** the **Insert** key opens it (advanced).

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
