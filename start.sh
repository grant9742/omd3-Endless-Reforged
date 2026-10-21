#!/usr/bin/env bash
# Install, update or remove the Reforged mod in the game folder.
#   ./start.sh            installs or updates the mod.
#   ./start.sh rollback   removes the mod.
# The game folder comes from OMD3_GAME_DIR (the folder that contains OMD/).
set -euo pipefail
cd "$(dirname "$0")"
GAME="${OMD3_GAME_DIR:-$HOME/.steam/steam/steamapps/common/Orcs Must Die 3}"
WIN="$GAME/OMD/Binaries/Win64"

cmd="${1:-install}"
case "$cmd" in
install|rollback) ;;
*)
  echo "usage: $0 [install|rollback]" >&2
  echo "  $0            installs or updates the mod" >&2
  echo "  $0 rollback   removes the mod" >&2
  exit 2 ;;
esac

[ -d "$WIN" ] || { echo "Game folder not found: $WIN" >&2; echo "Set OMD3_GAME_DIR to the folder that contains OMD/." >&2; exit 1; }

case "$cmd" in
install)
  # install.sh handles a fresh install, an update and the old layouts.
  OMD3_GAME_DIR="$GAME" Mods/Reforged/install.sh install --yes
  echo 'Linux: set the Steam launch option WINEDLLOVERRIDES="dwmapi=n,b" %command%'
  echo "Start the game. The mod loads at the next game start."
  if pgrep -f OMD-Win64-Shipping.exe >/dev/null 2>&1; then
    echo "The game is running. Restart it to load the new files."
  fi ;;
rollback)
  OMD3_GAME_DIR="$GAME" Mods/Reforged/install.sh rollback --yes ;;
esac
