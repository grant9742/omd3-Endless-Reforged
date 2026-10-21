# Endless Reforged: a rebuilt Endless mode for Orcs Must Die! 3

**Version 0.2.0** · single-player · tested on Linux with Steam Proton

Endless Reforged is a mod for *Orcs Must Die! 3* (Steam App ID 1522820). It adds a new
Endless mode next to the stock one. In Reforged Endless, the mod builds every
round itself: the enemy mix, the round size, the elites, the bosses, the build
breaks and special wave modifiers. You set the rules on a Reforged page in the
game's Options menu.

The stock Endless mode stays available as **Classic**. Classic plays like the
unmodded game unless you turn on a Reforged option for it.

The mod runs as Lua scripts and a small native helper (`reforged_gate.dll`) under
[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). It also adds three pak files to
`OMD/Content/Paks/Mods/`: the two extra maps and the Endless map list rows. It does
not change the game executable or the game's own PAK files. The uninstall removes
every file that the install added.

## Features

### Move the Rift

Before the first wave of a map, press **F7** (or **LB + RB** on a controller)
to move the Rift to where you stand. Enemies then take a direct route to the
new Rift. You respawn at that place. Stand on the ground when you press it.

### Two Endless modes

| Mode | What it is |
|---|---|
| **Classic** | The stock Endless game. It is the default. |
| **Reforged** | The rebuilt Endless game. The mod plans each round. |

Press **F6** in the Endless map screen to change the mode. The screen shows the
current mode. The mod applies it when the next map loads. When a map loads, a
short popup shows the mode, for example `REFORGED ENDLESS`.

### More maps in the Endless map list

The Endless map list has more maps while the mod is installed. They work in
every Endless mode.

| Maps | What they are |
|---|---|
| **Well That's Orcward** | A new map: one long corridor from the orc gate to the Rift. |
| **Servant Entrance** | A Backrooms map. An orc has returned from the Backrooms with poorly drawn maps: this one is the layout of the *Orcs Must Die! 2* map. |
| The 7 War Scenario maps | The stock War Scenario maps, as Endless maps. In Reforged they have a boss every 5 rounds and their own wave size. |

All Endless maps are unlocked while the mod is installed. DLC maps still need
their DLC.

### Wave modifiers

From round 3, a round can roll a special modifier (20% chance by default). A
banner shows its name when the round starts.

| Modifier | Effect |
|---|---|
| Horde Rush | Double squads, no promotions. |
| Iron Wall | Armored squads. |
| Sapper Rush | Bomb squads. |
| Firestorm | Fire fiend squads. |
| Mystic Circle | Casters and shamans. |
| Treasure Herd | Loot goblins and a Moneybags. Moneybags pays 500 coins on death. |
| Elite Guard | Some squads hold elite types. |
| One Gate | Every enemy uses one door. |
| Blitz | Shorter gaps between squads. |
| War Banner | A banner bearer calls reinforcements while it stands. |
| Warcamp | Three banner bearers (from round 6). |

Press **F5** in the Endless map screen to turn modifiers on or off for the
current mode. The screen shows `Modifiers: ON (F5)` or `Modifiers: OFF (F5)`.
In Classic, modifiers are off by default. When you turn them on, a modifier
adds extra enemies on top of the stock round.

### Settings

Open **Options**, then **Reforged**. Each change saves at once to `settings.json`.

Wave size and promotions apply to Reforged only. Health, damage and speed scale
the Endless enemies.

### Start screen

The main menu shows **Play** and **Options**. **Play** opens the Endless map
list and starts the map that you pick.

### Test mode

Press **F7** in the Endless map screen to turn test mode on or off. With test
mode on, the mode box shows `TEST MODE: ON`, and the level-load popup shows
`TEST MODE`. In a match, test mode keeps the Rift points at 1000 and turns off
the Go Breaks, so you can try traps and maps without losing. Test mode is off at
every game start.

## Requirements

- *Orcs Must Die! 3* from Steam, started once.
- Single-player. Co-op is not tested.

The mod includes UE4SS (experimental build 83330635). Other UE4SS builds are
not tested. UE4SS 3.0.1 does not work with this mod.

## Install

Read [INSTALL.md](INSTALL.md) for the full steps. The short forms are below.

### Windows

1. Download `Reforged-<version>.zip` from the Releases page and extract it.
2. Close the game.
3. Double-click `start.bat` in the extracted folder. It finds the game in your
   Steam libraries, also on other drives. If it does not find the game, paste
   the game folder path (the folder that contains `OMD`) and press Enter, or
   drag the game folder onto `start.bat`.
4. Start the game from Steam. Windows does not need a Steam launch option. The
   first start after an install can crash. Start it again.

To update, run `start.bat` again. To remove the mod, close the game and
double-click `uninstall.bat`. It deletes only the files that the install added.

`start.bat` and `uninstall.bat` were tested on Windows 10. The mod in the game is
not yet tested on Windows; please report the result if you try it.

### Linux (Steam Proton)

1. Set the Steam launch option for the game:
   `WINEDLLOVERRIDES="dwmapi=n,b" %command%`
2. Run:
   ```sh
   export OMD3_GAME_DIR="/path/to/steamapps/common/Orcs Must Die 3"
   Mods/Reforged/install.sh install --yes
   ```
3. Start the game. The first start after an install can crash. Start it again.

To remove the mod on Linux, close the game and run
`Mods/Reforged/install.sh rollback --yes`.

## Controls

| Key | Where | Action |
|---|---|---|
| F6 | Endless map screen | Change the Endless mode (Classic, Reforged). |
| F5 | Endless map screen | Turn wave modifiers on or off for the current mode. |
| F7 | Endless map screen | Turn test mode on or off (see "Test mode"). |
| F7 | In a match, before the first wave | Move the Rift to you. |
| LB + RB | In a match, before the first wave | Move the Rift to you (controller). |
| G | In a match | Start the next round (stock key). |

## Known limits

- Tested in the game only on Linux Mint 22 with Proton. On Windows, the install
  and uninstall scripts are tested; the mod in the game is not.
- Single-player only.
- No scores go to the leaderboards. The mod sets game integrity to 0 on every
  map, so the game does not save best scores or upload leaderboard scores while
  the mod is installed. Lifetime stats and achievements are not blocked.
- DLC maps stay locked if you do not own the DLC.
- The mod is made for Endless maps. If you turn off the start screen and play a
  campaign War Scenario with the mode set to Reforged, the mod changes its waves too.
- The first game start after an install or an update can crash. Start the
  game again.
- The mod loads its scripts only when the game starts. Restart the game after
  an update.
- The start screen replaces the stock main menu. The campaign is not on it.
- In Classic with "Use Modifiers with Classic" on, the extra enemies can stay
  into the build break.
- A game update can break the mod. Remove the mod if the game does not start
  after an update.

## Credits

The release includes [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) under its MIT
licence (`vendor/UE4SS/ue4ss/LICENSE`). *Orcs Must Die! 3* belongs to Robot
Entertainment. This mod is not made or supported by Robot Entertainment.

## Changes

See [CHANGELOG.md](CHANGELOG.md).
