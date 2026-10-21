# Changelog

## 0.2.2 (2026-10-21)

### Changed

- The mod acts only on Endless maps. On a campaign, weekly or DLC campaign map
  it does not change the waves, the difficulty, the build breaks or the Rift.
  It still blocks score uploads on every map.
- The mod checks the game build at start. On a game build it does not know (for
  example after a game update), it turns off the Reforged features that depend on
  that build (the wave hold, the break gate, the anchor delay and the Moneybags
  rewards) instead of risking a crash. Classic is not changed.
- The UE4SS cheat manager and console mods are off.
- The mod writes its version to `ue4ss/UE4SS.log` at start. The install copies the
  `VERSION` file to `Mods/Reforged/`.

### Fixed

- Less work per frame: the mod writes no developer log stream on a player
  install, and it scans the doors, the Rift, the enemy targets and the custom-map
  path points less often.
- The wall torches on Well That's Orcward and Servant Entrance sit against the
  wall.
- A settings file saved with a byte order mark loads. Settings saves are atomic.
  One failed step at map start no longer stops the steps after it.
- Linux `start.sh` says "The game is running" only when the game runs.

## 0.2.1 (2026-10-21)

### Fixed

- Moving the Rift on a War Scenario map no longer leaves the enemies standing
  at the closed inner gates. On these maps, enemies keep the stock lanes, break
  the gates as in the stock game, and then go to the new Rift. On the other
  maps, enemies still take a direct route to the new Rift.
- A second Rift move before the first wave plans from the stock lanes again.

### Known limits

- If you move the Rift to a place that enemies cannot walk to, the enemies stop
  before it or the game removes them. Move the Rift only to a floor that
  enemies can reach.

## 0.2.0 (2026-10-21)

### Added

- Two new maps in the Endless map list: **Well That's Orcward** and **Servant
  Entrance**, the first Backrooms map ("An orc has returned from the Backrooms with
  poorly drawn maps"). They play in every Endless mode, with their own loading
  screen, map preview, minimap, title card and music.
- Orc gates on the new maps. The first enemies break the gate, as on the stock
  maps, and the announcer calls the attack and the breach.
- The seven War Scenario maps in the Endless map list: The Lava Pits, Front Lawn,
  Mage Tower, Dragon Boneyard, Order Temple, Canyon Keep (DLC) and Desert Wall (DLC).
- Reforged on the War Scenario maps: a wave size for each map and a boss every
  5 rounds.
- All Endless maps are unlocked while the mod is installed. DLC maps still need
  their DLC.

### Changed

- No leaderboard scores: the mod sets game integrity to 0 on every map. The game
  does not save best scores or upload leaderboard scores while the mod is
  installed. Lifetime stats and achievements are not blocked.
- The install also copies three pak files to `OMD/Content/Paks/Mods/` and lists
  them in the manifest. The uninstall removes them.

### Fixed

- RETRY on a new map reopens that map, and the keyboard and controller work at
  once after RETRY.

## 0.1.0 (2026-10-19)

The first player release. The developer web panel and the Manual mode are not
part of the player release.

### Added

- Endless Reforged mode: the mod plans each round (composition, size, promotions,
  bosses every 10 rounds).
- Build-break options: wait, auto, timed.
- Next-wave preview on the minimap.
- Stock replay wave source.
- Eleven wave modifiers with a banner, in Reforged and optionally in Classic.
- Reforged rewards: round coins, a kill-coin floor, the Moneybags payout, the boss
  Rift cost.
- Health, damage and speed scaling options.
- The Reforged page in the Options menu, saved to `settings.json`.
- The start screen with Play and Options. Play lists the Endless maps.
- F6 changes the Endless mode in the map screen.
- F5 turns wave modifiers on or off for the current mode.
- F7 or LB + RB moves the Rift before the first wave.
- A level-load popup shows the mode.

### Changed

- UE4SS is now the experimental build 83330635 in `ue4ss/`. The installer
  upgrades an install that has the old layout.
