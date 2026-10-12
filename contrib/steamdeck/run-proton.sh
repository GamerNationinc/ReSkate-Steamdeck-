#!/bin/bash
# Phase 0 harness: run a skate. folder exe under a chosen Proton + Steam Linux Runtime, outside a Steam shortcut.
# usage: run-proton.sh <proton dir name> <exe> [args...]
STEAM=~/.local/share/Steam
GAME=$STEAM/steamapps/common/Skate
PROTON="$STEAM/steamapps/common/$1"; shift
case "$PROTON" in *Experimental*|*11.0*) SLR=$STEAM/steamapps/common/SteamLinuxRuntime_4 ;;
                 *) SLR=/run/media/deck/fill/steamapps/common/SteamLinuxRuntime_sniper ;; esac
export STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM
export STEAM_COMPAT_DATA_PATH=${PFX:-$HOME/Games/ReSkate/pfx-$(basename "$PROTON" | tr ' ' _)}
export STEAM_COMPAT_INSTALL_PATH=$GAME SteamAppId=3354750 SteamGameId=3354750 SteamDeck=1
export PROTON_LOG=1 PROTON_LOG_DIR=$HOME/Games/ReSkate/logs
mkdir -p "$STEAM_COMPAT_DATA_PATH" "$PROTON_LOG_DIR"
cd "$GAME"
exec "$SLR/_v2-entry-point" --verb=waitforexitandrun -- "$PROTON/proton" waitforexitandrun "$@"
