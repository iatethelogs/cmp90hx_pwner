#!/usr/bin/env bash
# CMP90HX PCIe Gen2 known-good apply script.
# This is Gen2 only. It does not install compute unlock, does not create systemd,
# and does not create boot autostart.
#
# Based on the supplied known-good script; stages now target one explicit GPU.
# Reconstructed from the successful session:
#   1) per-card handoff -> embedded adaptive masks, soft tries=13, PCI_RESET=0
#   2) failed card: handoff -> embedded adaptive masks, aggressive tries=13, PCI_RESET=1
#   3) for cards still stuck on FEAT 0x00823800:
#      stop GPU users -> unload nvidia -> target PCI reset -> PCI rescan -> handoff
#      -> repeated visible rejoin16-cycle 0x00823800 0xffffffff with retrain after each try
#   4) final soft pass
#
# Required existing runtime files in /opt/cmp90hx-gen2:
#   cmp90hx-gen2-handoff.sh
#   rejoin16-cycle.sh         # real rejoin16-cycle, not resource0 shim
#   maskread.py
#   bar0poke

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${CMP90_RUNTIME_DIR:-$SCRIPT_DIR}"
PREFIX="${CMP90_PREFIX:-$RUNTIME_DIR}"
HANDOFF="${CMP90_HANDOFF:-$RUNTIME_DIR/cmp90hx-compute-handoff.sh}"
CYCLE="${CMP90_CYCLE:-$RUNTIME_DIR/rejoin16-cycle.sh}"
READER="${CMP90_READER:-$RUNTIME_DIR/maskread.py}"
if [[ -x "$RUNTIME_DIR/bar0poke" ]]; then
    BAR0POKE="${CMP90_BAR0POKE:-$RUNTIME_DIR/bar0poke}"
else
    BAR0POKE="${CMP90_BAR0POKE:-/opt/cmp90hx-gen2/bar0poke}"
fi

MASK_FEAT="0x00823800"
MASK_XVE="0x00088fe8"

# Retry limits requested for this integration.
SOFT_MASK_TRIES=13
AGGR_MASK_TRIES=13
HARD_FEAT_TRIES=13
STUCK_REPEAT_LIMIT="${CMP90HX_STUCK_REPEAT_LIMIT:-8}"
TOTAL_TIMEOUT="${CMP90HX_TOTAL_TIMEOUT:-3600}"
START="$(date +%s)"
check_timeout() {
    if (( $(date +%s) - START >= TOTAL_TIMEOUT )); then
        log "FAIL: timeout. Reboot the server and run PCIe GEN2 again; card state varies between boots."
        exit 1
    fi
}

LOG="${CMP90HX_GEN2_LOG:-/root/cmp90hx-gen2-known-good-$(date +%Y%m%d-%H%M%S).log}"

exec > >(tee -a "$LOG") 2>&1

log() { printf '[cmp90hx-known-good] %s\n' "$*"; }

need_runtime() {
    [[ -x "$HANDOFF" ]] || { log "FAIL: missing handoff: $HANDOFF"; exit 11; }
    [[ -x "$CYCLE" ]] || { log "FAIL: missing rejoin16-cycle: $CYCLE"; exit 13; }
    [[ -r "$READER" ]] || { log "FAIL: missing mask reader: $READER"; exit 14; }
    [[ -x "$BAR0POKE" ]] || { log "FAIL: missing bar0poke: $BAR0POKE"; exit 15; }

    if grep -q 'via resource0' "$CYCLE" 2>/dev/null; then
        log "FAIL: bad direct-writer shim detected in $CYCLE"
        log "Restore real rejoin16-cycle.sh before running this script."
        exit 16
    fi
}

