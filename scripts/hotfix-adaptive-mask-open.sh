#!/usr/bin/env bash
# CMP90HX Pwner hotfix: adaptive retry pattern for 0x823800 / 0x088fe8 mask opening.
# This does not change register addresses or the handoff/minimal order.

set -Eeuo pipefail

PREFIX="${CMP90_PREFIX:-/opt/cmp90hx-gen2}"
PROJECT_DIR="${PROJECT_DIR:-/usr/local/src/cmp90hx-pwner/cmp90hx}"
RUN_AFTER_PATCH="${RUN_AFTER_PATCH:-0}"

write_adaptive_minimal() {
    local p="$1"
    [[ -f "$p" ]] || return 0

    cp -a "$p" "${p}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

    cat > "$p" <<'EOF_GEN2_MINIMAL'
#!/usr/bin/env bash
# CMP 90HX PCIe Gen2 unlock - adaptive 2-mask apply.
# Register addresses are intentionally unchanged:
#   0x00823800 FEAT_OVR_ECC_PLM
#   0x00088fe8 XVE privilege mask
set -uo pipefail

PREFIX="${CMP90_PREFIX:-/opt/cmp90hx-gen2}"
CYCLE="${CMP90_CYCLE:-$PREFIX/rejoin16-cycle.sh}"
READER="${CMP90_READER:-$PREFIX/maskread.py}"
HANDOFF="${CMP90_HANDOFF:-$PREFIX/cmp90hx-gen2-handoff.sh}"
MASK_FEAT_ECC=0x00823800
MASK_XVE=0x00088fe8
MASK_OPEN_TRIES="${CMP90HX_MASK_OPEN_TRIES:-60}"
OPEN_REHANDOFF="${CMP90HX_OPEN_REHANDOFF:-1}"
PCI_RESET="${CMP90HX_PCI_RESET:-0}"

log() { echo "cmp90hx-gen2: $*"; }

mask_val() {  # <bdf> <addr> -> value
    python3 "$READER" "$1" "$2" 2>/dev/null | awk '{print $1}'
}

upstream_of() { # <bdf>
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")"
}

retrain_gen2() {   # <bdf>
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
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
    bash "$HANDOFF" || true
    sleep 4
}

pci_function_reset() { # <bdf>; disabled by default
    local bdf="$1" dev="/sys/bus/pci/devices/$1"
    [[ "$PCI_RESET" == "1" ]] || return 0
    [[ -w "$dev/reset" ]] || return 0
    log "  $bdf PCI function reset"
    echo 1 > "$dev/reset" 2>/dev/null || true
    sleep 8
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
            log "  $bdf try $try: optional PCI reset stage"
            pci_function_reset "$bdf"
            retrain_gen2 "$bdf"
            ;;
    esac
}

open_mask() { # <bdf> <addr>
    local bdf="$1" addr="$2" try cur delay old_cur repeat_count=0

    cur="$(mask_val "$bdf" "$addr")"
    [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr already OK"; return 0; }
    old_cur="$cur"

    for try in $(seq 1 "$MASK_OPEN_TRIES"); do
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

        if (( repeat_count == 8 )); then
            log "  $bdf open $addr readback stuck at ${cur:-none}; forcing handoff refresh"
            soft_rehandoff "$bdf"
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

mapfile -t BDFS < <(lspci -Dnn | awk '/10de:220d/ {print $1}')
if [[ "${#BDFS[@]}" -eq 0 ]]; then
    log "no CMP 90HX found; nothing to do"
    exit 0
fi

for bdf in "${BDFS[@]}"; do
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
    spd="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null)"
    gen="$(nvidia-smi --query-gpu=pcie.link.gen.current,pci.bus_id --format=csv,noheader,nounits 2>/dev/null \
           | awk -v b="${bdf#0000:}" '$2 ~ b {print $1; exit}')"
    log "  $bdf link=${spd:-?} gen=${gen:-?}"
done
log "done"
exit 0
EOF_GEN2_MINIMAL

    chmod +x "$p"
    echo "patched: $p"
}

write_adaptive_minimal "$PREFIX/cmp90hx-gen2-minimal.sh"
write_adaptive_minimal "$PROJECT_DIR/scripts/cmp90hx-gen2-minimal.sh"

if [[ "$RUN_AFTER_PATCH" == "1" ]]; then
    CMP90HX_MASK_OPEN_TRIES="${CMP90HX_MASK_OPEN_TRIES:-60}" \
    CMP90HX_APPLY_MAX_WAIT="${CMP90HX_APPLY_MAX_WAIT:-2000}" \
    bash "$PREFIX/rejoin17-apply-all.sh"
fi
