#!/usr/bin/env bash
# Install UE4SS (experimental build 83330635) + Reforged into the game, or remove them again. Dry run unless --yes.
#   install.sh install  [--yes]     copies files, records them in Binaries/Win64/.reforged-manifest
#   install.sh rollback [--yes]     deletes exactly the files in the manifest, then empty folders under ue4ss/
# Layout (paths relative to Binaries/Win64): dwmapi.dll, ue4ss/ (UE4SS.dll, settings, built-in mods, log), Mods/Reforged/waves/.
set -euo pipefail
cd "$(dirname "$0")/../.."
GAME="${OMD3_GAME_DIR:-$HOME/.steam/steam/steamapps/common/Orcs Must Die 3}"
WIN="$GAME/OMD/Binaries/Win64"; PAKS="$GAME/OMD/Content/Paks/Mods"; MAN="$WIN/.reforged-manifest"
U=vendor/UE4SS; M=Mods/Reforged
cmd=${1:-}; yes=${2:-}
# Refuse a folder that is not an OMD3 install: a wrong OMD3_GAME_DIR (or the default path on a machine that keeps the game in
# another Steam library) would otherwise create a stray, game-less copy of the mod there.
if [ ! -f "$WIN/OMD-Win64-Shipping.exe" ] && [ "$cmd" != rollback ] && [ -z "${OMD3_ALLOW_ANY_DIR:-}" ]; then
  echo "No OMD3 install at: $GAME"; echo "(OMD-Win64-Shipping.exe not found in $WIN). Set OMD3_GAME_DIR to the game folder (OMD3_ALLOW_ANY_DIR=1 skips this check for a scratch folder)."; exit 1