find_cmps() {
    for d in /sys/bus/pci/devices/*; do
        [[ -f "$d/vendor" && -f "$d/device" ]] || continue
        [[ "$(cat "$d/vendor")" == "0x10de" && "$(cat "$d/device")" == "0x220d" ]] && basename "$d"
    done | sort
}

upstream_of() {
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")"
}

mask_val() {
    local bdf="$1" addr="$2"
    python3 "$READER" "$bdf" "$addr" 2>/dev/null | awk '{print $1}'
}

card_is_gen2() {
    local bdf="$1" up speed endpoint upstream
    up="$(upstream_of "$bdf")"
    speed="$(cat "/sys/bus/pci/devices/$bdf/current_link_speed" 2>/dev/null || true)"
    endpoint="$(lspci -Dvv -s "$bdf" | grep 'LnkSta:' | head -1 || true)"
    upstream="$(lspci -Dvv -s "$up"  | grep 'LnkSta:' | head -1 || true)"
    [[ "$speed" == *"5.0 GT/s"* ]] && [[ "$endpoint" == *"Speed 5GT/s"* ]] && [[ "$upstream" == *"Speed 5GT/s"* ]]
}

verify_links() {
    local cmps bdf up speed width endpoint upstream total=0 okc=0 failed=()
    cmps=("${BDFS[@]}")
    (( ${#cmps[@]} > 0 )) || { log "FAIL: no CMP 90HX 10de:220d devices found"; return 2; }

    for bdf in "${cmps[@]}"; do
        total=$((total + 1))
        up="$(upstream_of "$bdf")"
        speed="$(cat "/sys/bus/pci/devices/$bdf/current_link_speed" 2>/dev/null || true)"
        width="$(cat "/sys/bus/pci/devices/$bdf/current_link_width" 2>/dev/null || true)"
        endpoint="$(lspci -Dvv -s "$bdf" | grep 'LnkSta:' | head -1 || true)"
        upstream="$(lspci -Dvv -s "$up"  | grep 'LnkSta:' | head -1 || true)"

        log "$bdf upstream=$up speed=$speed width=$width"
        log "  endpoint $endpoint"
        log "  upstream $upstream"

        if card_is_gen2 "$bdf"; then
            okc=$((okc + 1))
        else
            failed+=("$bdf")
        fi
    done

    log "GEN2 $okc/$total"
    if (( ${#failed[@]} > 0 )); then
        log "not Gen2 yet: ${failed[*]}"
    fi

    [[ "$okc" == "$total" ]]
}





handoff() {
    local bdf="$1"
    log "$bdf handoff"
    CMP90_BDF="$bdf" bash "$HANDOFF"
}

# Operations from known-good's adaptive dependency, without its GPU loop.
# Subshell keeps its local retrain timings separate from hard-FEAT recovery.
run_card_masks() (
    local bdf="$1" PCI_RESET="$2" MASK_OPEN_TRIES="$3"
    local RESET_ON_STUCK=1 OPEN_REHANDOFF=1 MASK_FEAT_ECC="$MASK_FEAT"
    local RESET_DONE_DIR=/run/cmp90hx-gen2-reset-done
    local m_feat m_xve spd gen
    [[ "$bdf" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || return 2
    log "$bdf masks: pci_reset=$PCI_RESET tries=$MASK_OPEN_TRIES"
mask_val() {  # <bdf> <addr> -> value
    python3 "$READER" "$1" "$2" 2>/dev/null | awk '{print $1}'
}

upstream_of() { # <bdf>
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")"
}

retrain_gen2() {   # <bdf>
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
    log "  $bdf retrain target Gen2"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 2
}

retrain_gen1_then_gen2() { # <bdf>
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
    log "  $bdf speed-pulse Gen1 -> Gen2"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0001 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0001 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 2
    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 3
}

nvidia_wake() { # <bdf>
    local bdf="$1"
    log "  $bdf nvidia-smi settle"
    nvidia-smi --query-gpu=pci.bus_id,pcie.link.gen.current --format=csv,noheader,nounits >/dev/null 2>&1 || true
    sleep 2
}

soft_rehandoff() { # <bdf>
    local bdf="$1"
    [[ "$OPEN_REHANDOFF" == "1" ]] || return 0
    [[ -x "$HANDOFF" ]] || return 0
    log "  $bdf full handoff refresh"
    CMP90_BDF="$bdf" bash "$HANDOFF" || true
    sleep 4
}

pci_function_reset_once() { # <bdf> <addr>
    local bdf="$1" addr="$2" dev="/sys/bus/pci/devices/$1" key
    [[ "$PCI_RESET" == "1" && "$RESET_ON_STUCK" == "1" ]] || return 0
    [[ -w "$dev/reset" ]] || { log "  $bdf PCI reset unavailable"; return 0; }
    mkdir -p "$RESET_DONE_DIR" 2>/dev/null || true
    key="${bdf//[:.]/_}_${addr}"
    [[ ! -e "$RESET_DONE_DIR/$key" ]] || { log "  $bdf PCI reset already used for $addr in this run"; return 0; }
    : > "$RESET_DONE_DIR/$key" 2>/dev/null || true
    log "  $bdf PCI function reset for stuck $addr"
    echo 1 > "$dev/reset" 2>/dev/null || true
    sleep 8
    retrain_gen2 "$bdf"
    soft_rehandoff "$bdf"
}

settle_for_try() { # <try>
    local t="$1"
    case $(( (t - 1) % 10 )) in
        0) printf '0' ;;
        1) printf '0.25' ;;
        2) printf '0.5' ;;
        3) printf '1' ;;
        4) printf '2' ;;
        5) printf '3' ;;
        6) printf '5' ;;
        7) printf '8' ;;
        8) printf '13' ;;
        *) printf '1' ;;
    esac
}

try_prepare() { # <bdf> <try>
    local bdf="$1" try="$2"
    case $(( try % 18 )) in
        3|11)
            log "  $bdf try $try: pre-retrain"
            retrain_gen2 "$bdf"
            ;;
        5|13)
            log "  $bdf try $try: speed-pulse"
            retrain_gen1_then_gen2 "$bdf"
            ;;
        7)
            log "  $bdf try $try: nvidia settle"
            nvidia_wake "$bdf"
            ;;
        9)
            log "  $bdf try $try: longer quiet settle"
            sleep 10
            ;;
        15)
            log "  $bdf try $try: handoff refresh"
            soft_rehandoff "$bdf"
            ;;
        0)
            log "  $bdf try $try: reset stage if enabled"
            ;;
    esac
}

open_mask() { # <bdf> <addr>
    local bdf="$1" addr="$2" try cur delay old_cur repeat_count=0

    cur="$(mask_val "$bdf" "$addr")"
    [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr already OK"; return 0; }
    old_cur="$cur"

    for try in $(seq 1 "$MASK_OPEN_TRIES"); do
        check_timeout
        try_prepare "$bdf" "$try"

        CMP90_BDF="$bdf" bash "$CYCLE" "$addr" 0xffffffff >/dev/null 2>&1 || true

        cur="$(mask_val "$bdf" "$addr")"
        [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr OK (try $try immediate)"; return 0; }

        sleep 0.25
        cur="$(mask_val "$bdf" "$addr")"
        [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr OK (try $try delayed-250ms)"; return 0; }

        sleep 1
        cur="$(mask_val "$bdf" "$addr")"
        [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr OK (try $try delayed-1s)"; return 0; }

        if [[ "$cur" == "$old_cur" ]]; then
            repeat_count=$((repeat_count + 1))
        else
            repeat_count=0
            old_cur="$cur"
        fi

        if (( repeat_count == STUCK_REPEAT_LIMIT )); then
            log "  $bdf open $addr readback stuck at ${cur:-none}; handoff refresh"
            soft_rehandoff "$bdf"
        fi

        if (( repeat_count == STUCK_REPEAT_LIMIT + 4 )); then
            log "  $bdf open $addr still stuck at ${cur:-none}; reset stage"
            pci_function_reset_once "$bdf" "$addr"
            repeat_count=0
        fi

        delay="$(settle_for_try "$try")"
        log "  $bdf open $addr try $try readback=${cur:-none}; sleep ${delay}s"
        sleep "$delay"
    done

    cur="$(mask_val "$bdf" "$addr")"
    log "  $bdf open $addr FAIL (readback=${cur:-none})"
    return 1
}

    m_feat="$(mask_val "$bdf" "$MASK_FEAT_ECC")"
    m_xve="$(mask_val "$bdf" "$MASK_XVE")"
    log "$bdf masks feat_ecc=$m_feat xve=$m_xve"

    if [[ "$m_feat" == "0xffffffff" && "$m_xve" == "0xffffffff" ]]; then
        log "  masks already open - no reload cycles needed"
    else
        [[ "$m_feat" == "0xffffffff" ]] || open_mask "$bdf" "$MASK_FEAT_ECC" || true
        [[ "$m_xve"  == "0xffffffff" ]] || open_mask "$bdf" "$MASK_XVE"      || true
    fi

    retrain_gen2 "$bdf"
    spd="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || true)"
    gen="$(nvidia-smi --query-gpu=pcie.link.gen.current,pci.bus_id --format=csv,noheader,nounits 2>/dev/null \
           | awk -v b="${bdf#0000:}" '$2 ~ b {print $1; exit}' || true)"
    log "  $bdf link=${spd:-?} gen=${gen:-?}"
    sleep 5
)

soft_pass() {
    local bdf="$1" label="$2"
    log "$bdf SOFT: $label"
    handoff "$bdf" || true
    run_card_masks "$bdf" 0 "$SOFT_MASK_TRIES" || true
    card_is_gen2 "$bdf"
}

aggressive_pass() {
    local bdf="$1"
    log "$bdf AGGRESSIVE: handoff -> masks with PCI reset"
    rm -rf /run/cmp90hx-gen2-reset-done 2>/dev/null || true
    handoff "$bdf" || true
    run_card_masks "$bdf" 1 "$AGGR_MASK_TRIES" || true
    card_is_gen2 "$bdf"
}

stop_gpu_users() {
    log "stop GPU users"
    systemctl stop nvidia-persistenced 2>/dev/null || true
    systemctl stop ollama llama open-webui librechat comfyui docker containerd 2>/dev/null || true
    pkill -f 'nvidia-smi|llama-server|ollama|comfyui|python.*cuda|python.*torch|python.*nvidia' 2>/dev/null || true
    if ls /dev/nvidia* >/dev/null 2>&1; then
        fuser -k /dev/nvidia* 2>/dev/null || true
    fi
    sleep 2
}

nvidia_loaded() {
    lsmod | awk '{print $1}' | grep -Eq '^nvidia($|_)|^nvidia-vgpu-vfio$|^nvidia_vgpu_vfio$'
}

force_unload_nvidia() {
    local i loaded
    for i in 1 2 3 4 5; do
        stop_gpu_users
        modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
        modprobe -r nvidia-vgpu-vfio nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
        rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia_vgpu_vfio nvidia 2>/dev/null || true
        sleep 2

        if ! nvidia_loaded; then
            log "nvidia stack unloaded"
            return 0
        fi

        loaded="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
        log "nvidia stack still loaded after pass $i/5: ${loaded:-unknown}"
    done

    log "FAIL: nvidia stack still loaded"
    lsmod | grep '^nvidia' || true
    return 1
}

retrain_gen2() {
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
    log "$bdf pre-retrain target Gen2 via upstream=$up"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 3
}

hard_feat_card() {
    local bdf="$1" try feat

    log "=== hard FEAT fallback for $bdf ==="
    log "$bdf exact method: unload nvidia -> PCI reset card -> rescan -> handoff -> repeated rejoin16-cycle FEAT + retrain"

    force_unload_nvidia || return 1

    if [[ -w "/sys/bus/pci/devices/$bdf/reset" ]]; then
        log "$bdf PCI function reset"
        echo 1 > "/sys/bus/pci/devices/$bdf/reset" 2>/dev/null || true
        sleep 5
    else
        log "$bdf no writable PCI reset"
    fi

    log "PCI rescan"
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    sleep 5

    log "$bdf masks before hard handoff: $(python3 "$READER" "$bdf" "$MASK_FEAT" "$MASK_XVE" 2>/dev/null || true)"

    dmesg -C 2>/dev/null || true
    CMP90_BDF="$bdf" bash "$HANDOFF" || true

    for try in $(seq 1 "$HARD_FEAT_TRIES"); do
        check_timeout
        log "----- $bdf FEAT try $try/$HARD_FEAT_TRIES -----"
        CMP90_BDF="$bdf" bash "$CYCLE" "$MASK_FEAT" 0xffffffff || true

        feat="$(mask_val "$bdf" "$MASK_FEAT")"
        log "$bdf masks after FEAT try $try: $(python3 "$READER" "$bdf" "$MASK_FEAT" "$MASK_XVE" 2>/dev/null || true)"

        if [[ "$feat" == "0xffffffff" ]]; then
            log "$bdf FEAT OPENED on try $try"
            retrain_gen2 "$bdf"
            return 0
        fi

        retrain_gen2 "$bdf"
    done

    log "$bdf hard FEAT fallback did not open FEAT"
    return 1
}



main() {
    local bdf index=0
    [[ "$(id -u)" == 0 ]] || { log "FAIL: run as root"; exit 1; }
    need_runtime
    mapfile -t BDFS < <(find_cmps)
    (( ${#BDFS[@]} > 0 )) || { log "FAIL: no CMP 90HX cards found"; exit 2; }
    if [[ "${1:-}" == --verify-only ]]; then
        verify_links
        exit $?
    fi
    log "LOG: $LOG"
    log "known-good card order: ${BDFS[*]}"
    log "tries: soft=$SOFT_MASK_TRIES aggressive=$AGGR_MASK_TRIES hard_FEAT=$HARD_FEAT_TRIES"
    if verify_links; then
        log "already Gen2"
        exit 0
    fi

    for bdf in "${BDFS[@]}"; do
        check_timeout
        index=$((index + 1))
        log "$bdf CARD $index/${#BDFS[@]} START"
        if card_is_gen2 "$bdf"; then
            log "$bdf already Gen2; skip"
        elif soft_pass "$bdf" "initial known-good pass"; then
            log "$bdf Gen2 after soft pass"
        else
            aggressive_pass "$bdf" || true
            # Always finish an aggressive attempt with the known-good soft stage.
            soft_pass "$bdf" "mandatory soft after aggressive" || true
        fi
        log "$bdf CARD END"
    done

    # Recheck each GPU now, since a shared driver reload may change its state.
    for bdf in "${BDFS[@]}"; do
        check_timeout
        card_is_gen2 "$bdf" && continue
        log "$bdf RESCUE START"
        if [[ "$(mask_val "$bdf" "$MASK_FEAT")" != 0xffffffff ]]; then
            hard_feat_card "$bdf" || true
        else
            log "$bdf FEAT already open; skip hard-FEAT reset"
        fi
        # Includes XVE processing; run even if hard FEAT already reached Gen2.
        soft_pass "$bdf" "final known-good pass after rescue" || true
        log "$bdf RESCUE END"
    done

    if verify_links; then
        log "SUCCESS: GEN2 all/all"
        exit 0
    fi
    log "FAIL: Gen2 did not converge. Reboot the server and run PCIe GEN2 again."
    log "Card state varies between boots; another attempt may help."
    exit 1
}

main "$@"
