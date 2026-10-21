# Changelog

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
