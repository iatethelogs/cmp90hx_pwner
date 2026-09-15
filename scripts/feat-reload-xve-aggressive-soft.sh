#!/usr/bin/env bash
# CMP90HX Gen2-only lab runner.
# Policy:
#   - Do not preserve current GPU state.
#   - Before FEAT 0x00823800 on every CMP card: force a clean nvidia module unload, reset the target if possible,
#     run a real handoff, then write the mask repeatedly.
#   - For XVE 0x00088fe8: use the already proven aggressive installed minimal pass.
#   - Finish with repeated soft passes; success is only link Gen2 on endpoint and upstream.

set -Eeuo pipefail

PREFIX="${CMP90_PREFIX:-/opt/cmp90hx-gen2}"
CYCLE="${CMP90_CYCLE:-$PREFIX/rejoin16-cycle.sh}"
HANDOFF="${CMP90_HANDOFF:-$PREFIX/cmp90hx-gen2-handoff.sh}"
MINIMAL="${CMP90_MINIMAL:-$PREFIX/cmp90hx-gen2-minimal.sh}"
READER="${CMP90_READER:-$PREFIX/maskread.py}"

MASK_FEAT=0x00823800
MASK_XVE=0x00088fe8

FEAT_RELOAD_ROUNDS="${CMP90HX_FEAT_RELOAD_ROUNDS:-2}"
FEAT_WRITES_PER_ROUND="${CMP90HX_FEAT_WRITES_PER_ROUND:-8}"
XVE_TRIES="${CMP90HX_XVE_TRIES:-60}"
SOFT_TRIES="${CMP90HX_SOFT_TRIES:-15}"
SOFT_ROUNDS="${CMP90HX_SOFT_ROUNDS:-6}"
TOTAL_TIMEOUT="${CMP90HX_TOTAL_TIMEOUT:-1800}"

LOG="${CMP90HX_LOG:-/root/cmp90hx-feat-reload-xve-aggressive-soft-$(date +%Y%m%d-%H%M%S).log}"
exec > >(tee -a "$LOG") 2>&1

log(){ printf '[cmp90hx-gen2-force] %s\n' "$*"; }

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
        print(f"0x{struct.unpack_from('<I', mm, inner)[0]:08x}")
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

mask_val(){
    local bdf="$1" addr="$2"
    python3 "$READER" "$bdf" "$addr" 2>/dev/null | awk '{print $1}'
}

upstream_of(){
    local bdf="$1"
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$bdf")")"
}

show_driver_state(){
    local tag="$1" loaded
    loaded="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
    log "$tag nvidia modules: ${loaded:-none}"
}

stop_old_automation(){
    log "disable old cmp90hx autostart hooks for clean manual run"
    systemctl stop cmp90hx-gen2.service 2>/dev/null || true
    systemctl disable cmp90hx-gen2.service 2>/dev/null || true
    systemctl reset-failed cmp90hx-gen2.service 2>/dev/null || true
    rm -f /etc/profile.d/cmp90hx-pwner-login.sh
    systemctl daemon-reload 2>/dev/null || true
    rm -rf /run/cmp90hx-gen2-reset-done 2>/dev/null || true
}

stop_gpu_users(){
    log "stop GPU users"
    systemctl stop nvidia-persistenced 2>/dev/null || true
    systemctl stop ollama llama open-webui librechat comfyui docker containerd 2>/dev/null || true
    pkill -f 'nvidia-smi|llama-server|ollama|comfyui|python.*cuda|python.*torch|python.*nvidia' 2>/dev/null || true
    if ls /dev/nvidia* >/dev/null 2>&1; then
        fuser -k /dev/nvidia* 2>/dev/null || true
    fi
    sleep 2
}

unbind_all_from_nvidia_driver(){
    local dev bdf
    [[ -d /sys/bus/pci/drivers/nvidia ]] || return 0

    log "unbind all PCI devices currently attached to nvidia driver"
    for dev in /sys/bus/pci/drivers/nvidia/0000:*:*.*; do
        [[ -e "$dev" ]] || continue
        bdf="$(basename "$dev")"
        log "$bdf unbind from nvidia"
        echo "$bdf" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null || true
    done
    sleep 2
}

remove_nvidia_modules_once(){
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
    modprobe -r nvidia-vgpu-vfio nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
    rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia_vgpu_vfio nvidia 2>/dev/null || true
}

nvidia_modules_loaded(){
    lsmod | awk '{print $1}' | grep -Eq '^nvidia($|_)|^nvidia-vgpu-vfio$|^nvidia_vgpu_vfio$'
}