fi
run(){ if [ "$yes" = --yes ]; then "$@"; else echo "DRY: $*"; fi; }
# Remove the files named in a manifest (paths relative to WIN).
remove_listed(){ while read -r f; do run rm -f "$WIN/$f"; done < "$1"; }
# Remove the empty folders that the mod leaves in the runtime folder.
prune_runtime_dirs(){ run rmdir "$WIN/Mods/Reforged/waves" "$WIN/Mods/Reforged/Scripts" "$WIN/Mods/Reforged" "$WIN/Mods" "$PAKS" 2>/dev/null || true; }
case "$cmd" in
install)
  # Syntax-check Lua before anything is copied. Runs in dry-run mode too.
  # The check needs the Python package lupa. Without it, skip the check and say so.
  if python3 -c "import lupa" 2>/dev/null; then
    python3 "$M/check-lua.py" "$M/ue4ss/Reforged/Scripts/main.lua" || { echo "Lua syntax check failed; nothing copied"; exit 1; }
    python3 "$M/check-lua.py" "$M/ue4ss/Reforged/Scripts/modifiers.lua" || { echo "Lua syntax check failed; nothing copied"; exit 1; }
    python3 "$M/check-lua.py" "$M/ue4ss/Reforged/Scripts/stock_waves.lua" || { echo "Lua syntax check failed; nothing copied"; exit 1; }
    python3 "$M/check-lua.py" "$M/ue4ss/Reforged/Scripts/custom_map.lua" || { echo "Lua syntax check failed; nothing copied"; exit 1; }
  else
    echo "lupa not installed: Lua syntax check skipped"
  fi
  # Upgrade from the old name: the mod was called OrcAITest before Reforged. Remove its files by its own manifest first.
  LEGACY="$WIN/.orcaitest-manifest"
  if [ -f "$LEGACY" ]; then
    echo "Old OrcAITest install found. Removing it by its manifest."
    while read -r f; do run rm -f "$WIN/$f"; done < "$LEGACY"
    run rm -f "$LEGACY"
    run rm -rf "$WIN/Mods/OrcAITest"
  else
    if [ -e "$WIN/dwmapi.dll" ] && { [ ! -f "$MAN" ] || ! grep -Fxq 'dwmapi.dll' "$MAN"; }; then
      echo "dwmapi.dll already present without a Reforged manifest entry, refusing to overwrite"
      exit 1
    fi
  fi
  # Old layout (manifest lists UE4SS.dll at the root): remove every file it lists, as rollback does.
  if [ -f "$MAN" ] && grep -Fxq 'UE4SS.dll' "$MAN"; then
    echo "Old UE4SS layout found. Removing it by its manifest."
    remove_listed "$MAN"
    run rm -f "$MAN"
    prune_runtime_dirs
  fi
  # TestMapProbe (#89) is no longer installed. An old install lists its files: remove them and their folders.
  # The manifest is rewritten below, so its probe lines go with the old list.
  if [ -f "$MAN" ] && grep -Fq 'ue4ss/Mods/TestMapProbe/' "$MAN"; then
    echo "Old TestMapProbe install found. Removing its files."
    while read -r f; do case "$f" in ue4ss/Mods/TestMapProbe/*) run rm -f "$WIN/$f" ;; esac; done < "$MAN"
    run rmdir "$WIN/ue4ss/Mods/TestMapProbe/Scripts" "$WIN/ue4ss/Mods/TestMapProbe" 2>/dev/null || true
  fi
  # A UE4SS.log symlink is a test leftover. A regular UE4SS.log is never removed.
  if [ -L "$WIN/UE4SS.log" ]; then
    echo "Removing the UE4SS.log symlink (test leftover)."
    run rm -f "$WIN/UE4SS.log"
  fi
  # Every file under vendor/UE4SS/ue4ss/ goes to ue4ss/ in the game folder.
  ue_files=()
  while IFS= read -r f; do ue_files+=("${f#./}"); done < <(cd "$U/ue4ss" && find . -type f | LC_ALL=C sort)
  files=(dwmapi.dll)
  for f in "${ue_files[@]}"; do files+=("ue4ss/$f"); done
  files+=("ue4ss/Mods/Reforged/enabled.txt" "ue4ss/Mods/Reforged/Scripts/main.lua" "ue4ss/Mods/Reforged/Scripts/modifiers.lua" "ue4ss/Mods/Reforged/Scripts/stock_waves.lua" "ue4ss/Mods/Reforged/Scripts/custom_map.lua")
  # The break gate DLL is copied. The log is only listed: the gate writes it at run time, so install does not create it.
  files+=("ue4ss/Mods/Reforged/Scripts/reforged_gate.dll" "ue4ss/Mods/Reforged/Scripts/reforged_gate.log")
  # Packs (#93): every Mods/Reforged/paks/*.pak goes to OMD/Content/Paks/Mods/. The manifest path is relative to WIN.
  paks=("$M"/paks/*.pak)
  for p in "${paks[@]}"; do
    [ -f "$p" ] && files+=("../../Content/Paks/Mods/$(basename "$p")")
  done
  waves=("$M"/ue4ss/Reforged/waves/*.json)
  for w in "${waves[@]}"; do
    [ -f "$w" ] && files+=("Mods/Reforged/waves/$(basename "$w")")
  done

  run mkdir -p "$WIN/Mods/Reforged/waves"
  if [ "$yes" = --yes ]; then
    printf '%s\n' "${files[@]}" > "$MAN"
    echo "manifest: $MAN"
  else
    echo "DRY: write manifest: $MAN"
  fi

  run cp "$U/dwmapi.dll" "$WIN/dwmapi.dll"
  for f in "${ue_files[@]}"; do
    run mkdir -p "$(dirname "$WIN/ue4ss/$f")"
    run cp "$U/ue4ss/$f" "$WIN/ue4ss/$f"
  done
  run mkdir -p "$WIN/ue4ss/Mods/Reforged/Scripts"
  run cp "$M/ue4ss/Reforged/enabled.txt" "$WIN/ue4ss/Mods/Reforged/enabled.txt"
  run cp "$M/ue4ss/Reforged/Scripts/main.lua" "$WIN/ue4ss/Mods/Reforged/Scripts/main.lua"
  run cp "$M/ue4ss/Reforged/Scripts/modifiers.lua" "$WIN/ue4ss/Mods/Reforged/Scripts/modifiers.lua"
  run cp "$M/ue4ss/Reforged/Scripts/stock_waves.lua" "$WIN/ue4ss/Mods/Reforged/Scripts/stock_waves.lua"
  run cp "$M/ue4ss/Reforged/Scripts/custom_map.lua" "$WIN/ue4ss/Mods/Reforged/Scripts/custom_map.lua"
  run cp "$M/ue4ss/Reforged/Scripts/reforged_gate.dll" "$WIN/ue4ss/Mods/Reforged/Scripts/reforged_gate.dll"
  for w in "${waves[@]}"; do [ -f "$w" ] && run cp "$w" "$WIN/Mods/Reforged/waves/$(basename "$w")"; done
  for p in "${paks[@]}"; do
    if [ -f "$p" ]; then
      run mkdir -p "$PAKS"
      run cp "$p" "$PAKS/$(basename "$p")"
    fi
  done ;;
rollback)
  [ -f "$MAN" ] || { echo "no manifest, nothing to roll back"; exit 1; }
  remove_listed "$MAN"
  run rm -f "$MAN"; prune_runtime_dirs
  # Remove empty folders under ue4ss/, deepest first. rmdir fails on a folder that still has files; that is kept.
  if [ -d "$WIN/ue4ss" ]; then
    while IFS= read -r d; do run rmdir "$d" 2>/dev/null || true; done < <(find "$WIN/ue4ss" -depth -type d)
  fi ;;
*) echo "usage: $0 install|rollback [--yes]"; exit 2 ;;
esac
