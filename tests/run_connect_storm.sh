#!/bin/sh
# Drives tests/connect_storm.lua against the current queue and the pre-fix queue
# (the initial commit, before the bounded-reconciliation rewrite) and prints both,
# so the mass-reconnect main-thread stall can be reproduced and the fix verified.
#
# Usage: sh tests/run_connect_storm.sh [PLAYERS]
#   env passthrough: STORM_DUP_FRACTION, STORM_ARRIVAL_PER_SEC, STORM_ADMIT_PER_SEC
set -eu

PREFIX_COMMIT="${PREFIX_COMMIT:-8cca0fa}"
PLAYERS="${1:-${STORM_PLAYERS:-4000}}"
export STORM_PLAYERS="$PLAYERS"

LUA="${LUA:-lua}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "############################################################"
echo "# CURRENT code (working tree: server/lib)"
echo "############################################################"
"$LUA" tests/connect_storm.lua server/lib

echo
echo "############################################################"
echo "# PRE-FIX code (git $PREFIX_COMMIT: before the queue rewrite)"
echo "############################################################"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/lib"
for f in util defaults config config_lua config_store identity admission deferral queue; do
    git show "$PREFIX_COMMIT:server/lib/$f.lua" > "$TMP/lib/$f.lua"
done
"$LUA" tests/connect_storm.lua "$TMP/lib"