force_clean_nvidia_unload(){
    local pass loaded

    show_driver_state "before unload"

    for pass in 1 2 3 4 5; do
        log "force clean nvidia unload pass $pass/5"
        stop_gpu_users
        remove_nvidia_modules_once
        sleep 2

        if ! nvidia_modules_loaded; then
            log "nvidia stack unloaded cleanly"
            return 0
        fi

        loaded="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
        log "still loaded after modprobe/rmmod: ${loaded:-unknown}"

        unbind_all_from_nvidia_driver
        remove_nvidia_modules_once
        sleep 2

        if ! nvidia_modules_loaded; then
            log "nvidia stack unloaded after unbind"
            return 0
        fi
    done

    show_driver_state "FAILED unload"
    log "FAIL: nvidia module is still loaded; continuing would not be the known-good FEAT context"
    return 20
}

pci_reset_card(){
    local bdf="$1"
    if [[ -w "/sys/bus/pci/devices/$bdf/reset" ]]; then
        log "$bdf PCI function reset"
        echo 1 > "/sys/bus/pci/devices/$bdf/reset" 2>/dev/null || true
        sleep 3
    else
        log "$bdf no writable /reset; skip function reset"
    fi
}

rescan_pci(){
    log "PCI rescan"
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    sleep 2
}

run_real_handoff_for_bdf(){
    local bdf="$1" out rc after

    log "$bdf run handoff after confirmed module unload"
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
        log "$bdf BAD_HANDOFF: got 'patched module already active' after forced unload"
        return 30
    fi

    if ! nvidia_modules_loaded; then
        log "$bdf BAD_HANDOFF: nvidia modules are not loaded after handoff"
        return 31
    fi

    sleep 5
    return "$rc"
}

force_good_start_for_feat(){
    local bdf="$1" try

    for try in 1 2; do
        check_timeout
        log "$bdf prepare known-good FEAT start, try $try/2"

        force_clean_nvidia_unload || true
        pci_reset_card "$bdf"
        rescan_pci

        if run_real_handoff_for_bdf "$bdf"; then
            log "$bdf known-good FEAT start prepared"
            return 0
        fi

        log "$bdf handoff was not clean; unload and retry"
        force_clean_nvidia_unload || true
        sleep 3
    done

    log "$bdf WARN: clean handoff was not proven; still doing FEAT writes, but log must be inspected"
    return 0
}

retrain_gen2(){
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
    sleep 3
}

speed_pulse_gen1_gen2(){
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"

    log "$bdf speed pulse Gen1 -> Gen2 via upstream=$up"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0001 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0001 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 2
    retrain_gen2 "$bdf"
}

write_mask(){
    local bdf="$1" addr="$2"
    log "$bdf write $addr = 0xffffffff via rejoin16-cycle"
    CMP90_BDF="$bdf" bash "$CYCLE" "$addr" 0xffffffff >/dev/null 2>&1 || true
}

read_mask(){
    local bdf="$1" addr="$2" tag="$3" cur
    cur="$(mask_val "$bdf" "$addr")"
    log "$bdf $addr $tag readback=${cur:-none}"
}

write_read_triplet(){
    local bdf="$1" addr="$2" tag="$3"
    write_mask "$bdf" "$addr"
    read_mask "$bdf" "$addr" "$tag immediate"
    sleep 0.25
    read_mask "$bdf" "$addr" "$tag 250ms"
    sleep 1
    read_mask "$bdf" "$addr" "$tag 1s"
}

open_feat_one_card(){
    local bdf="$1" round i

    log "============================================================"
    log "$bdf FEAT $MASK_FEAT phase start"
    log "$bdf initial masks: FEAT=$(mask_val "$bdf" "$MASK_FEAT") XVE=$(mask_val "$bdf" "$MASK_XVE")"

    for round in $(seq 1 "$FEAT_RELOAD_ROUNDS"); do
        check_timeout
        log "$bdf FEAT reload round $round/$FEAT_RELOAD_ROUNDS"
        force_good_start_for_feat "$bdf"

        for i in $(seq 1 "$FEAT_WRITES_PER_ROUND"); do
            check_timeout
            write_read_triplet "$bdf" "$MASK_FEAT" "FEAT round $round write $i/$FEAT_WRITES_PER_ROUND"
            if (( i == 3 || i == 6 )); then
                retrain_gen2 "$bdf"
            fi
        done

        speed_pulse_gen1_gen2 "$bdf"
        read_mask "$bdf" "$MASK_FEAT" "FEAT after reload round $round"
    done

    retrain_gen2 "$bdf"
    log "$bdf FEAT final masks: FEAT=$(mask_val "$bdf" "$MASK_FEAT") XVE=$(mask_val "$bdf" "$MASK_XVE")"
    verify_one "$bdf" || true
}

open_feat_all_cards(){
    local bdf
    log "PHASE 1: FEAT 0x00823800 with clean nvidia unload + real handoff per card"
    for bdf in $(find_cmps); do
        open_feat_one_card "$bdf"
    done
}

