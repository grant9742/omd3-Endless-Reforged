# UE4SS experimental v3.0.1-1181 (git 83330635)

Unmodified runtime files from <https://github.com/UE4SS-RE/RE-UE4SS>, the `experimental-latest` prerelease asset `UE4SS_v3.0.1-1181-g83330635.zip` (asset updated 2026-10-17T16:38Z, sha256 `b9a166a756605b21058a64cde93bcaab1a855dba3553e5c7e6ce0fa8fdfad7b9`). MIT license (`ue4ss/LICENSE`).

Layout in the game folder (`OMD/Binaries/Win64/`):
- `dwmapi.dll` (the proxy that loads UE4SS under Proton with `WINEDLLOVERRIDES="dwmapi=n,b"`)
- `ue4ss/` (UE4SS.dll, UE4SS-settings.ini, the built-in Lua mods, and the log `ue4ss/UE4SS.log`)

Why this build (issue #17, 2026-10-18): v3.0.1 did not pass `FOMDSoftProtoPtr` parameters intact; this build does, and runs `ExecuteInGameThread` work on the engine tick. Evidence: `docs/ue4ss-experimental-research-2026-10-18.md`. The v3.0.1 files are in git history before this change.
