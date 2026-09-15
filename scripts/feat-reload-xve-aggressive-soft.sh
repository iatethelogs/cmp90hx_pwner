#!/usr/bin/env bash
# CMP90HX lab runner: force module reload before FEAT mask, then proven aggressive XVE pass, then final soft cleanup.
# This script is intentionally narrow:
#   FEAT 0x00823800: force nvidia stack unload -> real handoff -> fixed rejoin16 writes per card
#   XVE  0x00088fe8: installed adaptive/aggressive minimal with PCI_RESET enabled on stuck paths
#   final: installed minimal soft cleanup without reset/rehandoff

set -Eeuo pipefail

PREFIX="${CMP90_PREFIX:-/opt/cmp90hx-gen2}"
CYCLE="${CMP90_CYCLE:-$PREFIX/rejoin16-cycle.sh}"
HANDOFF="${CMP90_HANDOFF:-$PREFIX/cmp90hx-gen2-handoff.sh}"
MINIMAL="${CMP90_MINIMAL:-$PREFIX/cmp90hx-gen2-minimal.sh}"
APPLY="${CMP90_APPLY:-$PREFIX/rejoin17-apply-all.sh}"
READER="${CMP90_READER:-$PREFIX/maskread.py}"

MASK_FEAT=0x00823800
MASK_XVE=0x00088fe8
FEAT_ATTEMPTS="${CMP90HX_FEAT_ATTEMPTS:-6}"
XVE_TRIES="${CMP90HX_XVE_TRIES:-60}"
SOFT_TRIES="${CMP90HX_SOFT_TRIES:-15}"
SOFT_ROUNDS="${CMP90HX_SOFT_ROUNDS:-4}"
TOTAL_TIMEOUT="${CMP90HX_TOTAL_TIMEOUT:-1800}"

LOG="${CMP90HX_LOG:-/root/cmp90hx-feat-reload-xve-aggressive-soft-$(date +%Y%m%d-%H%M%S).log}"
exec > >(tee -a "$LOG") 2>&1

log(){ printf '[cmp90hx-feat-reload] %s\n' "$*"; }

need_exec(){
    [[ -x "$1" ]] || { log "missing executable: $1"; exit 10; }
}

need_file_or_exec(){
    [[ -f "$1" || -x "$1" ]] || { log "missing file: $1"; exit 11; }
}

elapsed(){ echo $(( $(date +%s) - START )); }

check_timeout(){
    local e
    e="$(elapsed)"
    if (( e >= TOTAL_TIMEOUT )); then
        log "FAIL: timeout ${e}s/${TOTAL_TIMEOUT}s"
        exit 1
    fi
}