open_xve_aggressive_all(){
    log "============================================================"
    log "PHASE 2: XVE $MASK_XVE with proven old aggressive minimal"
    log "env: PCI_RESET=1 RESET_ON_STUCK=1 OPEN_REHANDOFF=1 STUCK_REPEAT_LIMIT=8 MASK_OPEN_TRIES=$XVE_TRIES"
    rm -rf /run/cmp90hx-gen2-reset-done 2>/dev/null || true
    CMP90HX_PCI_RESET=1 \
    CMP90HX_RESET_ON_STUCK=1 \
    CMP90HX_OPEN_REHANDOFF=1 \
    CMP90HX_STUCK_REPEAT_LIMIT=8 \
    CMP90HX_MASK_OPEN_TRIES="$XVE_TRIES" \
    bash "$MINIMAL" || true
}

final_soft_all(){
    local round="$1"
    log "============================================================"
    log "PHASE 3: final soft pass $round/$SOFT_ROUNDS"
    log "env: PCI_RESET=0 RESET_ON_STUCK=0 OPEN_REHANDOFF=0 MASK_OPEN_TRIES=$SOFT_TRIES"
    CMP90HX_PCI_RESET=0 \
    CMP90HX_RESET_ON_STUCK=0 \
    CMP90HX_OPEN_REHANDOFF=0 \
    CMP90HX_MASK_OPEN_TRIES="$SOFT_TRIES" \
    bash "$MINIMAL" || true
}

verify_one(){
    local bdf="$1" up speed width endpoint upstream
    up="$(upstream_of "$bdf")"
    speed="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || true)"
    width="$(cat "/sys/bus/pci/devices/${bdf}/current_link_width" 2>/dev/null || true)"
    endpoint="$(lspci -Dvv -s "$bdf" | grep 'LnkSta:' | head -1 || true)"
    upstream="$(lspci -Dvv -s "$up" | grep 'LnkSta:' | head -1 || true)"

    log "$bdf upstream=$up speed=$speed width=$width"
    log "  endpoint $endpoint"
    log "  upstream $upstream"
}

card_is_gen2(){
    local bdf="$1" up speed endpoint upstream
    up="$(upstream_of "$bdf")"
    speed="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || true)"
    endpoint="$(lspci -Dvv -s "$bdf" | grep 'LnkSta:' | head -1 || true)"
    upstream="$(lspci -Dvv -s "$up" | grep 'LnkSta:' | head -1 || true)"
    [[ "$speed" == *"5.0 GT/s"* ]] && [[ "$endpoint" == *"Speed 5GT/s"* ]] && [[ "$upstream" == *"Speed 5GT/s"* ]]
}

verify_links(){
    local bdf total=0 ok=0 bad=()
    log "VERIFY links"
    for bdf in $(find_cmps); do
        total=$((total + 1))
        verify_one "$bdf"
        if card_is_gen2 "$bdf"; then
            ok=$((ok + 1))
        else
            bad+=("$bdf")
        fi
    done
    log "GEN2 $ok/$total"
    (( ${#bad[@]} == 0 )) || log "not Gen2 yet: ${bad[*]}"
    [[ "$ok" == "$total" ]]
}

main(){
    local round
    START="$(date +%s)"

    [[ "$(id -u)" == "0" ]] || { echo "run as root"; exit 1; }

    log "LOG: $LOG"
    log "timeout=${TOTAL_TIMEOUT}s feat_reload_rounds=${FEAT_RELOAD_ROUNDS} feat_writes_per_round=${FEAT_WRITES_PER_ROUND} xve_tries=${XVE_TRIES} soft_rounds=${SOFT_ROUNDS} soft_tries=${SOFT_TRIES}"

    stop_old_automation
    make_reader_if_needed
    need_exec "$CYCLE"
    need_exec "$HANDOFF"
    need_exec "$MINIMAL"
    need_file_or_exec "$READER"

    mapfile -t BDFS < <(find_cmps)
    (( ${#BDFS[@]} > 0 )) || { log "no CMP 90HX cards found"; exit 2; }
    log "cards: ${BDFS[*]}"

    log "INITIAL: force most successful start state before doing anything"
    force_clean_nvidia_unload || true
    rescan_pci
    verify_links || true

    open_feat_all_cards
    verify_links || true

    check_timeout
    open_xve_aggressive_all
    verify_links || true

    for round in $(seq 1 "$SOFT_ROUNDS"); do
        check_timeout
        final_soft_all "$round"
        sleep 10
        if verify_links; then
            log "SUCCESS: GEN2 all/all"
            exit 0
        fi
    done

    log "FAIL: final soft convergence exhausted"
    verify_links || true
    exit 1
}

main "$@"
