#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${CMP90_PREFIX:-/opt/cmp90hx-gen2}"
MAIN="$SCRIPT_DIR/rejoin17-apply-all-main.sh"
HANDOFF="$SCRIPT_DIR/cmp90hx-compute-handoff.sh"
CYCLE="$SCRIPT_DIR/rejoin16-cycle.sh"
READER="$SCRIPT_DIR/maskread.py"
BAR0POKE="${CMP90_BAR0POKE:-$PREFIX/bar0poke}"

log() { printf '[cmp90hx-known-good-wrapper] %s\n' "$*"; }

[[ -x "$MAIN" ]] || { log "FAIL: missing main Gen2 logic: $MAIN"; exit 10; }
[[ -x "$HANDOFF" ]] || { log "FAIL: missing tracked handoff: $HANDOFF"; exit 11; }
[[ -x "$CYCLE" ]] || { log "FAIL: missing tracked cycle: $CYCLE"; exit 12; }
[[ -r "$READER" ]] || { log "FAIL: missing tracked reader: $READER"; exit 13; }
[[ -x "$BAR0POKE" ]] || { log "FAIL: missing bar0poke: $BAR0POKE"; exit 14; }

if grep -qE 'cmp90hx-compute-handoff|cmp90hx-gen2-handoff' "$CYCLE" 2>/dev/null; then
    log "FAIL: rejoin16-cycle calls handoff; this is not main Gen2 reload logic"
    grep -nE 'handoff|cmp90hx' "$CYCLE" || true
    exit 15
fi

if grep -qE 'stock module|priming GPU' "$CYCLE" 2>/dev/null; then
    log "FAIL: rejoin16-cycle contains stock-prime logic; this is not main Gen2 reload logic"
    grep -nE 'stock|priming' "$CYCLE" || true
    exit 16
fi

if ! grep -q 'modprobe nvidia ||' "$CYCLE" 2>/dev/null; then
    log "FAIL: rejoin16-cycle lacks main-style modprobe nvidia reload"
    exit 17
fi

log "runtime dir: $SCRIPT_DIR"
log "main logic: $MAIN"
log "handoff: $HANDOFF"
log "cycle: $CYCLE"
log "reader: $READER"
log "bar0poke: $BAR0POKE"

export CMP90_RUNTIME_DIR="$SCRIPT_DIR"
export CMP90_PREFIX="$PREFIX"
export CMP90_HANDOFF="$HANDOFF"
export CMP90_CYCLE="$CYCLE"
export CMP90_READER="$READER"
export CMP90_BAR0POKE="$BAR0POKE"

exec bash "$MAIN" "$@"