make_reader_if_needed(){
    if [[ -f "$READER" || -x "$READER" ]]; then
        log "reader: $READER"
        return 0
    fi

    READER="/tmp/cmp90hx-maskread.py"
    cat > "$READER" <<'PY_READER'
#!/usr/bin/env python3
import mmap
import os
import struct
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: maskread.py <bdf> <offset>")

bdf = sys.argv[1]
off = int(sys.argv[2], 0)
path = f"/sys/bus/pci/devices/{bdf}/resource0"
page = mmap.PAGESIZE
base = off & ~(page - 1)
inner = off - base

fd = os.open(path, os.O_RDONLY | getattr(os, "O_SYNC", 0))
try:
    mm = mmap.mmap(fd, inner + 4, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    try:
        val = struct.unpack_from("<I", mm, inner)[0]
        print(f"0x{val:08x}")
    finally:
        mm.close()
finally:
    os.close(fd)
PY_READER
    chmod +x "$READER"
    log "created fallback reader: $READER"
}

find_cmps(){
    for d in /sys/bus/pci/devices/*; do
        [[ -f "$d/vendor" && -f "$d/device" ]] || continue
        [[ "$(cat "$d/vendor")" == "0x10de" && "$(cat "$d/device")" == "0x220d" ]] && basename "$d"
    done | sort
}

mask_val(){ # <bdf> <addr>
    local bdf="$1" addr="$2"
    python3 "$READER" "$bdf" "$addr" 2>/dev/null | awk '{print $1}'
}

write_mask(){ # <bdf> <addr>
    local bdf="$1" addr="$2"
    log "$bdf write $addr = 0xffffffff via rejoin16-cycle"
    CMP90_BDF="$bdf" bash "$CYCLE" "$addr" 0xffffffff >/dev/null 2>&1 || true
}

read_mask(){ # <bdf> <addr> <tag>
    local bdf="$1" addr="$2" tag="$3" cur
    cur="$(mask_val "$bdf" "$addr")"
    log "$bdf $addr $tag readback=${cur:-none}"
}

write_read_triplet(){ # <bdf> <addr> <tag>
    local bdf="$1" addr="$2" tag="$3"
    write_mask "$bdf" "$addr"
    read_mask "$bdf" "$addr" "$tag immediate"
    sleep 0.25
    read_mask "$bdf" "$addr" "$tag 250ms"
    sleep 1
    read_mask "$bdf" "$addr" "$tag 1s"
}

upstream_of(){
    local bdf="$1"
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$bdf")")"
}

retrain_gen2(){ # <bdf>
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
    log "$bdf retrain target Gen2 via upstream=$up"

    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true

    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 2
}

stop_old_temp(){
    log "stop old temporary test scripts/units"
    pkill -f 'staged-aggressive-soft.sh|cmp90hx-brutal-then-soft.sh|cmp90hx-aggressive-then-soft.sh|cmp90hx-known-good-all|cmp90hx-confirmed-feat-xve' 2>/dev/null || true
    systemctl stop 'cmp90hx-brutal-soft-*' 'cmp90hx-aggr-soft-*' 'cmp90hx-hotfix-*' 'cmp90hx-final-soft-*' 'cmp90hx-final-pass-*' 2>/dev/null || true
    systemctl reset-failed 'cmp90hx-brutal-soft-*' 'cmp90hx-aggr-soft-*' 'cmp90hx-hotfix-*' 'cmp90hx-final-soft-*' 'cmp90hx-final-pass-*' 2>/dev/null || true
}

stop_gpu_users(){
    log "stop GPU users"
    systemctl stop nvidia-persistenced ollama llama open-webui librechat comfyui docker containerd 2>/dev/null || true
    pkill -f 'llama-server|/opt/llama.cpp|ollama|comfyui' 2>/dev/null || true
    if ls /dev/nvidia* >/dev/null 2>&1; then
        fuser -k /dev/nvidia* 2>/dev/null || true
    fi
    sleep 2
}

unload_nvidia_stack_strict(){
    local pass loaded
    for pass in 1 2 3; do
        log "unload nvidia stack pass $pass/3"
        modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
        sleep 2
        loaded="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
        if [[ -z "$loaded" ]]; then
            log "nvidia stack unloaded"
            return 0
        fi
        log "still loaded: $loaded"
        stop_gpu_users
    done

    loaded="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
    if [[ -n "$loaded" ]]; then
        log "FAIL: cannot unload nvidia stack: $loaded"
        log "check holders: lsmod | grep '^nvidia'; fuser -v /dev/nvidia*"
        return 20
    fi
}

force_real_handoff_for_bdf(){ # <bdf>
    local bdf="$1" before after out rc
    log "$bdf force real stock->patched handoff before FEAT"

    before="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
    log "$bdf nvidia modules before unload: ${before:-none}"

    unload_nvidia_stack_strict || return $?

    log "$bdf run handoff with CMP90_BDF=$bdf"
    set +e
    out="$(CMP90_BDF="$bdf" bash "$HANDOFF" 2>&1)"
    rc=$?
    set -e
    while IFS= read -r line; do
        [[ -n "$line" ]] && log "$bdf handoff: $line"
    done <<< "$out"

    after="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
    log "$bdf nvidia modules after handoff: ${after:-none}"

    if grep -qi 'patched module already active' <<< "$out"; then
        log "$bdf WARN: handoff reported patched module already active after forced unload"
    fi

    sleep 5
    return "$rc"
}

open_feat_by_confirmed_reload(){ # <bdf>
    local bdf="$1" i
    log "$bdf FEAT $MASK_FEAT: confirmed method = force module reload + real handoff + fixed rejoin16 writes"
    log "$bdf FEAT initial readback=$(mask_val "$bdf" "$MASK_FEAT")"

    force_real_handoff_for_bdf "$bdf" || true

    for i in $(seq 1 "$FEAT_ATTEMPTS"); do
        check_timeout
        log "$bdf FEAT attempt $i/$FEAT_ATTEMPTS"
        write_read_triplet "$bdf" "$MASK_FEAT" "FEAT attempt $i"
        if (( i == 3 )); then
            retrain_gen2 "$bdf"
        fi
    done

    retrain_gen2 "$bdf"
    log "$bdf FEAT final readback=$(mask_val "$bdf" "$MASK_FEAT")"
}

card_is_gen2(){ # <bdf>
    local bdf="$1" up speed endpoint upstream
    up="$(upstream_of "$bdf")"
    speed="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || true)"
    endpoint="$(lspci -Dvv -s "$bdf" | grep 'LnkSta:' | head -1 || true)"
    upstream="$(lspci -Dvv -s "$up" | grep 'LnkSta:' | head -1 || true)"
    [[ "$speed" == *"5.0 GT/s"* ]] && [[ "$endpoint" == *"Speed 5GT/s"* ]] && [[ "$upstream" == *"Speed 5GT/s"* ]]
}

verify_links(){
    local cmps bdf up speed width endpoint upstream total=0 ok=0 bad=()
    mapfile -t cmps < <(find_cmps)
    (( ${#cmps[@]} > 0 )) || { log "no CMP 90HX cards found"; return 2; }

    for bdf in "${cmps[@]}"; do
        total=$((total + 1))
        up="$(upstream_of "$bdf")"
        speed="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || true)"
        width="$(cat "/sys/bus/pci/devices/${bdf}/current_link_width" 2>/dev/null || true)"
        endpoint="$(lspci -Dvv -s "$bdf" | grep 'LnkSta:' | head -1 || true)"
        upstream="$(lspci -Dvv -s "$up" | grep 'LnkSta:' | head -1 || true)"
        log "$bdf upstream=$up speed=$speed width=$width"
        log "  endpoint $endpoint"
        log "  upstream $upstream"
        if card_is_gen2 "$bdf"; then ok=$((ok + 1)); else bad+=("$bdf"); fi
    done

    log "GEN2 $ok/$total"
    (( ${#bad[@]} == 0 )) || log "not Gen2 yet: ${bad[*]}"
    [[ "$ok" == "$total" ]]
}

open_xve_aggressive_all(){
    log "XVE $MASK_XVE: proven aggressive adaptive pass via installed minimal"
    log "env: PCI_RESET=1 RESET_ON_STUCK=1 OPEN_REHANDOFF=1 STUCK_REPEAT_LIMIT=8 MASK_OPEN_TRIES=$XVE_TRIES"
    CMP90HX_PCI_RESET=1 \
    CMP90HX_RESET_ON_STUCK=1 \
    CMP90HX_OPEN_REHANDOFF=1 \
    CMP90HX_STUCK_REPEAT_LIMIT=8 \
    CMP90HX_MASK_OPEN_TRIES="$XVE_TRIES" \
    bash "$MINIMAL" || true
}

final_soft_all(){ # <round>
    local round="$1"
    log "final soft pass round $round/$SOFT_ROUNDS via installed minimal"
    log "env: PCI_RESET=0 RESET_ON_STUCK=0 OPEN_REHANDOFF=0 MASK_OPEN_TRIES=$SOFT_TRIES"
    CMP90HX_PCI_RESET=0 \
    CMP90HX_RESET_ON_STUCK=0 \
    CMP90HX_OPEN_REHANDOFF=0 \
    CMP90HX_MASK_OPEN_TRIES="$SOFT_TRIES" \
    bash "$MINIMAL" || true
}

main(){
    local bdf round
    START="$(date +%s)"

    log "LOG: $LOG"
    log "timeout=${TOTAL_TIMEOUT}s feat_attempts=${FEAT_ATTEMPTS} xve_tries=${XVE_TRIES} soft_tries=${SOFT_TRIES} soft_rounds=${SOFT_ROUNDS}"

    stop_old_temp || true
    stop_gpu_users || true
    make_reader_if_needed

    need_exec "$CYCLE"
    need_exec "$HANDOFF"
    need_exec "$MINIMAL"
    need_file_or_exec "$READER"

    mapfile -t BDFS < <(find_cmps)
    (( ${#BDFS[@]} > 0 )) || { log "no CMP 90HX cards found"; exit 2; }
    log "cards: ${BDFS[*]}"

    log "initial verify"
    verify_links || true

    log "============================================================"
    log "PHASE 1: FEAT first mask per-card with forced module reload"
    for bdf in "${BDFS[@]}"; do
        check_timeout
        log "---------------- FEAT target card: $bdf ----------------"
        open_feat_by_confirmed_reload "$bdf"
    done

    log "verify after FEAT phase"
    verify_links || true

    check_timeout
    log "============================================================"
    log "PHASE 2: XVE second mask aggressive confirmed adaptive pass"
    open_xve_aggressive_all

    log "verify after aggressive XVE phase"
    verify_links || true

    log "============================================================"
    log "PHASE 3: final soft cleanup"
    for round in $(seq 1 "$SOFT_ROUNDS"); do
        check_timeout
        final_soft_all "$round"
        log "verify after final soft round $round"
        if verify_links; then
            log "SUCCESS: GEN2 all/all after FEAT reload + aggressive XVE + final soft"
            exit 0
        fi
        sleep 10
    done

    log "FAIL: final soft convergence exhausted"
    verify_links || true
    exit 1
}

main "$@"
