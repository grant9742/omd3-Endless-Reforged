# Install Endless Reforged 0.1.0

**Tested on:** Linux Mint 22, Steam Proton Experimental, game build RobotUE4
4.27.1, single-player Endless. **Windows is not tested.**

The install adds files under the game folder `OMD/Binaries/Win64/`. It writes a
list of every file it adds to `.reforged-manifest` in that folder. The uninstall
deletes exactly those files. The install does not change the game executable or
the game's PAK files.

## Before you start

1. Install *Orcs Must Die! 3* from Steam (App ID 1522820).
2. Start the game once, then close it.
3. Find the game folder. It contains `OMD/Binaries/Win64`.
   The default Linux folder is `~/.steam/steam/steamapps/common/Orcs Must Die 3`.
   In Steam, right-click the game, then select **Manage** > **Browse local files**.

## Linux (Steam Proton)

### 1. Set the launch option

Proton must load the UE4SS proxy `dwmapi.dll`. Without this option, the mod does
not load.

1. In Steam, right-click *Orcs Must Die! 3*, then select **Properties**.
2. In **Launch Options**, type:
   ```
   WINEDLLOVERRIDES="dwmapi=n,b" %command%
   ```

### 2. Install the files

You need `bash`, `python3` and the standard file tools. Run the commands from the
top folder of the Endless Reforged release.

1. Set the game folder:
   ```sh
   export OMD3_GAME_DIR="/path/to/steamapps/common/Orcs Must Die 3"
   ```
2. Do a dry run. It prints each file that it will copy and copies nothing:
   ```sh
   Mods/Reforged/install.sh install
   ```
3. Install:
   ```sh
   Mods/Reforged/install.sh install --yes
   ```

Optional: with the Python package `lupa` installed (`pip install --user lupa`),
the installer checks the Lua files for syntax errors before it copies them.

If a copy fails, run the install command again. It continues from the manifest.
The installer does not overwrite a `dwmapi.dll` that it did not install. If you
use another mod that installs `dwmapi.dll`, remove that mod first.

### 3. Check the install

1. Start the game from Steam. The first start after an install can crash.
   If it does, start the game again.
2. Open the file `OMD/Binaries/Win64/ue4ss/UE4SS.log` in the game folder.
3. Find a line that starts with `[Reforged] wave director ready`. The mod writes
   it when it loads.
4. The main menu shows **Play** and **Options**.

## Windows

`start.bat` and `uninstall.bat` were tested on Windows 10 on 2026-10-19: they
install and remove the files in the table below. The mod load in the game is
not tested on Windows. Report the result if you try it.

### Install with start.bat

1. Close the game.
2. Double-click `start.bat` in the top folder of the release.
   It finds the game in your Steam libraries, also on other drives.
3. If it does not find the game, it asks for the game folder. Paste the folder
   path, then press Enter. You can also drag the game folder onto `start.bat`.
4. Start the game. Do the checks in "Check the install" above.

To update, run `start.bat` again. To remove the mod, double-click
`uninstall.bat`. It deletes the files in the manifest, then the empty folders.

### Install by hand

1. Close the game.
2. Copy these files from the release into the game folder
   `OMD\Binaries\Win64\`:

   | From the release | To `OMD\Binaries\Win64\` |
   |---|---|
   | `vendor\UE4SS\dwmapi.dll` | `dwmapi.dll` |
   | `vendor\UE4SS\ue4ss\` (the full folder) | `ue4ss\` |
   | `Mods\Reforged\ue4ss\Reforged\enabled.txt` | `ue4ss\Mods\Reforged\enabled.txt` |
   | `Mods\Reforged\ue4ss\Reforged\Scripts\main.lua` | `ue4ss\Mods\Reforged\Scripts\main.lua` |
   | `Mods\Reforged\ue4ss\Reforged\Scripts\modifiers.lua` | `ue4ss\Mods\Reforged\Scripts\modifiers.lua` |
   | `Mods\Reforged\ue4ss\Reforged\Scripts\stock_waves.lua` | `ue4ss\Mods\Reforged\Scripts\stock_waves.lua` |
   | `Mods\Reforged\ue4ss\Reforged\Scripts\reforged_gate.dll` (Reforged break gate, native helper loaded by the Lua mod) | `ue4ss\Mods\Reforged\Scripts\reforged_gate.dll` |
   | Not in the release (written by the gate at run time) | `ue4ss\Mods\Reforged\Scripts\reforged_gate.log` |
   | `Mods\Reforged\ue4ss\Reforged\waves\*.json` | `Mods\Reforged\waves\` |

3. Make the empty folder `OMD\Binaries\Win64\Mods\Reforged\` if it does not exist.
   The mod saves its settings there.
4. Start the game. Do the checks in "Check the install" above.

Windows does not need the Steam launch option.

To remove the mod on Windows, delete the files and folders in the table, and
the folder `OMD\Binaries\Win64\Mods\Reforged\`.

## Update

1. Close the game.
2. Run the install again:
   ```sh
   Mods/Reforged/install.sh install --yes
   ```
3. Start the game. The mod loads the new scripts only when the game starts.

Your settings stay in `OMD/Binaries/Win64/Mods/Reforged/settings.json`.

## Uninstall

1. Close the game.
2. Run:
   ```sh
   Mods/Reforged/install.sh rollback --yes
   ```
   The script deletes the files in the manifest, then the empty folders.
3. Remove the Steam launch option.

The uninstall keeps the files that the mod writes while it runs: `settings.json`,
`endless-mode.txt` and `ue4ss/UE4SS.log`. To remove them too,
delete the folder `OMD/Binaries/Win64/Mods/Reforged/` and the file
`OMD/Binaries/Win64/ue4ss/UE4SS.log`.

## Problems

| Problem | Check |
|---|---|
| No `[Reforged]` lines and no `ue4ss/UE4SS.log` | Linux: the Steam launch option is missing or has a typo. |
| The game crashes at the first start | Start it again. This happens once after an install or an update. |
| The game does not start after a game update | Uninstall the mod. The game update can break UE4SS. |
| F6 does not change the mode | Press F6 in the Endless map screen, not in a match. |
| A setting does not change the game | The mode must be Reforged for the Reforged-only settings. |
